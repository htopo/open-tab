import Foundation

/// What the input layer reports upward.
///
/// The switcher controller conforms to this. Keeping it a protocol means the
/// hotkey state machine can be exercised in tests against a recording double
/// rather than a live overlay.
public protocol SwitcherDriver: AnyObject {
    /// A quick tap: swap to the previous window with no visible panel.
    func performInstantSwap(shortcutIndex: Int)

    /// The hold threshold elapsed — show the overlay.
    func presentOverlay(shortcutIndex: Int)

    /// Move the selection by `delta` entries, wrapping per settings.
    func advanceSelection(by delta: Int)

    /// Commit the current selection and focus that window.
    func commitSelection()

    /// Dismiss without focusing anything.
    func cancel()
}

/// Reasons the input layer can be unable to observe keys, surfaced to the UI so
/// the app can explain itself instead of silently doing nothing.
public enum InputUnavailableReason: Equatable, Sendable {
    /// Accessibility has not been granted; an event tap cannot be created.
    case accessibilityDenied
    /// The tap was created but the system disabled it and re-enabling failed.
    case tapDisabled
}
