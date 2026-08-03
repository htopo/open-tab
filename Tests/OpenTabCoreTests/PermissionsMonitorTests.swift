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
    final class FakeState {
        var accessibility = false
        var screenRecording = false
    }

    private func makeMonitor(_ state: FakeState) -> PermissionsMonitor {
        PermissionsMonitor(
            accessibilityProbe: { state.accessibility },
            screenRecordingProbe: { state.screenRecording }
        )
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
        monitor.refresh()

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
        monitor.refresh()

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

        monitor.refresh()
        monitor.refresh()
        monitor.refresh()

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
        monitor.refresh()

        #expect(observed.count == 1)
        #expect(observed.first?.accessibility == true)
        #expect(observed.first?.screenRecording == true)
    }

    @Test("Screen Recording alone toggling is still reported")
    func screenRecordingChangeIsReported() {
        let state = FakeState()
        state.accessibility = true
        let monitor = makeMonitor(state)

        var observed = 0
        monitor.onChange = { _, _ in observed += 1 }

        state.screenRecording = true
        monitor.refresh()

        #expect(observed == 1)
        #expect(monitor.screenRecording)
    }
}
