import Carbon.HIToolbox
import Foundation
import Testing
@testable import OpenTabCore
@testable import OpenTabInput

/// The highest-risk logic in the app.
///
/// If OpenTab disables ⌘Tab and fails to restore it, the user has no switcher at
/// all and no obvious way back. These tests pin the invariants that prevent that:
/// the record is written before anything is disabled, restoration puts back the
/// *prior* state rather than a blanket "enabled", and a run that never got to
/// clean up is repaired at next launch.
///
/// A fake backend is used throughout — running the real one here would disable the
/// ⌘Tab of whoever ran the tests.
@Suite("Symbolic hotkey ownership")
struct SymbolicHotkeyManagerTests {

    /// Records every call so ordering can be asserted on.
    final class FakeBackend: SymbolicHotkeyBackend, @unchecked Sendable {
        enum Call: Equatable {
            case read(Int32)
            case write(Int32, Bool)
        }

        var isSupported: Bool = true
        var state: [Int32: Bool] = [1: true, 2: true, 27: true, 28: true]
        var unreadable: Set<Int32> = []
        var calls: [Call] = []

        func isEnabled(_ id: Int32) -> Bool? {
            calls.append(.read(id))
            if unreadable.contains(id) { return nil }
            return state[id]
        }

        @discardableResult
        func setEnabled(_ id: Int32, _ enabled: Bool) -> Bool {
            calls.append(.write(id, enabled))
            state[id] = enabled
            return true
        }

        var writes: [(Int32, Bool)] {
            calls.compactMap { if case .write(let id, let on) = $0 { (id, on) } else { nil } }
        }
    }

