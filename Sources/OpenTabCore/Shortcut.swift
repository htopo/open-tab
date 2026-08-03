import Foundation

/// One configured shortcut.
///
/// Each carries its own filtering, ordering, and appearance, which is what lets a
/// user bind ⌘Tab to "every window everywhere" and ⌥` to "this app's windows on
/// this Space" and have both feel like purpose-built tools.
public struct Shortcut: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var combo: KeyCombo
    public var isEnabled: Bool

    public var filter: FilterSettings
    public var ordering: OrderingSettings

    /// Per-shortcut appearance, or nil to use the global settings.
    public var appearance: AppearanceOverride?

    public init(
        id: UUID = UUID(),
        name: String,
        combo: KeyCombo,
        isEnabled: Bool = true,
        filter: FilterSettings = .default,
        ordering: OrderingSettings = .default,
        appearance: AppearanceOverride? = nil
    ) {
        self.id = id
        self.name = name
        self.combo = combo
        self.isEnabled = isEnabled
        self.filter = filter
        self.ordering = ordering
        self.appearance = appearance
    }

    /// The maximum number of shortcuts the UI allows.
    public static let maximumCount = 9

    /// ⌘Tab, replacing the system application switcher.
    public static func defaultFirst() -> Shortcut {
        Shortcut(name: "Shortcut 1", combo: .commandTab)
    }

    /// ⌥`, which macOS does not reserve, so it works even if the symbolic-hotkey
    /// takeover is unavailable.
    public static func defaultSecond() -> Shortcut {
        Shortcut(name: "Shortcut 2", combo: .optionBacktick)
    }

    public static func defaults() -> [Shortcut] {
        [defaultFirst(), defaultSecond()]
    }
}

/// Per-shortcut appearance overrides. A nil field means "use the global setting".
public struct AppearanceOverride: Codable, Equatable, Sendable {
    public var style: SwitcherStyle?
    public var size: SwitcherSize?
    public var theme: SwitcherTheme?

    public init(style: SwitcherStyle? = nil,
                size: SwitcherSize? = nil,
                theme: SwitcherTheme? = nil) {
        self.style = style
        self.size = size
        self.theme = theme
    }

    public var isEmpty: Bool { style == nil && size == nil && theme == nil }
}

/// The three switcher looks.
public enum SwitcherStyle: String, Codable, CaseIterable, Sendable {
    /// Grid of live window previews with app icon, title, and badges.
    case thumbnails
    /// Compact dock-like row of large app icons.
    case appIcons
    /// Vertical list of "AppName — Window Title" rows.
    case titles

    public var displayName: String {
        switch self {
        case .thumbnails: "Thumbnails"
        case .appIcons:   "App Icons"
        case .titles:     "Titles"
        }
    }
}

public enum SwitcherSize: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case large
    /// Scales to the window count — larger when few windows, smaller when many —
    /// targeting a stable overall panel area.
    case auto

    public var displayName: String {
        switch self {
        case .small:  "Small"
        case .medium: "Medium"
        case .large:  "Large"
        case .auto:   "Auto"
        }
    }
}

/// Duplicated from the UI layer's `ThemePreference` so that OpenTabCore does not
/// depend on OpenTabUI; the UI maps between them.
public enum SwitcherTheme: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case system

    public var displayName: String {
        switch self {
        case .light:  "Light"
        case .dark:   "Dark"
        case .system: "System"
        }
    }
}
