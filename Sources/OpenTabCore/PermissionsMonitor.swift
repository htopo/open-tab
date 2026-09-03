import AppKit
import Foundation
import Observation

/// The permission state OpenTab cares about, kept current.
///
/// macOS sends no notification when a TCC grant changes, so the only way to
/// notice the user ticking a checkbox in System Settings is to poll. The timer
/// runs only while something is actually missing, so it stops once everything
/// is granted and restarts if a grant is revoked.
///
/// **The probes are not the cheap process-local reads they look like.**
/// `CGPreflightScreenCaptureAccess` is a synchronous IPC to `tccd`, so how long
/// a poll takes is up to a system daemon. Running it on the main thread made
/// the switcher's responsiveness depend on that: while the main actor waited
/// for an answer, the event tap had already swallowed ⌘Tab — swallowing is
/// decided on the tap thread, before the handler runs — so the shortcut did
/// nothing, showed nothing, and logged nothing, because every line the switcher
/// writes is written by main-actor code. A denied Screen Recording grant is an
/// ordinary choice, and it left this polling forever.
@MainActor
@Observable
public final class PermissionsMonitor {

    /// Required. Without it the app cannot enumerate, focus, or observe keys.
    public private(set) var accessibility: Bool

    /// Optional. Gates thumbnails only; the app stays fully usable without it.
    public private(set) var screenRecording: Bool

    /// True once the app has everything it needs to do its job. Screen Recording
    /// is deliberately not part of this — treating an optional permission as a
    /// blocker is how apps end up nagging.
    public var isOperational: Bool { accessibility }

    /// Fires whenever either value changes, with the previous state for comparison.
    public var onChange: ((_ old: Snapshot, _ new: Snapshot) -> Void)?

    public struct Snapshot: Equatable, Sendable {
        public let accessibility: Bool
        public let screenRecording: Bool
    }

    public var snapshot: Snapshot {
        Snapshot(accessibility: accessibility, screenRecording: screenRecording)
    }

    /// How often to re-check while the user is looking at OpenTab's own UI.
    ///
    /// The onboarding window and Settings both show the state next to a button
    /// that sends the user to System Settings, so it has to keep up with them
    /// walking there and back.
    private static let activePollInterval: TimeInterval = 0.75

    /// How often to re-check otherwise.
    ///
    /// Nothing on screen is showing the state, and a grant that changes will be
    /// noticed on the next application activation regardless — so this only has
    /// to be a backstop for a change made with no activation at all, not a live
    /// feed. At the fast rate it was a `tccd` round trip every 750 ms for the
    /// entire life of the process.
    private static let idlePollInterval: TimeInterval = 30

    // Plumbing, not state: changing these must not invalidate a SwiftUI view.
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    @ObservationIgnored private let accessibilityProbe: @Sendable () -> Bool
    @ObservationIgnored private let screenRecordingProbe: @Sendable () -> Bool

    /// Where the probes run. Serial, so a slow answer delays only the next poll
    /// rather than piling up round trips behind it.
    @ObservationIgnored private let probeQueue = DispatchQueue(
        label: "io.github.htopo.opentab.permissions", qos: .utility
    )

    /// True while a probe is in flight, so a slow `tccd` cannot accumulate a
    /// backlog of identical questions.
    @ObservationIgnored private var isProbing = false

    /// The interval the running timer was created with, so the rate can change
    /// without replacing a timer that is already correct.
    @ObservationIgnored private var scheduledInterval: TimeInterval?

    /// Both probes are injected so tests can drive the monitor without a real TCC
    /// state — there is no way to grant or revoke a permission programmatically,
    /// so the change-detection logic would otherwise be untestable.
    ///
    /// - Parameters:
    ///   - accessibilityProbe: defaults to the live `AXIsProcessTrusted` check.
    ///   - screenRecordingProbe: defaults to the live CoreGraphics preflight.
    public init(accessibilityProbe: @escaping @Sendable () -> Bool = { AccessibilityPermission.isGranted },
                screenRecordingProbe: @escaping @Sendable () -> Bool) {
        self.accessibilityProbe = accessibilityProbe
        self.screenRecordingProbe = screenRecordingProbe
        // At construction there is no main actor to protect and nothing on
        // screen yet, so the blocking read is the right one.
        self.accessibility = accessibilityProbe()
        self.screenRecording = screenRecordingProbe()
    }

