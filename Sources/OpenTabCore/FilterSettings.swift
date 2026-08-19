import CoreGraphics
import Foundation

// MARK: - Scopes

/// Which applications' windows to include.
public enum AppScope: String, Codable, CaseIterable, Sendable {
    case allApps
    case activeApp
    case allAppsExceptActive

    public var displayName: String {
        switch self {
        case .allApps:            "All apps"
        case .activeApp:          "Active app"
        case .allAppsExceptActive: "All apps except active"
        }
    }
}

/// Which Spaces' windows to include.
public enum SpaceScope: String, Codable, CaseIterable, Sendable {
    case allSpaces
    case activeSpace
    case visibleSpaces

    public var displayName: String {
        switch self {
        case .allSpaces:     "All Spaces"
        case .activeSpace:   "Active Space"
        case .visibleSpaces: "Visible Spaces"
        }
    }
}

/// Which screens' windows to include.
public enum ScreenScope: String, Codable, CaseIterable, Sendable {
    case allScreens
    case activeScreen

    public var displayName: String {
        switch self {
        case .allScreens:   "All screens"
        case .activeScreen: "Active screen"
        }
    }
}

/// What to do with a category of window.
///
/// `showAtEnd` is not a filter but a sort hint: the windows stay in the list and
/// are pushed past everything else, which is how "I rarely want these but
/// sometimes I do" is expressed without a second gesture.
public enum VisibilityPolicy: String, Codable, CaseIterable, Sendable {
    case show
    case hide
    case showAtEnd

    public var displayName: String {
        switch self {
        case .show:      "Show"
        case .hide:      "Hide"
        case .showAtEnd: "Show at the end"
        }
    }
}

// MARK: - Settings

/// The Filtering tab of one shortcut. Each shortcut carries its own copy, which
/// is what lets a user bind ⌘Tab to "everything" and ⌥Tab to "this app only".
public struct FilterSettings: Codable, Equatable, Sendable {
    public var apps: AppScope
    public var spaces: SpaceScope
    public var screens: ScreenScope
    public var minimized: VisibilityPolicy
    public var hidden: VisibilityPolicy
    public var fullscreen: VisibilityPolicy
    public var appsWithNoWindows: VisibilityPolicy

    /// Holding the space bar while the switcher is open widens the list to every
    /// Space, for as long as it is held.
    ///
    /// A peek rather than a mode: narrowing to the current Space is the useful
    /// default, but "where did that other window go" is a real question and
    /// answering it should not mean closing the switcher and changing a setting.
    /// Does nothing when `spaces` is already `.allSpaces` — there would be
    /// nothing to reveal — which is also why the space bar is left alone as a
    /// typed character in that case.
    public var spaceKeyRevealsOtherSpaces: Bool

    public init(
        apps: AppScope = .allApps,
        spaces: SpaceScope = .allSpaces,
        screens: ScreenScope = .allScreens,
        minimized: VisibilityPolicy = .show,
        hidden: VisibilityPolicy = .show,
        fullscreen: VisibilityPolicy = .show,
        appsWithNoWindows: VisibilityPolicy = .showAtEnd,
        spaceKeyRevealsOtherSpaces: Bool = true
    ) {
        self.apps = apps
        self.spaces = spaces
        self.screens = screens
        self.minimized = minimized
        self.hidden = hidden
        self.fullscreen = fullscreen
        self.appsWithNoWindows = appsWithNoWindows
        self.spaceKeyRevealsOtherSpaces = spaceKeyRevealsOtherSpaces
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilterSettings()
        apps = c.value(.apps, d.apps)
        spaces = c.value(.spaces, d.spaces)
        screens = c.value(.screens, d.screens)
        minimized = c.value(.minimized, d.minimized)
        hidden = c.value(.hidden, d.hidden)
        fullscreen = c.value(.fullscreen, d.fullscreen)
        appsWithNoWindows = c.value(.appsWithNoWindows, d.appsWithNoWindows)
        spaceKeyRevealsOtherSpaces = c.value(.spaceKeyRevealsOtherSpaces, d.spaceKeyRevealsOtherSpaces)
    }

    public static let `default` = FilterSettings()

    /// Whether holding space would actually change this list.
    public var canRevealOtherSpaces: Bool {
        spaceKeyRevealsOtherSpaces && spaces != .allSpaces
    }

    /// Shown under the "Hold space to reveal other Spaces" toggle.
    public static let spacePeekExplanation = """
        While the switcher is open, holding the space bar widens the list to \
        every Space until you let go. Only applies when the list is narrowed \
        above.
        """
}

// MARK: - Context

/// The "where am I right now" facts the scope filters resolve against.
///
/// Captured once when the switcher opens rather than read per window, so that a
/// Space change mid-build cannot produce a list filtered against two different
/// worlds.
public struct FilterContext: Equatable, Sendable {
    /// The frontmost application at the moment the switcher was invoked — not
    /// OpenTab itself, which never activates.
    public var activePID: pid_t?
    public var activeSpaceID: Int?
    /// Spaces currently visible across all displays. On a multi-display setup with
    /// separate Spaces there is more than one.
    public var visibleSpaceIDs: Set<Int>
    public var activeDisplayID: CGDirectDisplayID?

    public init(
        activePID: pid_t? = nil,
        activeSpaceID: Int? = nil,
        visibleSpaceIDs: Set<Int> = [],
        activeDisplayID: CGDirectDisplayID? = nil
    ) {
        self.activePID = activePID
        self.activeSpaceID = activeSpaceID
        self.visibleSpaceIDs = visibleSpaceIDs
        self.activeDisplayID = activeDisplayID
    }

    public static let empty = FilterContext()
}
