import Carbon.HIToolbox
import Foundation
import OpenTabCore
import OpenTabAX

/// Ownership of the system's reserved keyboard shortcuts.
///
/// macOS reserves ⌘Tab, ⌘⇧Tab, and ⌘` at a level above event taps: a tap never
/// sees them. The only way to bind them is to disable the corresponding *symbolic
/// hotkey*, which is a system-wide setting.
///
/// **That change outlives this process.** It survives quit and reboot. If OpenTab
/// disables ⌘Tab and then dies without restoring it, the user is left with no
/// switcher at all and no obvious way to get one back — the worst failure this app
/// can produce. Everything here is built around preventing that:
///
///  - the record of what was disabled is persisted *before* anything is disabled,
///    so a crash mid-operation is still recoverable;
///  - the record stores each hotkey's *prior* state, so restoring puts back what
///    the user had rather than blanket-enabling;
///  - `repairOnLaunch()` cleans up after a previous run that did not exit cleanly;
///  - `restoreAll()` is a manual escape hatch exposed in Settings;
///  - the same UserDefaults key is documented in TROUBLESHOOTING.md so recovery is
///    possible with the app uninstalled.
public final class SymbolicHotkeyManager {

    /// Key in the app's own preferences domain. Documented in
    /// docs/TROUBLESHOOTING.md as part of the manual recovery path — do not rename
    /// it without updating that document.
    public static let defaultsKey = "DisabledSymbolicHotKeys"

    /// A reserved combination and the symbolic hotkey IDs that implement it.
    struct Reserved {
        let ids: [Int32]
        let keyCode: UInt16
        let modifiers: ModifierSet
        let label: String
    }

    /// The combinations OpenTab is willing to take over.
    ///
    /// Each entry claims a *pair* of IDs, because the shifted variant has its own
    /// ID and ⇧ is the reverse-direction modifier while the switcher is open. If
    /// only ⌘Tab were freed, ⌘⇧Tab would still reach the system switcher and
    /// cycling backwards would break.
    static let reserved: [Reserved] = [
        Reserved(ids: [1, 2],
                 keyCode: UInt16(kVK_Tab),
                 modifiers: .command,
                 label: "⌘Tab / ⌘⇧Tab (application switcher)"),
        Reserved(ids: [27, 28],
                 keyCode: UInt16(kVK_ANSI_Grave),
                 modifiers: .command,
                 label: "⌘` / ⌘⇧` (next window in application)"),
    ]

    /// Outcome of trying to take a shortcut over.
    public enum TakeoverResult: Equatable, Sendable {
        /// Nothing needed doing — the binding is not a reserved combination.
        case notReserved
        /// The system reservation was released.
        case takenOver(ids: [Int32])
        /// The symbol is gone on this macOS. The binding will still be installed,
        /// but the system switcher will appear alongside OpenTab.
        case unavailable
    }

    private let defaults: UserDefaults
    private let backend: any SymbolicHotkeyBackend

    /// - Parameters:
    ///   - defaults: where the crash-safety record lives.
    ///   - backend: the actual hotkey plumbing. Injected so the persist-before-
    ///     disable ordering can be verified in tests — exercising the real backend
    ///     would disable the test runner's own ⌘Tab, and a failing test would
    ///     leave it that way.
    public init(defaults: UserDefaults = .standard,
                backend: any SymbolicHotkeyBackend = SystemSymbolicHotkeyBackend()) {
        self.defaults = defaults
        self.backend = backend
    }

    // MARK: - Availability

    /// Whether reserved combinations can be taken over at all on this system.
    public var isSupported: Bool { backend.isSupported }

    /// Whether a combination is one macOS reserves.
    public static func isReserved(_ combo: KeyCombo) -> Bool {
        matching(combo) != nil
    }

    static func matching(_ combo: KeyCombo) -> Reserved? {
        reserved.first { entry in
            entry.keyCode == combo.keyCode
                && entry.modifiers == combo.modifiers.subtracting(.shift)
        }
    }

    // MARK: - Persisted record

