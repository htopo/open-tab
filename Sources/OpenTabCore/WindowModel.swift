import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Identity of a switchable entry.
///
/// A `CGWindowID` alone is not enough: IDs are recycled by the window server, and
/// entries that represent a whole application have no window at all. Pairing it
/// with the owning pid makes collisions across process lifetimes impossible.
public struct WindowID: Hashable, Sendable {
    /// The window server's ID, or 0 for an application-level entry.
    public let cgWindowID: CGWindowID
    public let pid: pid_t

    public init(cgWindowID: CGWindowID, pid: pid_t) {
        self.cgWindowID = cgWindowID
        self.pid = pid
    }

    /// Identity for an application that has no open windows.
    public static func application(pid: pid_t) -> WindowID {
        WindowID(cgWindowID: 0, pid: pid)
    }
}

/// What a switcher entry represents.
///
/// Modelling "app with no open windows" as a kind of entry rather than a separate
/// list keeps ordering, filtering, selection, and rendering working on one
/// homogeneous array. The alternative — a sum type — pushes a switch into every
/// one of those, for a case that differs only in what committing it does.
public enum WindowKind: Sendable, Equatable {
    case window
    case applicationWithNoWindows
}

/// One entry in the switcher.
///
/// Deliberately a value type. The registry rebuilds and mutates these on a
/// background queue and hands snapshots to the UI; sharing reference types across
/// that boundary is how switchers end up rendering half-updated state.
public struct WindowModel: Identifiable {

    public let id: WindowID
    public let kind: WindowKind

    /// The accessibility element for this window, or the application element for
    /// an application entry. Optional so that models can be constructed in tests,
    /// where no real element exists.
    public let axElement: AXUIElement?

    public var title: String
    public var appBundleID: String
    public var appName: String
    public var appIcon: NSImage?

    public var isMinimized: Bool
    /// True when the *owning application* is hidden (⌘H), not the window itself.
    public var isHidden: Bool
    public var isFullscreen: Bool

    /// nil when the Space cannot be determined — either the private symbol is
    /// unavailable or the window is not currently on any Space.
    public var spaceID: Int?
    public var displayID: CGDirectDisplayID?

    public var frame: CGRect

    /// Drives most-recently-used ordering. Set when the window takes focus.
    public var lastFocusedAt: Date

    /// True for the window that currently has focus.
    public var isFocused: Bool

    public init(
        id: WindowID,
        kind: WindowKind = .window,
        axElement: AXUIElement? = nil,
        title: String = "",
        appBundleID: String = "",
        appName: String = "",
        appIcon: NSImage? = nil,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        isFullscreen: Bool = false,
        spaceID: Int? = nil,
        displayID: CGDirectDisplayID? = nil,
        frame: CGRect = .zero,
        lastFocusedAt: Date = .distantPast,
        isFocused: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.axElement = axElement
        self.title = title
        self.appBundleID = appBundleID
        self.appName = appName
        self.appIcon = appIcon
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.isFullscreen = isFullscreen
        self.spaceID = spaceID
        self.displayID = displayID
        self.frame = frame
        self.lastFocusedAt = lastFocusedAt
        self.isFocused = isFocused
    }

    // MARK: - Derived

    /// What the switcher shows under a thumbnail. Falls back to the app name,
    /// because plenty of windows legitimately have no title.
    public var displayTitle: String {
        title.isEmpty ? appName : title
    }

    /// The "AppName — Window Title" form used by the Titles style.
    public var qualifiedTitle: String {
        if title.isEmpty || title == appName { return appName }
        return "\(appName) — \(title)"
    }

    /// The label for this window, as the appearance settings ask for it.
    ///
    /// Search deliberately does not go through this: someone typing "google" must
    /// still find Chrome, and someone typing part of a file name must still find
    /// its window, whether or not either is currently on screen. Hiding something
    /// is a display decision, not a change to what exists.
    public func displayLabel(shortenAppName: Bool, windowTitle: WindowTitleDisplay) -> String {
        let name = AppDisplayName.display(appName, shorten: shortenAppName)
        guard let suffix = WindowTitleFormatter.title(title, appName: appName, display: windowTitle)
        else { return name }
        return "\(name) — \(suffix)"
    }

    /// Text matched against when the user types to filter.
    public var searchableText: String {
        "\(appName) \(title)"
    }

    public var isApplicationEntry: Bool {
        kind == .applicationWithNoWindows
    }
}

/// Window models are handed between the discovery queue and the main actor.
///
/// The compiler cannot prove this is safe because of two members: `axElement` is
/// a CFType, and `appIcon` is an `NSImage`. Both are treated as immutable handles
/// here — the element is only ever passed back to the thread-safe AX API, and the
/// icon comes from `NSRunningApplication` and is never drawn into. Everything
/// else in the struct is a value type.
extension WindowModel: @unchecked Sendable {}

extension WindowModel: Equatable {
    /// Compared by identity and the fields that affect rendering. `axElement` and
    /// `appIcon` are excluded: they are reference-ish handles whose identity says
    /// nothing useful about whether the UI needs to redraw.
    public static func == (lhs: WindowModel, rhs: WindowModel) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.appBundleID == rhs.appBundleID
            && lhs.appName == rhs.appName
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isHidden == rhs.isHidden
            && lhs.isFullscreen == rhs.isFullscreen
            && lhs.spaceID == rhs.spaceID
            && lhs.displayID == rhs.displayID
            && lhs.frame == rhs.frame
            && lhs.isFocused == rhs.isFocused
    }
}

/// A running application that owns zero or more windows.
///
/// `@unchecked Sendable` for the same reason as `WindowModel`: the only
/// non-Sendable member is an `NSImage` that is read but never mutated.
public struct AppModel: Identifiable, Equatable, @unchecked Sendable {
    public let id: pid_t
    public var bundleID: String
    public var name: String
    public var icon: NSImage?
    public var isHidden: Bool
    public var isActive: Bool

    /// Drives the "Application launch order" sort. `NSRunningApplication` exposes
    /// this directly, so it survives across OpenTab restarts — unlike MRU, which
    /// only knows about focus changes observed since launch.
    public var launchedAt: Date

    public init(
        id: pid_t,
        bundleID: String = "",
        name: String = "",
        icon: NSImage? = nil,
        isHidden: Bool = false,
        isActive: Bool = false,
        launchedAt: Date = .distantPast
    ) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.isHidden = isHidden
        self.isActive = isActive
        self.launchedAt = launchedAt
    }

    public static func == (lhs: AppModel, rhs: AppModel) -> Bool {
        lhs.id == rhs.id
            && lhs.bundleID == rhs.bundleID
            && lhs.name == rhs.name
            && lhs.isHidden == rhs.isHidden
            && lhs.isActive == rhs.isActive
            && lhs.launchedAt == rhs.launchedAt
    }
}
