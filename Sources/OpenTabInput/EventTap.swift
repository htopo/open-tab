import AppKit
import CoreGraphics
import Foundation
import OpenTabCore
import os

/// The keyboard event tap.
///
/// Two decisions here are load-bearing:
///
/// **It is a `.defaultTap`, not listen-only.** OpenTab has to consume the trigger
/// event so it never reaches the focused application. Otherwise every switch would
/// also fire whatever that app binds to the same key.
///
/// **It runs on its own thread with its own run loop.** macOS disables a tap whose
/// callback takes too long, and the symptom is the user's typing stuttering
/// system-wide. Keeping the callback off the main thread means a hitch in the UI —
/// a slow SwiftUI layout, a synchronous disk read — cannot cause that. The
/// callback itself only matches against a snapshotted configuration and hands
/// anything real to the main actor.
public final class EventTap {

    /// Delivered on the main actor.
    public typealias Handler = @MainActor (TapOutcome) -> Void

    private let handler: Handler
    private let onUnavailable: @MainActor (InputUnavailableReason) -> Void

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    /// Guards `configuration`, which is written from the main actor and read on
    /// the tap thread.
    private let configLock = NSLock()
    private var _configuration = TapConfiguration()

    private var notificationObservers: [any NSObjectProtocol] = []

    /// Modifier state at the previous event. Tap-thread only; see `handle`.
    private var lastFlags: CGEventFlags = []

    /// How many events the tap has been handed, ever.
    ///
    /// This is the one number that separates "the switcher ignored the shortcut"
    /// from "the shortcut never reached the switcher" — and from outside the tap
    /// those two look identical, because a tap that has quietly stopped
    /// delivering behaves exactly like a matcher that declined every event.
    /// Without it, a report of "⌘Tab did nothing" leaves no trace at all in the
    /// log: there is no line for an event that never arrived.
    private let eventCounter = OSAllocatedUnfairLock(initialState: UInt64(0))

    public var eventsSeen: UInt64 { eventCounter.withLock { $0 } }

    /// Tracks the hand-off from the tap thread to the main actor.
    ///
    /// Swallowing is decided here, on the tap thread; acting on the event is
    /// the main actor's job. Only the first of those is guaranteed to happen.
    /// A main actor stuck in a synchronous system call - a TCC probe, an
    /// Accessibility call to an application that has stopped answering - leaves
    /// the keystroke consumed and nothing done with it. That is a switcher that
    /// ignores the shortcut and cannot say why, because every line it logs is
    /// written by main-actor code.
    private struct HandOff {
        var pending = 0
        /// When the oldest unhandled hand-off was made. Reset to now on each
        /// acknowledgement rather than tracking every event's own timestamp,
        /// which errs towards reporting a stall as shorter than it was.
        var oldestPendingAt: DispatchTime?
    }

    private let handOff = OSAllocatedUnfairLock(initialState: HandOff())

    /// How long the main actor may leave an event unhandled before it is worth
    /// a line in the log. Two events arriving in the same instant and both
    /// dispatched before either is handled is ordinary; a quarter of a second
    /// is not.
    private static let handOffStallThreshold: Double = 250

    public init(
        handler: @escaping Handler,
        onUnavailable: @escaping @MainActor (InputUnavailableReason) -> Void
    ) {
        self.handler = handler
        self.onUnavailable = onUnavailable
    }

    // MARK: - Configuration

