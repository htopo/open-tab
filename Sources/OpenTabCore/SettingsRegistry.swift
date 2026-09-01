import Foundation

/// The four settings panes.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case appearance
    case controls
    case general
    case exceptions

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appearance: "Appearance"
        case .controls:   "Controls"
        case .general:    "General"
        case .exceptions: "Exceptions"
        }
    }

    public var symbolName: String {
        switch self {
        case .appearance: "paintpalette"
        case .controls:   "command"
        case .general:    "gearshape"
        case .exceptions: "hand.raised"
        }
    }
}

/// One searchable setting.
public struct SettingDescriptor: Identifiable, Equatable, Sendable {
    /// Stable across releases. Used to scroll to and highlight a match, so
    /// renaming one silently breaks a search result rather than failing loudly.
    public let id: String
    public let title: String
    public let pane: SettingsPane
    /// The group heading it appears under, shown in search results for context.
    public let section: String
    /// Extra terms that should find it. Deliberately includes the words users
    /// reach for rather than the words the UI uses — someone looking for "delay"
    /// should find "Hold threshold".
    public let keywords: [String]

    public init(id: String, title: String, pane: SettingsPane,
                section: String, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.pane = pane
        self.section = section
        self.keywords = keywords
    }
}

/// The one place every setting is registered.
///
/// The settings search field is a lookup over this rather than a hand-maintained
/// list of special cases, which is the only way a search across four panes and
/// roughly sixty controls stays correct as controls are added.
public enum SettingsRegistry {

    public static let all: [SettingDescriptor] = appearance + controls + general + exceptions

    // MARK: - Appearance

    static let appearance: [SettingDescriptor] = [
        .init(id: "appearance.style", title: "Style", pane: .appearance, section: "Appearance",
              keywords: ["thumbnails", "app icons", "titles", "look", "layout", "preview"]),
        .init(id: "appearance.size", title: "Size", pane: .appearance, section: "Appearance",
              keywords: ["small", "medium", "large", "auto", "scale", "big", "bigger", "smaller"]),
        .init(id: "appearance.theme", title: "Theme", pane: .appearance, section: "Appearance",
              keywords: ["light", "dark", "system", "colour", "color", "appearance", "mode"]),
        .init(id: "appearance.afterRelease", title: "After keys are released", pane: .appearance, section: "Appearance",
              keywords: ["focus", "hold", "search", "release", "let go", "commit"]),
        .init(id: "appearance.previewSelected", title: "Preview selected window", pane: .appearance, section: "Appearance",
              keywords: ["highlight", "dim", "show", "behind", "peek"]),
        .init(id: "appearance.showOn", title: "Show on", pane: .appearance, section: "Multiple screens",
              keywords: ["screen", "display", "monitor", "multiple", "mouse", "external"]),

        .init(id: "appearance.animations.fadeIn", title: "Fade in duration", pane: .appearance, section: "Animations",
              keywords: ["animation", "speed", "fast", "slow", "transition"]),
        .init(id: "appearance.animations.fadeOut", title: "Fade out duration", pane: .appearance, section: "Animations",
              keywords: ["animation", "speed", "fast", "slow", "transition", "dismiss"]),
        .init(id: "appearance.animations.selectionMove", title: "Animate selection movement", pane: .appearance, section: "Animations",
              keywords: ["animation", "highlight", "slide", "motion"]),
        .init(id: "appearance.animations.reduce", title: "Reduce animations", pane: .appearance, section: "Animations",
              keywords: ["motion", "accessibility", "disable", "off", "instant", "no animation"]),

        .init(id: "appearance.advanced.maxRows", title: "Maximum rows", pane: .appearance, section: "Customize more",
              keywords: ["grid", "layout", "height", "wrap"]),
        .init(id: "appearance.advanced.maxColumns", title: "Maximum columns", pane: .appearance, section: "Customize more",
              keywords: ["grid", "layout", "width", "wrap"]),
        .init(id: "appearance.advanced.opacity", title: "Panel opacity", pane: .appearance, section: "Customize more",
              keywords: ["transparency", "translucent", "alpha", "see through", "blur"]),
        .init(id: "appearance.advanced.cornerRadius", title: "Corner radius", pane: .appearance, section: "Customize more",
              keywords: ["rounded", "corners", "shape", "square"]),
        .init(id: "appearance.advanced.cellPadding", title: "Spacing between items", pane: .appearance, section: "Customize more",
              keywords: ["padding", "gap", "margin", "density", "tight"]),
        .init(id: "appearance.advanced.titleFontSize", title: "Title font size", pane: .appearance, section: "Customize more",
              keywords: ["text", "label", "type", "bigger", "smaller", "readable"]),
        .init(id: "appearance.advanced.appIconBadge", title: "Show app icon on thumbnails", pane: .appearance, section: "Customize more",
              keywords: ["badge", "overlay", "icon", "corner"]),
        .init(id: "appearance.advanced.windowCountBadge", title: "Show window count badge", pane: .appearance, section: "Customize more",
              keywords: ["badge", "number", "count", "grouped"]),
        .init(id: "appearance.advanced.statusBadges", title: "Show minimized and hidden badges", pane: .appearance, section: "Customize more",
              keywords: ["badge", "indicator", "minimized", "hidden", "fullscreen", "status"]),
        .init(id: "appearance.advanced.windowTitle", title: "Window titles", pane: .appearance, section: "Customize more",
              keywords: ["label", "caption", "name", "text", "file name", "document", "title", "project", "folder", "last part"]),
        .init(id: "appearance.advanced.shortenAppNames", title: "Shorten application names", pane: .appearance, section: "Customize more",
              keywords: ["short", "publisher", "vendor", "google", "chrome", "microsoft", "prefix", "name"]),
        .init(id: "appearance.advanced.highlightStyle", title: "Highlight style", pane: .appearance, section: "Customize more",
              keywords: ["selection", "border", "fill", "outline", "marker"]),
    ]

