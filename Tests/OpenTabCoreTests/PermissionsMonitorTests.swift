import Foundation
import Testing
@testable import OpenTabCore

/// Behaviour of the permission watcher.
///
/// TCC state cannot be changed programmatically, so both probes are injected and
/// driven by hand here. What matters is the transition handling: OpenTab starts
/// its subsystems on a grant and suspends them on a revocation, and getting either
/// edge wrong leaves the app silently dead.
@Suite("Permissions monitor")
@MainActor
struct PermissionsMonitorTests {

    /// A controllable stand-in for the real TCC checks.
    ///
    /// Locked because the probes are deliberately called off the main thread —
    /// see `probesRunOffTheMainThread`.
    final class FakeState: @unchecked Sendable {
        private let lock = NSLock()
        private var values = (accessibility: false, screenRecording: false)

        var accessibility: Bool {
            get { lock.withLock { values.accessibility } }
            set { lock.withLock { values.accessibility = newValue } }
        }
        var screenRecording: Bool {
            get { lock.withLock { values.screenRecording } }
            set { lock.withLock { values.screenRecording = newValue } }
        }
    }

    /// Remembers which threads the probes were called on.
    final class ThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Bool] = []

        func record(isMain: Bool) { lock.withLock { calls.append(isMain) } }
        func reset() { lock.withLock { calls.removeAll() } }
        var ranOnMainThread: Bool { lock.withLock { calls.contains(true) } }
        var callCount: Int { lock.withLock { calls.count } }
    }

    private func makeMonitor(_ state: FakeState) -> PermissionsMonitor {
        PermissionsMonitor(
            accessibilityProbe: { state.accessibility },
            screenRecordingProbe: { state.screenRecording }
        )
    }

    /// Waits for a main-actor condition, yielding between checks so the
    /// monitor's own hop back to the main actor can run.
    private func waitUntil(_ description: Comment,
                           _ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for: \(description)")
    }

    @Test("Initial state is read from the probes")
    func initialStateReflectsProbes() {
        let state = FakeState()
        state.accessibility = true
        state.screenRecording = false

        let monitor = makeMonitor(state)

        #expect(monitor.accessibility)
        #expect(!monitor.screenRecording)
    }

    /// Screen Recording is optional; treating it as a blocker would mean nagging
    /// users who have deliberately declined it.
    @Test("Operational depends only on Accessibility")
    func operationalIgnoresScreenRecording() {
        let state = FakeState()

        state.accessibility = false
        state.screenRecording = true
        #expect(!makeMonitor(state).isOperational)

        state.accessibility = true
        state.screenRecording = false
        #expect(makeMonitor(state).isOperational)
    }

    @Test("Granting Accessibility publishes a change")
    func grantPublishesChange() {
        let state = FakeState()
        let monitor = makeMonitor(state)

        var observed: [(PermissionsMonitor.Snapshot, PermissionsMonitor.Snapshot)] = []
        monitor.onChange = { old, new in observed.append((old, new)) }

        state.accessibility = true
        monitor.refreshSynchronously()

        #expect(observed.count == 1)
        #expect(observed.first?.0.accessibility == false)
        #expect(observed.first?.1.accessibility == true)
        #expect(monitor.accessibility)
    }

    /// A revocation is not hypothetical: the user can untick the box at any time,
    /// and macOS silently drops the grant when an app's signing identity changes.
    @Test("Revoking Accessibility publishes a change")
    func revocationPublishesChange() {
        let state = FakeState()
        state.accessibility = true
        let monitor = makeMonitor(state)

        var transitions: [(Bool, Bool)] = []
        monitor.onChange = { old, new in transitions.append((old.accessibility, new.accessibility)) }

        state.accessibility = false
        monitor.refreshSynchronously()

        #expect(transitions.count == 1)
        #expect(transitions.first! == (true, false))
        #expect(!monitor.isOperational)
    }

    /// Refresh runs on a timer; firing `onChange` when nothing moved would make
    /// every consumer defensively de-duplicate.
    @Test("Refreshing without a change publishes nothing")
    func noChangeIsSilent() {
        let state = FakeState()
        state.accessibility = true
        let monitor = makeMonitor(state)

        var callCount = 0
        monitor.onChange = { _, _ in callCount += 1 }

        monitor.refreshSynchronously()
        monitor.refreshSynchronously()
        monitor.refreshSynchronously()

        #expect(callCount == 0)
    }

    @Test("Both permissions changing at once publishes one combined change")
    func simultaneousChangeIsCoalesced() {
        let state = FakeState()
        let monitor = makeMonitor(state)

        var observed: [PermissionsMonitor.Snapshot] = []
        monitor.onChange = { _, new in observed.append(new) }

        state.accessibility = true
        state.screenRecording = true
        monitor.refreshSynchronously()

        #expect(observed.count == 1)
        #expect(observed.first?.accessibility == true)
        #expect(observed.first?.screenRecording == true)
    }

    // MARK: - Probing off the main thread

    /// The regression this file exists to prevent from returning.
    ///
    /// `CGPreflightScreenCaptureAccess` is a synchronous IPC to `tccd`, not the
    /// process-local read it resembles. Polled on the main thread it made the
    /// switcher wait on a system daemon: the event tap had already swallowed
    /// ⌘Tab by then, so the shortcut did nothing and — because every line the
    /// switcher logs is written by main-actor code — left no trace of why.
    @Test("Polling probes off the main thread")
    func probesRunOffTheMainThread() async {
        let state = FakeState()
        let recorder = ThreadRecorder()
        let monitor = PermissionsMonitor(
            accessibilityProbe: {
                recorder.record(isMain: Thread.isMainThread)
                return state.accessibility
            },
            screenRecordingProbe: { state.screenRecording }
        )

        // Construction is allowed to block: there is no main actor to protect
        // yet and nothing on screen waiting on it.
        recorder.reset()

        state.accessibility = true
        monitor.refresh()

        // Still unpublished, and provably so: this test holds the main actor
        // until it next suspends, so a probe that had run inline would already
        // have been applied.
        #expect(!monitor.accessibility, "refresh must not answer on the caller's thread")

        await waitUntil("the probed grant to be published") { monitor.accessibility }
        #expect(!recorder.ranOnMainThread, "a probe ran on the main thread")
    }

    /// A `tccd` slower than the poll interval would otherwise queue up a
    /// backlog of identical questions, each one holding the answer further out
    /// of date than the last.
    @Test("Overlapping refreshes collapse into one probe")
    func refreshDoesNotStackProbes() async {
        let state = FakeState()
        let recorder = ThreadRecorder()
        let monitor = PermissionsMonitor(
            accessibilityProbe: {
                recorder.record(isMain: Thread.isMainThread)
                return state.accessibility
            },
            screenRecordingProbe: { state.screenRecording }
        )
        recorder.reset()

        for _ in 0..<10 { monitor.refresh() }

        state.accessibility = true
        await waitUntil("the first probe to land") { recorder.callCount >= 1 }
        #expect(recorder.callCount == 1, "ten calls produced \(recorder.callCount) probes")
    }

    @Test("Screen Recording alone toggling is still reported")
    func screenRecordingChangeIsReported() {
        let state = FakeState()
        state.accessibility = true
        let monitor = makeMonitor(state)

        var observed = 0
        monitor.onChange = { _, _ in observed += 1 }

        state.screenRecording = true
        monitor.refreshSynchronously()

        #expect(observed == 1)
        #expect(monitor.screenRecording)
    }
}