    // No deinit teardown: Swift runs `deinit` outside the actor, so it cannot
    // touch main-actor state. `stop()` is the teardown, and the app delegate calls
    // it during shutdown. The timer holds only a weak reference, so failing to
    // call it leaks a no-op timer rather than the monitor itself.

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil else { return }

        // Coming back from System Settings is the single most likely moment for a
        // grant to have changed, so check immediately on activation rather than
        // waiting up to a full poll interval.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        scheduleTimerIfNeeded()
        refresh()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: - Polling

    /// Re-reads both permissions off the main actor and publishes any change.
    ///
    /// Nothing waits on the answer, which is the point: a `tccd` that takes a
    /// second to reply now delays only the next poll instead of every keystroke
    /// the switcher is meant to be handling.
    public func refresh() {
        guard !isProbing else { return }
        isProbing = true

        let probeAccessibility = accessibilityProbe
        let probeScreenRecording = screenRecordingProbe

        probeQueue.async { [weak self] in
            let probed = Snapshot(accessibility: probeAccessibility(),
                                  screenRecording: probeScreenRecording())
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isProbing = false
                self.apply(probed)
            }
        }
    }

    /// Re-reads both permissions on the calling thread.
    ///
    /// For the two moments where the next line genuinely needs the answer:
    /// constructing the monitor, and returning from a system prompt the user
    /// has just dismissed. Everywhere else, use `refresh`.
    public func refreshSynchronously() {
        apply(Snapshot(accessibility: accessibilityProbe(),
                       screenRecording: screenRecordingProbe()))
    }

    /// Publishes a freshly probed state. The only writer of either property.
    private func apply(_ new: Snapshot) {
        let old = snapshot
        accessibility = new.accessibility
        screenRecording = new.screenRecording

        guard old != new else {
            scheduleTimerIfNeeded()
            return
        }

        Log.permissions.notice(
            "Permissions changed: accessibility \(old.accessibility)→\(new.accessibility), screenRecording \(old.screenRecording)→\(new.screenRecording)"
        )
        scheduleTimerIfNeeded()
        onChange?(old, new)
    }

    /// Runs the timer only while a permission is outstanding, at a rate that
    /// depends on whether anyone is looking.
    private func scheduleTimerIfNeeded() {
        let everythingGranted = accessibility && screenRecording

        if everythingGranted {
            timer?.invalidate()
            timer = nil
            scheduledInterval = nil
            return
        }

        // OpenTab becomes active only when its own windows are open, which are
        // the only place the permission state is on screen.
        let wanted = NSApp?.isActive == true ? Self.activePollInterval : Self.idlePollInterval
        guard scheduledInterval != wanted else { return }

        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Keep firing while a modal menu or window drag has the run loop in a
        // tracking mode; otherwise the grant appears to "stick" until the user
        // clicks somewhere.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduledInterval = wanted
    }

    // MARK: - Actions

    /// Triggers the system Accessibility prompt.
    public func requestAccessibility() {
        AccessibilityPermission.requestPrompt()
        // The user has just answered a prompt and is looking at the result.
        refreshSynchronously()
    }

    /// Opens the relevant System Settings pane.
    public func openSettings(for permission: Permission) {
        let urlString: String
        switch permission {
        case .accessibility:  urlString = AccessibilityPermission.settingsURLString
        case .screenRecording: urlString = Self.screenRecordingSettingsURLString
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    public enum Permission: Sendable {
        case accessibility
        case screenRecording
    }

    /// Duplicated from OpenTabShot so that opening the pane does not require the
    /// capture module — OpenTabCore must not depend on it.
    public static let screenRecordingSettingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}
