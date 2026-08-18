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

    /// Tapping ⇧ while the switcher is open steps backwards one entry.
    ///
    /// When on, ⇧ stops modifying Tab's direction once the switcher is up: Tab
    /// always moves forward and ⇧ always moves back. The two roles cannot
    /// coexist — if ⇧ both stepped back on its own *and* reversed Tab, the single
    /// ⌘⇧Tab gesture would move two entries instead of one.
    ///
    /// ⇧ still selects the last entry when it is held for the press that *opens*
    /// the switcher, which is unambiguous because there is nothing to step back
    /// from yet.
    public var shiftStepsBackwards: Bool

    public init(
        holdThresholdMS: Int = 150,
        mouseHoverSelects: Bool = true,
        clickOutsideDismisses: Bool = true,
        scrollNavigates: Bool = true,
        escapeCancels: Bool = true,
        wrapAround: Bool = true,
        shiftStepsBackwards: Bool = true
    ) {
        self.holdThresholdMS = holdThresholdMS
        self.mouseHoverSelects = mouseHoverSelects
        self.clickOutsideDismisses = clickOutsideDismisses
        self.scrollNavigates = scrollNavigates
        self.escapeCancels = escapeCancels
        self.wrapAround = wrapAround
        self.shiftStepsBackwards = shiftStepsBackwards
    }

    public var holdThreshold: TimeInterval { Double(holdThresholdMS) / 1000 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InteractionSettings()
        holdThresholdMS = c.value(.holdThresholdMS, d.holdThresholdMS)
        mouseHoverSelects = c.value(.mouseHoverSelects, d.mouseHoverSelects)
        clickOutsideDismisses = c.value(.clickOutsideDismisses, d.clickOutsideDismisses)
        scrollNavigates = c.value(.scrollNavigates, d.scrollNavigates)
        escapeCancels = c.value(.escapeCancels, d.escapeCancels)
        wrapAround = c.value(.wrapAround, d.wrapAround)
        shiftStepsBackwards = c.value(.shiftStepsBackwards, d.shiftStepsBackwards)
    }

    public static let `default` = InteractionSettings()

    /// Shown under the "Shift steps backwards" toggle.
    public static let shiftStepsExplanation = """
        Tap ⇧ while the switcher is open to move back one entry, and Tab always \
        moves forward. Turn this off to reverse direction with ⇧Tab instead.
        """
}
