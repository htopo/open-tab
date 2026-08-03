import AppKit
import CoreGraphics
import Foundation
import OpenTabCore

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
    /// Needed after wake from sleep and after display reconfiguration, both of
    /// which can leave the tap alive but no longer receiving anything.
    public func reinstall() {
        Log.input.notice("Reinstalling event tap")
        uninstall()
        _ = install()
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
                self?.reinstall()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reinstall()
            }
        )
    }

    // MARK: - Callback

    /// Runs on the tap thread. Must stay fast and must never block.
    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

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

        // Reading the typed characters is only needed for search-mode input, so it
        // is skipped for everything else — it is the most expensive thing in this
        // function.
        let characters: String? = (type == .keyDown) ? event.unicodeString : nil

        let outcome = TapMatcher.evaluate(
            type: type,
            keyCode: keyCode,
            flags: flags,
            characters: characters,
            config: configuration
        )

        if outcome != .ignore {
            let handler = self.handler
            Task { @MainActor in handler(outcome) }
        }

        return outcome.swallowsEvent ? nil : Unmanaged.passUnretained(event)
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
