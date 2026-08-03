import Foundation
import OpenTabAX

/// The system plumbing behind symbolic hotkeys.
///
/// Exists purely so `SymbolicHotkeyManager` can be tested. Exercising the real
/// implementation from a test would disable the developer's own ⌘Tab, and a test
/// that failed part-way through would leave it disabled — which is exactly the
/// failure the manager is designed to prevent.
public protocol SymbolicHotkeyBackend: Sendable {
    /// Whether the underlying system call is available at all.
    var isSupported: Bool { get }

    /// Current state of a symbolic hotkey, or nil if it cannot be read.
    func isEnabled(_ id: Int32) -> Bool?

    /// Sets the state. Returns whether the call succeeded.
    @discardableResult
    func setEnabled(_ id: Int32, _ enabled: Bool) -> Bool
}

/// The real implementation, backed by the undocumented CoreGraphics symbols.
public struct SystemSymbolicHotkeyBackend: SymbolicHotkeyBackend {
    public init() {}

    public var isSupported: Bool {
        PrivateSymbols.canControlSymbolicHotKeys && PrivateSymbols.canReadSymbolicHotKeyState
    }

    public func isEnabled(_ id: Int32) -> Bool? {
        PrivateSymbols.isSymbolicHotKeyEnabled(id)
    }

    @discardableResult
    public func setEnabled(_ id: Int32, _ enabled: Bool) -> Bool {
        PrivateSymbols.setSymbolicHotKeyEnabled(id, enabled)
    }
}
