import Foundation

/// What releasing the modifier keys does.
public enum AfterReleaseBehavior: String, Codable, CaseIterable, Sendable {
    /// Commit and focus the highlighted window. The default, and what makes the
    /// app feel like the system switcher.
    case focus
    /// Leave the panel open; committing requires Return or a click.
    case hold
    /// Leave the panel open and route keyboard input to a search field.
    case search

    public var displayName: String {
        switch self {
        case .focus:  "Focus"
        case .hold:   "Hold"
        case .search: "Search"
        }
    }
}

/// The "Additional controls…" sheet.
public struct InteractionSettings: Codable, Equatable, Sendable {

    /// How long the modifier must be held before the overlay appears.
    ///
    /// This is what makes a quick tap swap windows with no visible flash, which is
    /// the single detail that decides whether the app feels native or laggy. Too
    /// low and every tap flickers the panel; too high and holding feels
    /// unresponsive.
    public var holdThresholdMS: Int

    public var mouseHoverSelects: Bool
    public var clickOutsideDismisses: Bool
    public var scrollNavigates: Bool
    public var escapeCancels: Bool

    /// Whether advancing past the last entry returns to the first.
    public var wrapAround: Bool

    public init(
        holdThresholdMS: Int = 150,
        mouseHoverSelects: Bool = true,
        clickOutsideDismisses: Bool = true,
        scrollNavigates: Bool = true,
        escapeCancels: Bool = true,
        wrapAround: Bool = true
    ) {
        self.holdThresholdMS = holdThresholdMS
        self.mouseHoverSelects = mouseHoverSelects
        self.clickOutsideDismisses = clickOutsideDismisses
        self.scrollNavigates = scrollNavigates
        self.escapeCancels = escapeCancels
        self.wrapAround = wrapAround
    }

    public var holdThreshold: TimeInterval { Double(holdThresholdMS) / 1000 }

    public static let `default` = InteractionSettings()
}