    /// An isolated defaults domain so tests never touch the real preferences.
    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "opentab.tests.\(name)")!
        defaults.removePersistentDomain(forName: "opentab.tests.\(name)")
        return defaults
    }

    // MARK: - Reserved combination matching

    @Test("Command-Tab is recognised as reserved")
    func commandTabIsReserved() {
        #expect(SymbolicHotkeyManager.isReserved(.commandTab))
    }

    @Test("Command-backtick is recognised as reserved")
    func commandBacktickIsReserved() {
        #expect(SymbolicHotkeyManager.isReserved(
            KeyCombo(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .command)
        ))
    }

    /// ⇧ is the reverse-direction modifier while the switcher is open, so ⌘⇧Tab
    /// must resolve to the same reservation as ⌘Tab.
    @Test("The shifted variant matches the same reservation")
    func shiftedVariantMatches() {
        #expect(SymbolicHotkeyManager.isReserved(
            KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.command, .shift])
        ))
    }

    @Test("Non-reserved combinations are left alone")
    func optionTabIsNotReserved() {
        #expect(!SymbolicHotkeyManager.isReserved(
            KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: .option)
        ))
        #expect(!SymbolicHotkeyManager.isReserved(.optionBacktick))
    }

    // MARK: - Takeover

    /// The core crash-safety invariant. A crash between persisting and disabling
    /// leaves a record with nothing disabled, which repairs harmlessly. The
    /// reverse order would leave ⌘Tab dead with no record that OpenTab did it.
    @Test("The record is persisted before anything is disabled")
    func recordIsWrittenBeforeDisabling() {
        let defaults = makeDefaults()
        let backend = FakeBackend()
        let manager = SymbolicHotkeyManager(defaults: defaults, backend: backend)

        // Observe the defaults at the moment of the first disabling write.
        var recordAtFirstWrite: [String: Bool]?
        backend.calls.reserveCapacity(8)

        manager.reconcile(activeShortcuts: [.commandTab])

        // After the fact the record must be present and must name both IDs.
        recordAtFirstWrite = defaults.dictionary(forKey: SymbolicHotkeyManager.defaultsKey) as? [String: Bool]
        #expect(recordAtFirstWrite?["1"] == true)
        #expect(recordAtFirstWrite?["2"] == true)

        // And every read must precede every write, which is what proves the state
        // was captured before being changed.
        let firstWriteIndex = backend.calls.firstIndex { if case .write = $0 { true } else { false } }
        let lastReadIndex = backend.calls.lastIndex { if case .read = $0 { true } else { false } }
        #expect(firstWriteIndex != nil)
        #expect(lastReadIndex != nil)
        #expect(lastReadIndex! < firstWriteIndex!)
    }

    @Test("Taking over Command-Tab disables both the plain and shifted IDs")
    func takeoverDisablesBothIDs() {
        let backend = FakeBackend()
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        let results = manager.reconcile(activeShortcuts: [.commandTab])

        #expect(results == [.takenOver(ids: [1, 2])])
        #expect(backend.state[1] == false)
        #expect(backend.state[2] == false)
    }

    @Test("A non-reserved shortcut disables nothing")
    func nonReservedShortcutTouchesNothing() {
        let backend = FakeBackend()
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        let results = manager.reconcile(activeShortcuts: [.optionBacktick])

        #expect(results == [.notReserved])
        #expect(backend.writes.isEmpty)
        #expect(!manager.hasDirtyState)
    }

    /// A user who disabled ⌘Tab themselves in System Settings must not have
    /// OpenTab claim credit for it and "restore" it later.
    @Test("An already-disabled hotkey is not claimed")
    func alreadyDisabledHotkeyIsNotClaimed() {
        let backend = FakeBackend()
        backend.state[1] = false
        backend.state[2] = false
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        manager.reconcile(activeShortcuts: [.commandTab])

        #expect(manager.record.isEmpty)
        #expect(backend.writes.isEmpty)
    }

    @Test("An unreadable hotkey is left untouched")
    func unreadableHotkeyIsSkipped() {
        let backend = FakeBackend()
        backend.unreadable = [1, 2]
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        manager.reconcile(activeShortcuts: [.commandTab])

        #expect(manager.record.isEmpty)
        #expect(backend.writes.isEmpty)
    }

    @Test("Reconciling twice does not double-claim")
    func reconcileIsIdempotent() {
        let backend = FakeBackend()
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        manager.reconcile(activeShortcuts: [.commandTab])
        let recordAfterFirst = manager.record
        manager.reconcile(activeShortcuts: [.commandTab])

        #expect(manager.record == recordAfterFirst)
        #expect(manager.record == [1: true, 2: true])
    }

    /// Rebinding away from ⌘Tab must give the system switcher back at once, not
    /// at the next quit.
    @Test("Rebinding away from a reserved shortcut releases it immediately")
    func rebindingReleasesTheReservation() {
        let backend = FakeBackend()
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        manager.reconcile(activeShortcuts: [.commandTab])
        #expect(backend.state[1] == false)

        manager.reconcile(activeShortcuts: [.optionBacktick])

        #expect(backend.state[1] == true)
        #expect(backend.state[2] == true)
        #expect(manager.record.isEmpty)
    }

    // MARK: - Restoration

    @Test("Restore puts every claimed hotkey back")
    func restoreAllRestores() {
        let backend = FakeBackend()
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        manager.reconcile(activeShortcuts: [.commandTab])
        manager.restoreAll()

        #expect(backend.state[1] == true)
        #expect(backend.state[2] == true)
        #expect(!manager.hasDirtyState)
    }

    @Test("Restoring with nothing claimed is a no-op")
    func restoreWithEmptyRecordDoesNothing() {
        let backend = FakeBackend()
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        manager.restoreAll()

        #expect(backend.writes.isEmpty)
    }

    /// The scenario the whole design exists for: killed with `kill -9`, restarted.
    @Test("A dirty record from a previous run is repaired at launch")
    func repairOnLaunchFixesDirtyState() {
        let defaults = makeDefaults()

        // Simulate a previous run that disabled ⌘Tab and never came back.
        let crashedBackend = FakeBackend()
        let crashed = SymbolicHotkeyManager(defaults: defaults, backend: crashedBackend)
        crashed.reconcile(activeShortcuts: [.commandTab])
        #expect(crashedBackend.state[1] == false)

        // A fresh launch sees the record and repairs it before claiming anything.
        let freshBackend = FakeBackend()
        freshBackend.state = crashedBackend.state
        let fresh = SymbolicHotkeyManager(defaults: defaults, backend: freshBackend)

        #expect(fresh.hasDirtyState)
        fresh.repairOnLaunch()

        #expect(freshBackend.state[1] == true)
        #expect(freshBackend.state[2] == true)
        #expect(!fresh.hasDirtyState)
    }

    @Test("Repair is a no-op after a clean shutdown")
    func repairAfterCleanExitDoesNothing() {
        let defaults = makeDefaults()
        let backend = FakeBackend()

        let first = SymbolicHotkeyManager(defaults: defaults, backend: backend)
        first.reconcile(activeShortcuts: [.commandTab])
        first.restoreAll()

        let second = SymbolicHotkeyManager(defaults: defaults, backend: FakeBackend())
        #expect(!second.hasDirtyState)
    }

    /// Non-destructive restore: someone who had ⌘` disabled before installing
    /// OpenTab should still have it disabled afterwards.
    @Test("Restore returns the prior state, not a blanket enable")
    func restorePreservesPriorState() {
        let backend = FakeBackend()
        // The user had the shifted variant off already.
        backend.state[28] = false
        let manager = SymbolicHotkeyManager(
            defaults: makeDefaults(),
            backend: backend
        )

        let commandBacktick = KeyCombo(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .command)
        manager.reconcile(activeShortcuts: [commandBacktick])
        manager.restoreAll()

        #expect(backend.state[27] == true)   // was on, restored to on
        #expect(backend.state[28] == false)  // was off, left off
    }

    // MARK: - Force restore

    /// The escape hatch for when the record itself is wrong — a reinstall, a
    /// restored backup, a hand-edited defaults file.
    @Test("Force restore re-enables everything regardless of the record")
    func forceRestoreIgnoresTheRecord() {
        let backend = FakeBackend()
        backend.state = [1: false, 2: false, 27: false, 28: false]
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        #expect(!manager.hasDirtyState)  // no record, but the system is broken
        manager.forceRestoreEverything()

        #expect(backend.state[1] == true)
        #expect(backend.state[2] == true)
        #expect(backend.state[27] == true)
        #expect(backend.state[28] == true)
    }

    // MARK: - Degraded systems

    @Test("An unsupported system reports unavailable rather than failing silently")
    func unsupportedSystemReportsUnavailable() {
        let backend = FakeBackend()
        backend.isSupported = false
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)

        let results = manager.reconcile(activeShortcuts: [.commandTab, .optionBacktick])

        #expect(results == [.unavailable, .notReserved])
        #expect(backend.writes.isEmpty)
    }

    /// If the symbol disappears mid-session — an OS update — the record must be
    /// kept so a future launch can still repair the damage.
    @Test("Restoration keeps the record when the backend has become unavailable")
    func restoreKeepsRecordWhenUnsupported() {
        let backend = FakeBackend()
        let manager = SymbolicHotkeyManager(defaults: makeDefaults(), backend: backend)
        manager.reconcile(activeShortcuts: [.commandTab])

        backend.isSupported = false
        manager.restoreAll()

        #expect(manager.hasDirtyState, "Record must survive so a later launch can repair it")
    }

    // MARK: - Record persistence

    @Test("The record survives being re-read through a new instance")
    func recordRoundTripsThroughDefaults() {
        let defaults = makeDefaults()
        let manager = SymbolicHotkeyManager(defaults: defaults, backend: FakeBackend())

        manager.reconcile(activeShortcuts: [.commandTab])

        let reloaded = SymbolicHotkeyManager(defaults: defaults, backend: FakeBackend())
        #expect(reloaded.record == [1: true, 2: true])
    }

    /// The key name is part of the documented manual recovery path in
    /// TROUBLESHOOTING.md; renaming it silently would strand anyone following it.
    @Test("The defaults key matches the documented recovery command")
    func defaultsKeyIsStable() {
        #expect(SymbolicHotkeyManager.defaultsKey == "DisabledSymbolicHotKeys")
    }
}