    /// Symbolic hotkey ID → whether it was enabled before OpenTab touched it.
    ///
    /// Storing the prior state rather than a plain list is what makes restoration
    /// non-destructive: a user who had already disabled ⌘Tab themselves gets that
    /// back, not OpenTab's idea of a default.
    var record: [Int32: Bool] {
        get {
            guard let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool]
            else { return [:] }
            return raw.reduce(into: [:]) { result, pair in
                if let id = Int32(pair.key) { result[id] = pair.value }
            }
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                let raw = newValue.reduce(into: [String: Bool]()) { result, pair in
                    result[String(pair.key)] = pair.value
                }
                defaults.set(raw, forKey: Self.defaultsKey)
            }
            // Force the write to disk now. The whole point of the record is to
            // survive a crash, and a crash a millisecond from now would otherwise
            // lose it to the preferences daemon's write coalescing.
            defaults.synchronize()
        }
    }

    public var hasDirtyState: Bool { !record.isEmpty }

    // MARK: - Takeover

    /// Frees up whichever reserved combinations the given bindings claim, and
    /// restores any that are no longer claimed.
    ///
    /// Safe to call repeatedly; it reconciles rather than accumulating.
    @discardableResult
    public func reconcile(activeShortcuts: [KeyCombo]) -> [TakeoverResult] {
        guard isSupported else {
            Log.hotkeys.error("CGSSetSymbolicHotKeyEnabled unavailable — cannot free reserved shortcuts")
            return activeShortcuts.map { Self.isReserved($0) ? .unavailable : .notReserved }
        }

        let claimed = Set(activeShortcuts.compactMap { Self.matching($0) }.flatMap(\.ids))
        var current = record

        // Restore anything we hold that is no longer claimed — the user rebound a
        // shortcut away from ⌘Tab and should get the system switcher back at once.
        for (id, wasEnabled) in current where !claimed.contains(id) {
            backend.setEnabled(id, wasEnabled)
            current[id] = nil
            Log.hotkeys.notice("Released symbolic hotkey \(id) (restored to enabled=\(wasEnabled))")
        }
        record = current

        // Now take over anything newly claimed.
        var results: [TakeoverResult] = []
        for combo in activeShortcuts {
            guard let entry = Self.matching(combo) else {
                results.append(.notReserved)
                continue
            }
            disable(entry)
            results.append(.takenOver(ids: entry.ids))
        }
        return results
    }

    private func disable(_ entry: Reserved) {
        var current = record

        for id in entry.ids where current[id] == nil {
            // Read the prior state before writing. The plan calls for verifying
            // these IDs empirically rather than trusting the constants across
            // macOS versions; an ID that cannot be read is one we do not touch.
            guard let wasEnabled = backend.isEnabled(id) else {
                Log.hotkeys.error("Symbolic hotkey \(id) is unreadable on this system; leaving it alone")
                continue
            }

            guard wasEnabled else {
                // Already off — the user disabled it themselves. Nothing to do,
                // and nothing to restore later.
                Log.hotkeys.notice("Symbolic hotkey \(id) was already disabled; not claiming it")
                continue
            }

            current[id] = wasEnabled
        }

        // Persist BEFORE disabling. A crash between these two statements leaves a
        // record with nothing disabled, which repairs harmlessly. The reverse
        // order would leave ⌘Tab disabled with no record that we did it.
        record = current

        for id in entry.ids where current[id] != nil {
            if backend.setEnabled(id, false) {
                Log.hotkeys.notice("Disabled symbolic hotkey \(id) for \(entry.label, privacy: .public)")
            } else {
                Log.hotkeys.error("Failed to disable symbolic hotkey \(id)")
            }
        }
    }

    // MARK: - Restoration

    /// Puts every hotkey OpenTab disabled back the way it was.
    ///
    /// Called on normal quit, from the signal handlers, and from the manual
    /// "Restore system shortcuts" button in Settings.
    public func restoreAll() {
        let current = record
        guard !current.isEmpty else { return }

        guard isSupported else {
            // The symbol vanished between disabling and now — an OS update mid
            // session. Keep the record so a future launch can still repair it.
            Log.hotkeys.error("Cannot restore symbolic hotkeys: symbol unavailable. Record kept for next launch.")
            return
        }

        for (id, wasEnabled) in current {
            if backend.setEnabled(id, wasEnabled) {
                Log.hotkeys.notice("Restored symbolic hotkey \(id) to enabled=\(wasEnabled)")
            } else {
                Log.hotkeys.error("Failed to restore symbolic hotkey \(id)")
            }
        }

        record = [:]
    }

    /// The nuclear option behind Settings → Controls → "Restore system shortcuts".
    ///
    /// Re-enables every hotkey OpenTab is capable of touching, whether or not it
    /// believes it owns them. This exists for the case where the record itself is
    /// wrong — the user reinstalled, restored from a backup, or edited defaults by
    /// hand — and the normal restore therefore does nothing.
    public func forceRestoreEverything() {
        guard isSupported else {
            Log.hotkeys.error("Cannot force-restore: CGSSetSymbolicHotKeyEnabled unavailable")
            return
        }

        for entry in Self.reserved {
            for id in entry.ids {
                backend.setEnabled(id, true)
            }
        }
        record = [:]
        Log.hotkeys.notice("Force-restored all reserved system shortcuts")
    }

    /// Repairs state left behind by a run that did not exit cleanly.
    ///
    /// Call this at launch, before taking anything over. A `kill -9`, a panic, or
    /// a power loss all land here.
    public func repairOnLaunch() {
        let current = record
        guard !current.isEmpty else { return }

        Log.hotkeys.error(
            "Found \(current.count) symbolic hotkey(s) left disabled by a previous run; repairing"
        )
        restoreAll()
    }
}
