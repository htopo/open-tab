import Foundation

/// Whether an application's windows appear in the switcher.
public enum HideWindowsPolicy: String, Codable, CaseIterable, Sendable {
    case always
    case never
    case whenAppIsNotActive

    public var displayName: String {
        switch self {
        case .always:             "Always"
        case .never:              "Never"
        case .whenAppIsNotActive: "When app is not active"
        }
    }
}

/// Whether OpenTab's own shortcuts reach the application.
public enum IgnoreShortcutsPolicy: String, Codable, CaseIterable, Sendable {
    case always
    case never
    case whenAppIsFullscreen

    public var displayName: String {
        switch self {
        case .always:              "Always"
        case .never:               "Never"
        case .whenAppIsFullscreen: "When app is fullscreen"
        }
    }
}

/// A per-application rule.
public struct ExceptionRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var hideWindows: HideWindowsPolicy
    public var ignoreShortcuts: IgnoreShortcutsPolicy

    public init(
        id: UUID = UUID(),
        bundleID: String,
        hideWindows: HideWindowsPolicy = .never,
        ignoreShortcuts: IgnoreShortcutsPolicy = .never
    ) {
        self.id = id
        self.bundleID = bundleID
        self.hideWindows = hideWindows
        self.ignoreShortcuts = ignoreShortcuts
    }

    /// Rules shipped out of the box.
    ///
    /// All of these are remote-desktop or virtual-machine clients, where ⌘Tab has
    /// to reach the *guest* operating system. Without these entries OpenTab would
    /// intercept the switcher inside the VM, which is both surprising and hard for
    /// a user to diagnose — so it is configured correctly before they ever hit it.
    public static let shippedDefaults: [ExceptionRule] = [
        "com.microsoft.rdc.macos",
        "com.teamviewer.TeamViewer",
        "org.virtualbox.app.VirtualBoxVM",
        "com.parallels.desktop.console",
        "com.citrix.XenAppViewer",
        "com.vmware.fusion",
        "com.nicesoftware.dcvviewer",
        "com.realvnc.vncviewer",
    ].map { ExceptionRule(bundleID: $0, ignoreShortcuts: .always) }
}

/// Applies exception rules.
///
/// Matching is exact on bundle identifier rather than by prefix. A prefix rule for
/// `com.microsoft` would silently cover Word, Excel, and Teams as well as Remote
/// Desktop, which is not what anyone adding one rule intends.
public enum ExceptionEngine {

    /// Context for evaluating a rule against the current moment.
    public struct Context: Equatable, Sendable {
        public var frontmostBundleID: String?
        /// Bundle IDs of applications currently showing a fullscreen window.
        public var fullscreenBundleIDs: Set<String>

        public init(frontmostBundleID: String? = nil,
                    fullscreenBundleIDs: Set<String> = []) {
            self.frontmostBundleID = frontmostBundleID
            self.fullscreenBundleIDs = fullscreenBundleIDs
        }

        public static let empty = Context()
    }

    public static func rule(for bundleID: String, in rules: [ExceptionRule]) -> ExceptionRule? {
        guard !bundleID.isEmpty else { return nil }
        return rules.first { $0.bundleID == bundleID }
    }

    /// Whether OpenTab should pass its shortcuts through untouched right now.
    ///
    /// Evaluated against the *frontmost* application, because that is who would
    /// receive the keystroke.
    public static func shouldIgnoreShortcuts(rules: [ExceptionRule],
                                             context: Context) -> Bool {
        guard let frontmost = context.frontmostBundleID,
              let rule = rule(for: frontmost, in: rules)
        else { return false }

        switch rule.ignoreShortcuts {
        case .never:
            return false
        case .always:
            return true
        case .whenAppIsFullscreen:
            return context.fullscreenBundleIDs.contains(frontmost)
        }
    }

    /// Whether a window should be excluded from the switcher list.
    public static func shouldHideWindow(_ window: WindowModel,
                                        rules: [ExceptionRule],
                                        context: Context) -> Bool {
        guard let rule = rule(for: window.appBundleID, in: rules) else { return false }

        switch rule.hideWindows {
        case .never:
            return false
        case .always:
            return true
        case .whenAppIsNotActive:
            return context.frontmostBundleID != window.appBundleID
        }
    }

    /// Removes windows hidden by an exception rule.
    public static func filter(_ windows: [WindowModel],
                              rules: [ExceptionRule],
                              context: Context) -> [WindowModel] {
        guard !rules.isEmpty else { return windows }
        return windows.filter { !shouldHideWindow($0, rules: rules, context: context) }
    }
}
