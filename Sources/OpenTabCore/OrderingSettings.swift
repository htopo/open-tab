import Foundation

/// How the switcher list is sorted.
public enum WindowOrdering: String, Codable, CaseIterable, Sendable {
    /// Default. The window you were on before this one is second in the list,
    /// which is what makes a quick tap a "go back" gesture.
    case mostRecentlyUsed
    case leastRecentlyUsed
    /// Stable across OpenTab restarts, unlike MRU, which only knows about focus
    /// changes it has observed since launch.
    case applicationLaunchOrder
    case alphabeticalByApp
    case spaceThenApp

    public var displayName: String {
        switch self {
        case .mostRecentlyUsed:       "Most recently used"
        case .leastRecentlyUsed:      "Least recently used"
        case .applicationLaunchOrder: "Application launch order"
        case .alphabeticalByApp:      "Alphabetical by app"
        case .spaceThenApp:           "Space then app"
        }
    }
}

/// The Ordering & Grouping tab of one shortcut.
public struct OrderingSettings: Codable, Equatable, Sendable {
    public var ordering: WindowOrdering

    /// Cluster every window of an application together, keeping the app's best
    /// position in the primary sort.
    public var groupByApplication: Bool

    /// Move the window that currently has focus to the front of the list.
    ///
    /// On by default: it makes the selection start on "where I am", so the first
    /// press of the trigger key lands on "where I was".
    public var activeWindowFirst: Bool

    public init(
        ordering: WindowOrdering = .mostRecentlyUsed,
        groupByApplication: Bool = false,
        activeWindowFirst: Bool = true
    ) {
        self.ordering = ordering
        self.groupByApplication = groupByApplication
        self.activeWindowFirst = activeWindowFirst
    }

    public static let `default` = OrderingSettings()
}