    // MARK: - Controls

    static let controls: [SettingDescriptor] = [
        .init(id: "controls.shortcuts", title: "Shortcuts", pane: .controls, section: "Controls",
              keywords: ["hotkey", "keyboard", "binding", "trigger", "command tab", "key"]),
        .init(id: "controls.trigger", title: "Trigger", pane: .controls, section: "Controls",
              keywords: ["hold", "press", "modifier", "key", "record", "bind"]),

        .init(id: "controls.filter.apps", title: "Show windows from applications", pane: .controls, section: "Filtering",
              keywords: ["filter", "all apps", "active app", "current app", "only"]),
        .init(id: "controls.filter.spaces", title: "Show windows from Spaces", pane: .controls, section: "Filtering",
              keywords: ["filter", "space", "desktop", "mission control", "virtual desktop"]),
        .init(id: "controls.filter.spacePeek", title: "Hold space to reveal other Spaces", pane: .controls, section: "Filtering",
              keywords: ["space bar", "peek", "desktop", "reveal", "hold", "other spaces", "temporarily"]),
        .init(id: "controls.filter.screens", title: "Show windows from screens", pane: .controls, section: "Filtering",
              keywords: ["filter", "display", "monitor", "screen"]),
        .init(id: "controls.filter.minimized", title: "Show minimized windows", pane: .controls, section: "Filtering",
              keywords: ["filter", "minimised", "dock", "hidden", "collapsed"]),
        .init(id: "controls.filter.hidden", title: "Show hidden windows", pane: .controls, section: "Filtering",
              keywords: ["filter", "hide", "command h", "invisible"]),
        .init(id: "controls.filter.fullscreen", title: "Show fullscreen windows", pane: .controls, section: "Filtering",
              keywords: ["filter", "full screen", "maximised", "maximized"]),
        .init(id: "controls.filter.noWindows", title: "Show apps with no open window", pane: .controls, section: "Filtering",
              keywords: ["filter", "empty", "application", "running", "no windows"]),

        .init(id: "controls.appearanceOverride", title: "Per-shortcut appearance", pane: .controls, section: "Appearance",
              keywords: ["override", "style", "size", "theme", "custom"]),

        .init(id: "controls.ordering.order", title: "Order", pane: .controls, section: "Ordering & Grouping",
              keywords: ["sort", "mru", "recent", "alphabetical", "launch", "space"]),
        .init(id: "controls.ordering.group", title: "Group windows by application", pane: .controls, section: "Ordering & Grouping",
              keywords: ["cluster", "together", "app", "sort"]),
        .init(id: "controls.ordering.activeFirst", title: "Put the active window first", pane: .controls, section: "Ordering & Grouping",
              keywords: ["current", "focused", "front", "sort", "first"]),

        .init(id: "controls.gesture", title: "Gesture", pane: .controls, section: "Controls",
              keywords: ["trackpad", "swipe", "fingers", "touch", "magic"]),

        .init(id: "controls.additional.holdThreshold", title: "Hold threshold", pane: .controls, section: "Additional controls",
              keywords: ["delay", "timing", "quick tap", "milliseconds", "responsive", "flash"]),
        .init(id: "controls.additional.hover", title: "Mouse hover selects", pane: .controls, section: "Additional controls",
              keywords: ["pointer", "cursor", "mouse", "highlight"]),
        .init(id: "controls.additional.clickOutside", title: "Click outside to dismiss", pane: .controls, section: "Additional controls",
              keywords: ["cancel", "close", "away", "mouse"]),
        .init(id: "controls.additional.scroll", title: "Scroll to navigate", pane: .controls, section: "Additional controls",
              keywords: ["wheel", "trackpad", "move", "cycle"]),
        .init(id: "controls.additional.escape", title: "Escape cancels", pane: .controls, section: "Additional controls",
              keywords: ["esc", "cancel", "abort", "close"]),
        .init(id: "controls.additional.wrap", title: "Wrap around at the ends", pane: .controls, section: "Additional controls",
              keywords: ["cycle", "loop", "clamp", "stop"]),
        .init(id: "controls.additional.shiftSteps", title: "Shift steps backwards", pane: .controls, section: "Additional controls",
              keywords: ["shift", "reverse", "back", "backwards", "previous", "shift tab", "direction"]),

        .init(id: "controls.active.close", title: "Close window", pane: .controls, section: "Shortcuts when active",
              keywords: ["command w", "quit window", "shut"]),
        .init(id: "controls.active.minimize", title: "Minimize window", pane: .controls, section: "Shortcuts when active",
              keywords: ["command m", "dock", "minimise"]),
        .init(id: "controls.active.quit", title: "Quit app", pane: .controls, section: "Shortcuts when active",
              keywords: ["command q", "terminate", "exit"]),
        .init(id: "controls.active.hide", title: "Hide app", pane: .controls, section: "Shortcuts when active",
              keywords: ["command h", "conceal"]),
        .init(id: "controls.active.fullscreen", title: "Toggle fullscreen", pane: .controls, section: "Shortcuts when active",
              keywords: ["command f", "full screen", "maximise", "maximize"]),
        .init(id: "controls.active.restoreSystem", title: "Restore system shortcuts", pane: .controls, section: "Controls",
              keywords: ["command tab", "repair", "fix", "broken", "reset", "recover", "system switcher"]),
    ]

