import Foundation

/// Where the overlay appears on a multi-display setup.
///
/// A specific display is stored by *name* rather than by `CGDirectDisplayID`,
/// because display IDs are reassigned across reboots and re-plugs. A name survives
/// both, and falls back gracefully when that display is gone.
public enum ScreenPlacement: Codable, Hashable, Sendable {
    case activeScreen
    case screenWithMouse
    case screenWithFocusedWindow
    case specificDisplay(name: String)

    public var displayName: String {
        switch self {
        case .activeScreen:            "Active screen"
        case .screenWithMouse:         "Screen with mouse"
        case .screenWithFocusedWindow: "Screen with the focused window"
        case .specificDisplay(let name): name
        }
    }

    /// The fixed options, excluding the per-display entries the UI appends.
    public static let standardCases: [ScreenPlacement] = [
        .activeScreen, .screenWithMouse, .screenWithFocusedWindow,
    ]
}

/// The "Animations…" sheet.
public struct AnimationSettings: Codable, Equatable, Sendable {
    public var fadeInDuration: Double
    public var fadeOutDuration: Double
    public var animateSelectionMove: Bool

    /// Master switch. The system's own "reduce motion" setting is honoured in
    /// addition to this — a user who asked the OS to reduce motion should not have
    /// to ask again here.
    public var reduceAnimations: Bool

    public init(
        fadeInDuration: Double = 0.10,
        fadeOutDuration: Double = 0.08,
        animateSelectionMove: Bool = true,
        reduceAnimations: Bool = false
    ) {
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.animateSelectionMove = animateSelectionMove
        self.reduceAnimations = reduceAnimations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnimationSettings()
        fadeInDuration = c.value(.fadeInDuration, d.fadeInDuration)
        fadeOutDuration = c.value(.fadeOutDuration, d.fadeOutDuration)
        animateSelectionMove = c.value(.animateSelectionMove, d.animateSelectionMove)
        reduceAnimations = c.value(.reduceAnimations, d.reduceAnimations)
    }

    public static let `default` = AnimationSettings()
}

/// How the selected entry is marked.
public enum HighlightStyle: String, Codable, CaseIterable, Sendable {
    case fill
    case border

    public var displayName: String {
        switch self {
        case .fill:   "Filled"
        case .border: "Border"
        }
    }
}

/// The "Customize more…" sheet.
public struct AdvancedAppearanceSettings: Codable, Equatable, Sendable {
    public var maxRows: Int
    public var maxColumns: Int
    public var panelOpacity: Double
    public var cornerRadius: Double
    public var cellPadding: Double
    public var titleFontSize: Double

    public var showAppIconBadge: Bool
    public var showWindowCountBadge: Bool
    public var showStatusBadges: Bool
    public var showWindowTitle: Bool
    public var highlightStyle: HighlightStyle

    public init(
        maxRows: Int = 4,
        maxColumns: Int = 6,
        panelOpacity: Double = 1.0,
        cornerRadius: Double = 16,
        cellPadding: Double = 8,
        titleFontSize: Double = 11,
        showAppIconBadge: Bool = true,
        showWindowCountBadge: Bool = true,
        showStatusBadges: Bool = true,
        showWindowTitle: Bool = true,
        highlightStyle: HighlightStyle = .fill
    ) {
        self.maxRows = maxRows
        self.maxColumns = maxColumns
        self.panelOpacity = panelOpacity
        self.cornerRadius = cornerRadius
        self.cellPadding = cellPadding
        self.titleFontSize = titleFontSize
        self.showAppIconBadge = showAppIconBadge
        self.showWindowCountBadge = showWindowCountBadge
        self.showStatusBadges = showStatusBadges
        self.showWindowTitle = showWindowTitle
        self.highlightStyle = highlightStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AdvancedAppearanceSettings()
        maxRows = c.value(.maxRows, d.maxRows)
        maxColumns = c.value(.maxColumns, d.maxColumns)
        panelOpacity = c.value(.panelOpacity, d.panelOpacity)
        cornerRadius = c.value(.cornerRadius, d.cornerRadius)
        cellPadding = c.value(.cellPadding, d.cellPadding)
        titleFontSize = c.value(.titleFontSize, d.titleFontSize)
        showAppIconBadge = c.value(.showAppIconBadge, d.showAppIconBadge)
        showWindowCountBadge = c.value(.showWindowCountBadge, d.showWindowCountBadge)
        showStatusBadges = c.value(.showStatusBadges, d.showStatusBadges)
        showWindowTitle = c.value(.showWindowTitle, d.showWindowTitle)
        highlightStyle = c.value(.highlightStyle, d.highlightStyle)
    }

    public static let `default` = AdvancedAppearanceSettings()
}

