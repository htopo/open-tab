import AppKit
import Foundation
import Observation

/// The permission state OpenTab cares about, kept current.
///
/// macOS sends no notification when a TCC grant changes, so the only way to
/// notice the user ticking a checkbox in System Settings is to poll. Polling is
/// cheap — both checks are process-local — but it is only worth doing while
/// something is actually missing, so the timer stops once everything is granted
/// and restarts if a grant is revoked.
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

    /// How often to re-check while something is outstanding. Fast enough that
    /// ticking the checkbox feels instant, slow enough to be invisible in Activity
    /// Monitor.
    private static let pollInterval: TimeInterval = 0.75

    // These two are marked nonisolated so `deinit` — which Swift runs outside the
    // actor — can still tear them down. Every other access is on the main actor.
    private nonisolated(unsafe) var timer: Timer?
    private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?

    private let accessibilityProbe: () -> Bool
    private let screenRecordingProbe: () -> Bool

    /// Both probes are injected so tests can drive the monitor without a real TCC
    /// state — there is no way to grant or revoke a permission programmatically,
    /// so the change-detection logic would otherwise be untestable.
    ///
    /// - Parameters:
    ///   - accessibilityProbe: defaults to the live `AXIsProcessTrusted` check.
    ///   - screenRecordingProbe: defaults to the live CoreGraphics preflight.
    public init(accessibilityProbe: @escaping () -> Bool = { AccessibilityPermission.isGranted },
                screenRecordingProbe: @escaping () -> Bool) {
        self.accessibilityProbe = accessibilityProbe
        self.screenRecordingProbe = screenRecordingProbe
        self.accessibility = accessibilityProbe()
        self.screenRecording = screenRecordingProbe()
    }

    deinit {
        timer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

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

    /// Re-reads both permissions and publishes any change.
    public func refresh() {
        let old = snapshot
        accessibility = accessibilityProbe()
        screenRecording = screenRecordingProbe()
        let new = snapshot

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

    /// Runs the timer only while a permission is outstanding.
    private func scheduleTimerIfNeeded() {
        let everythingGranted = accessibility && screenRecording

        if everythingGranted {
            timer?.invalidate()
            timer = nil
            return
        }

        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Keep firing while a modal menu or window drag has the run loop in a
        // tracking mode; otherwise the grant appears to "stick" until the user
        // clicks somewhere.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Actions

    /// Triggers the system Accessibility prompt.
    public func requestAccessibility() {
        AccessibilityPermission.requestPrompt()
        refresh()
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