    // MARK: - General

    static let general: [SettingDescriptor] = [
        .init(id: "general.startAtLogin", title: "Start at login", pane: .general, section: "General",
              keywords: ["launch", "startup", "boot", "automatic", "login item"]),
        .init(id: "general.menuBarIcon", title: "Menubar icon", pane: .general, section: "General",
              keywords: ["status", "menu bar", "tray", "icon", "hide", "show"]),
        .init(id: "general.backgroundCapture", title: "Capture windows in the background", pane: .general, section: "General",
              keywords: ["thumbnail", "screen recording", "purple", "indicator", "drm", "flicker", "privacy", "battery"]),
        .init(id: "general.language", title: "Language", pane: .general, section: "General",
              keywords: ["locale", "translation", "localisation", "localization"]),
        .init(id: "general.updates", title: "Updates policy", pane: .general, section: "General",
              keywords: ["version", "upgrade", "automatic", "sparkle", "check"]),
        .init(id: "general.checkNow", title: "Check for updates now", pane: .general, section: "General",
              keywords: ["version", "upgrade", "manual"]),
        .init(id: "general.export", title: "Export settings", pane: .general, section: "General",
              keywords: ["backup", "save", "json", "transfer", "share"]),
        .init(id: "general.import", title: "Import settings", pane: .general, section: "General",
              keywords: ["restore", "load", "json", "transfer"]),
        .init(id: "general.reset", title: "Reset settings and restart", pane: .general, section: "General",
              keywords: ["defaults", "factory", "clear", "wipe", "start over"]),
    ]

    // MARK: - Exceptions

    static let exceptions: [SettingDescriptor] = [
        .init(id: "exceptions.list", title: "Exceptions", pane: .exceptions, section: "Exceptions",
              keywords: ["per app", "rules", "bundle", "ignore", "block"]),
        .init(id: "exceptions.bundleID", title: "Bundle ID", pane: .exceptions, section: "Exceptions",
              keywords: ["identifier", "app", "com.", "package"]),
        .init(id: "exceptions.hideWindows", title: "Hide windows", pane: .exceptions, section: "Exceptions",
              keywords: ["exclude", "omit", "remove", "filter"]),
        .init(id: "exceptions.ignoreShortcuts", title: "Ignore shortcuts", pane: .exceptions, section: "Exceptions",
              keywords: ["pass through", "vm", "remote desktop", "rdp", "virtual machine", "guest", "parallels", "vmware"]),
    ]

    // MARK: - Search

    /// Finds settings matching typed text.
    ///
    /// Results are ranked so a title match beats a keyword match — someone typing
    /// "theme" wants the Theme control, not every setting that mentions colour.
    public static func search(_ query: String) -> [SettingDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let terms = trimmed.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }

        func score(_ descriptor: SettingDescriptor) -> Int? {
            var total = 0
            for term in terms {
                let title = descriptor.title.lowercased()
                if title.hasPrefix(term) {
                    total += 100
                } else if title.contains(term) {
                    total += 50
                } else if descriptor.section.lowercased().contains(term) {
                    total += 20
                } else if descriptor.keywords.contains(where: { $0.lowercased().contains(term) }) {
                    total += 10
                } else {
                    // Every term must match something, so a second word narrows
                    // the result set rather than widening it.
                    return nil
                }
            }
            return total
        }

        return all
            .compactMap { descriptor -> (SettingDescriptor, Int)? in
                score(descriptor).map { (descriptor, $0) }
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.title < rhs.0.title : lhs.1 > rhs.1
            }
            .map(\.0)
    }

    public static func descriptor(id: String) -> SettingDescriptor? {
        all.first { $0.id == id }
    }
}