/// The Appearance pane.
public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var style: SwitcherStyle
    public var size: SwitcherSize
    public var theme: SwitcherTheme
    public var afterRelease: AfterReleaseBehavior

    /// Dim or highlight the actual selected window on screen while the switcher is
    /// open, so it can be seen behind the overlay.
    public var previewSelectedWindow: Bool

    public var screenPlacement: ScreenPlacement
    public var animations: AnimationSettings
    public var advanced: AdvancedAppearanceSettings

    public init(
        style: SwitcherStyle = .thumbnails,
        size: SwitcherSize = .small,
        theme: SwitcherTheme = .system,
        afterRelease: AfterReleaseBehavior = .focus,
        previewSelectedWindow: Bool = false,
        screenPlacement: ScreenPlacement = .activeScreen,
        animations: AnimationSettings = .default,
        advanced: AdvancedAppearanceSettings = .default
    ) {
        self.style = style
        self.size = size
        self.theme = theme
        self.afterRelease = afterRelease
        self.previewSelectedWindow = previewSelectedWindow
        self.screenPlacement = screenPlacement
        self.animations = animations
        self.advanced = advanced
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        style = c.value(.style, d.style)
        size = c.value(.size, d.size)
        theme = c.value(.theme, d.theme)
        afterRelease = c.value(.afterRelease, d.afterRelease)
        previewSelectedWindow = c.value(.previewSelectedWindow, d.previewSelectedWindow)
        screenPlacement = c.value(.screenPlacement, d.screenPlacement)
        animations = c.value(.animations, d.animations)
        advanced = c.value(.advanced, d.advanced)
    }

    public static let `default` = AppearanceSettings()

    /// Applies a shortcut's per-shortcut overrides on top of these globals.
    public func merging(_ override: AppearanceOverride?) -> AppearanceSettings {
        guard let override else { return self }
        var result = self
        if let style = override.style { result.style = style }
        if let size = override.size { result.size = size }
        if let theme = override.theme { result.theme = theme }
        return result
    }
}

/// Concrete pixel dimensions derived from a `SwitcherSize`.
///
/// Kept out of the view layer so "Auto" — which depends on the window count — is
/// a plain function that can be reasoned about and tested rather than a layout
/// side effect.
public struct SwitcherMetrics: Equatable, Sendable {
    public let thumbnailWidth: Double
    public let thumbnailHeight: Double
    public let iconSize: Double
    public let titleRowHeight: Double

    /// Thumbnail aspect ratio. Matches a typical window rather than the screen, so
    /// previews are not letterboxed.
    static let aspectRatio: Double = 16.0 / 10.0

    public init(thumbnailWidth: Double, iconSize: Double, titleRowHeight: Double) {
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = (thumbnailWidth / Self.aspectRatio).rounded()
        self.iconSize = iconSize
        self.titleRowHeight = titleRowHeight
    }

    public static let small = SwitcherMetrics(thumbnailWidth: 160, iconSize: 48, titleRowHeight: 28)
    public static let medium = SwitcherMetrics(thumbnailWidth: 220, iconSize: 64, titleRowHeight: 34)
    public static let large = SwitcherMetrics(thumbnailWidth: 300, iconSize: 88, titleRowHeight: 42)

    /// Compact metrics used beyond twenty windows, where fitting everything on
    /// screen at once matters more than preview fidelity.
    public static let compact = SwitcherMetrics(thumbnailWidth: 120, iconSize: 36, titleRowHeight: 24)

    /// Resolves a size setting, scaling for the window count when set to Auto.
    ///
    /// Auto targets a roughly constant total panel area: generous previews when
    /// only a few windows are open, tighter ones as the list grows. Clamped at both
    /// ends so a single window does not fill the screen and forty do not become
    /// unrecognisable.
    public static func resolve(_ size: SwitcherSize, windowCount: Int) -> SwitcherMetrics {
        switch size {
        case .small:  return .small
        case .medium: return .medium
        case .large:  return .large
        case .auto:
            switch windowCount {
            case ..<0:    return .medium
            case 0...4:   return .large
            case 5...9:   return .medium
            case 10...20: return .small
            // Beyond twenty, shrink further rather than paginating — seeing
            // everything at once is the point of the grid.
            default:      return .compact
            }
        }
    }
}

/// Grid shape arithmetic for the overlay.
public enum SwitcherLayout {

    /// Chooses a column count for `itemCount` entries.
    ///
    /// Prefers a roughly square grid — easier to scan than one long line — then
    /// clamps to the user's maximums. When the two maximums cannot hold everything,
    /// columns win: a grid that is too wide still shows every window, whereas
    /// respecting `maxRows` strictly would have to hide some, and a switcher that
    /// silently omits a window is worse than one that is inconveniently shaped.
    public static func columnCount(forItemCount itemCount: Int,
                                   maxColumns: Int,
                                   maxRows: Int) -> Int {
        guard itemCount > 0 else { return 1 }

        let squareish = Int(Double(itemCount).squareRoot().rounded(.up))
        var columns = min(squareish, max(1, maxColumns))

        // If that would need more rows than allowed, widen until it fits.
        if maxRows > 0 {
            let rows = Int((Double(itemCount) / Double(columns)).rounded(.up))
            if rows > maxRows {
                columns = Int((Double(itemCount) / Double(maxRows)).rounded(.up))
            }
        }

        return max(1, min(columns, itemCount))
    }

    /// How many rows `itemCount` entries occupy at a given column count.
    public static func rowCount(forItemCount itemCount: Int, columns: Int) -> Int {
        guard itemCount > 0, columns > 0 else { return 0 }
        return Int((Double(itemCount) / Double(columns)).rounded(.up))
    }
}