    public var configuration: TapConfiguration {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _configuration
        }
        set {
            configLock.lock()
            _configuration = newValue
            configLock.unlock()
        }
    }

    /// Mutates the configuration in place under the lock.
    public func updateConfiguration(_ mutate: (inout TapConfiguration) -> Void) {
        configLock.lock()
        mutate(&_configuration)
        configLock.unlock()
    }

    // MARK: - Lifecycle

    public var isInstalled: Bool { machPort != nil }

    /// Creates and enables the tap.
    ///
    /// - Returns: false when the tap could not be created, which in practice
    ///   always means Accessibility is not granted.
    @discardableResult
    public func install() -> Bool {
        guard machPort == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.input.error("CGEvent.tapCreate failed — Accessibility is almost certainly not granted")
            Task { @MainActor in self.onUnavailable(.accessibilityDenied) }
            return false
        }

        machPort = port
        startTapThread(port: port)
        subscribeToSystemEvents()

        Log.input.notice("Event tap installed")
        return true
    }

    public func uninstall() {
        for observer in notificationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }
        machPort = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil

        Log.input.notice("Event tap removed")
    }

    /// Tears the tap down and builds a new one.
    ///
    /// A last resort. Prefer `revalidate()`, which repairs the failure that
    /// actually happens without a gap in coverage.
    public func reinstall() {
        Log.input.notice("Reinstalling event tap")
        uninstall()
        _ = install()
    }

    /// Checks the tap is still delivering, and re-enables it if not.
    ///
    /// The failure a tap suffers is being *disabled*, not destroyed — by an
    /// overrun callback, by sleep, by the system deciding it has had enough.
    /// Re-enabling is the documented repair and takes effect immediately.
    ///
    /// Rebuilding instead is worse than useless. Tearing the tap down and
    /// standing a new one up takes a thread teardown, a new run loop and a new
    /// mach port, and every keystroke in that gap is lost. This ran on
    /// `didChangeScreenParametersNotification`, which macOS also posts when the
    /// user switches Desktop — so moving to another Desktop and immediately
    /// pressing ⌘Tab landed squarely in the gap, and the switcher appeared not to
    /// exist there at all.
    public func revalidate() {
        guard let machPort else {
            reinstall()
            return
        }
        guard !CGEvent.tapIsEnabled(tap: machPort) else { return }

        Log.input.notice("Event tap had been disabled; re-enabling")
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    // MARK: - Tap thread

    private func startTapThread(port: CFMachPort) {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source

        let thread = Thread { [weak self] in
            guard let self else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)

            // Runs until CFRunLoopStop, which uninstall() calls.
            CFRunLoopRun()
        }
        thread.name = "io.github.htopo.opentab.eventtap"
        // Above default so a busy system cannot starve keyboard handling; below
        // real-time, which this does not warrant.
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
    }

    // MARK: - System events

    private func subscribeToSystemEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        notificationObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // A tap can survive sleep as an object while no longer delivering.
                self?.revalidate()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Also posted on a Desktop switch, not only on real display
                // changes — so this must be cheap and must not interrupt delivery.
                self?.revalidate()
            }
        )
    }

    // MARK: - Callback

    /// Runs on the tap thread. Must stay fast and must never block.
    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        eventCounter.withLock { $0 &+= 1 }

        // macOS disables a tap whose callback overran its deadline, and tells us
        // by sending this. Re-enabling is the only way back; without it the
        // hotkey silently stops working for the rest of the session.
        if type == .tapDisabledByTimeout {
            Log.input.error("Event tap disabled by timeout — re-enabling")
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByUserInput {
            Log.input.notice("Event tap disabled by user input — re-enabling")
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // `.flagsChanged` carries the resulting modifier state, never what
        // changed, so telling a ⇧ press from a ⇧ release needs the previous
        // value. Kept here rather than in `TapConfiguration` because it belongs
        // to the tap thread — it is written and read only inside this callback,
        // which is serial, so no lock is involved.
        let previousFlags = lastFlags
        lastFlags = flags

        // Reading the typed characters is only needed for search-mode input, so it
        // is skipped for everything else — it is the most expensive thing in this
        // function.
        let characters: String? = (type == .keyDown) ? event.unicodeString : nil

        let outcome = TapMatcher.evaluate(
            type: type,
            keyCode: keyCode,
            flags: flags,
            characters: characters,
            config: configuration,
            previousFlags: previousFlags
        )

        if outcome != .ignore {
            noteDispatch()
            let handler = self.handler
            let handOff = self.handOff
            Task { @MainActor in
                // Acknowledged before the handler runs: this measures how long
                // the hand-off waited, not how long the work took.
                handOff.withLock { state in
                    state.pending = max(0, state.pending - 1)
                    state.oldestPendingAt = state.pending > 0 ? .now() : nil
                }
                handler(outcome)
            }
        }

        return outcome.swallowsEvent ? nil : Unmanaged.passUnretained(event)
    }

    /// Records a hand-off, and reports a main actor that is not draining them.
    ///
    /// Runs on the tap thread, which is the whole point: this is the one place
    /// that still gets to speak while the main actor is wedged.
    private func noteDispatch() {
        let stalled: (waited: Double, count: Int)? = handOff.withLock { state in
            let age = state.oldestPendingAt.map {
                Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000
            }
            state.pending += 1
            if state.oldestPendingAt == nil { state.oldestPendingAt = .now() }
            guard let age, age > Self.handOffStallThreshold else { return nil }
            return (age, state.pending)
        }

        guard let stalled else { return }
        Log.input.error(
            "Main actor has not handled \(stalled.count) dispatched events; oldest waiting \(stalled.waited, format: .fixed(precision: 0))ms. The shortcut has been consumed and cannot be acted on until it frees up."
        )
    }

    /// C trampoline back into Swift.
    private static let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handle(proxy: proxy, type: type, event: event)
    }
}

private extension CGEvent {
    /// The characters this key event would produce.
    var unicodeString: String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: buffer.count,
                                 actualStringLength: &length,
                                 unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
