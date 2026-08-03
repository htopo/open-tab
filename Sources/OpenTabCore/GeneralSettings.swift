import Foundation

/// How OpenTab handles its own updates.
public enum UpdatePolicy: String, Codable, CaseIterable, Sendable {
    case autoInstall
    case checkAndNotify
    case never

    public var displayName: String {
        switch self {
        case .autoInstall:    "Auto-install updates periodically"
        case .checkAndNotify: "Check for updates and notify"
        case .never:          "Never check for updates"
        }
    }

    public var checksAutomatically: Bool { self != .never }
    public var downloadsAutomatically: Bool { self == .autoInstall }
}

/// Which glyph the menu-bar item uses.
public enum MenuBarIconVariant: String, Codable, CaseIterable, Sendable {
    case windows
    case arrows
    case grid

    public var symbolName: String {
        switch self {
        case .windows: "macwindow.on.rectangle"
        case .arrows:  "arrow.left.arrow.right"
        case .grid:    "square.grid.2x2"
        }
    }

    public var displayName: String {
        switch self {
        case .windows: "Windows"
        case .arrows:  "Arrows"
        case .grid:    "Grid"
        }
    }
}

/// The General pane.
public struct GeneralSettings: Codable, Equatable, Sendable {
    public var startAtLogin: Bool
    public var showMenuBarIcon: Bool
    public var menuBarIconVariant: MenuBarIconVariant

    /// Refresh thumbnails on a timer rather than only at switcher-open time.
    ///
    /// Turning this off avoids the macOS purple screen-recording indicator and
    /// the flicker it causes in DRM-protected video, at the cost of staler
    /// thumbnails. Users who notice either of those care about them a lot.
    public var captureWindowsInBackground: Bool

    /// BCP-47 language code, or nil to follow the system.
    public var languageCode: String?

    public var updatePolicy: UpdatePolicy

    public init(
        startAtLogin: Bool = true,
        showMenuBarIcon: Bool = false,
        menuBarIconVariant: MenuBarIconVariant = .windows,
        captureWindowsInBackground: Bool = true,
        languageCode: String? = nil,
        updatePolicy: UpdatePolicy = .checkAndNotify
    ) {
        self.startAtLogin = startAtLogin
        self.showMenuBarIcon = showMenuBarIcon
        self.menuBarIconVariant = menuBarIconVariant
        self.captureWindowsInBackground = captureWindowsInBackground
        self.languageCode = languageCode
        self.updatePolicy = updatePolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        startAtLogin = c.value(.startAtLogin, d.startAtLogin)
        showMenuBarIcon = c.value(.showMenuBarIcon, d.showMenuBarIcon)
        menuBarIconVariant = c.value(.menuBarIconVariant, d.menuBarIconVariant)
        captureWindowsInBackground = c.value(.captureWindowsInBackground, d.captureWindowsInBackground)
        languageCode = c.optionalValue(.languageCode)
        updatePolicy = c.value(.updatePolicy, d.updatePolicy)
    }

    public static let `default` = GeneralSettings()

    /// The exact explanatory text the spec calls for under "Capture windows in
    /// the background".
    public static let backgroundCaptureExplanation = """
        When disabled, avoids the macOS purple screen-recording indicator, and \
        avoids flickers when playing DRM video. Thumbnails will be less up-to-date.
        """
}

/// The trackpad gesture trigger. Ships disabled.
public struct GestureSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Three or four fingers.
    public var fingerCount: Int

    public init(isEnabled: Bool = false, fingerCount: Int = 3) {
        self.isEnabled = isEnabled
        self.fingerCount = fingerCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureSettings()
        isEnabled = c.value(.isEnabled, d.isEnabled)
        fingerCount = c.value(.fingerCount, d.fingerCount)
    }

    public static let `default` = GestureSettings()
}
