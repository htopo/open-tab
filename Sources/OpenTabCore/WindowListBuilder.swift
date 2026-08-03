import CoreGraphics
import Foundation

/// Turns the raw window registry into the ordered list the switcher displays.
///
/// The pipeline runs in a fixed order, and the order is load-bearing:
///
///   1. **Exclude** — scope filters and `.hide` policies remove entries entirely.
///   2. **Sort** — the primary ordering is applied to what survived.
///   3. **Group** — windows of one application are clustered, if enabled.
///   4. **Defer** — `.showAtEnd` categories are moved past everything else.
///   5. **Promote** — the focused window is pulled to the front, if enabled.
///
/// Sorting before deferring is what lets "show minimized at the end" keep the
/// minimized windows in MRU order among themselves. Deferring before promoting
/// means an explicit "active window first" always wins, which is what a user who
/// turned that on expects.
///
/// Every stage is a pure function of its input, so the whole thing is exercised
/// in tests without a running window server.
public enum WindowListBuilder {

    public static func build(
        windows: [WindowModel],
        apps: [pid_t: AppModel] = [:],
        filter: FilterSettings = .default,
        ordering: OrderingSettings = .default,
        context: FilterContext = .empty
    ) -> [WindowModel] {
        var result = exclude(windows, filter: filter, context: context)
        result = sort(result, apps: apps, ordering: ordering.ordering)
        if ordering.groupByApplication {
            result = groupByApplication(result)
        }
        result = defer_(result, filter: filter)
        if ordering.activeWindowFirst {
            result = promoteFocused(result, grouped: ordering.groupByApplication)
        }
        return result
    }

    // MARK: - 1. Exclude

    static func exclude(_ windows: [WindowModel],
                        filter: FilterSettings,
                        context: FilterContext) -> [WindowModel] {
        windows.filter { window in
            isInScope(window, filter: filter, context: context)
                && !isHiddenByPolicy(window, filter: filter)
        }
    }

    private static func isInScope(_ window: WindowModel,
                                  filter: FilterSettings,
                                  context: FilterContext) -> Bool {
        // Application scope.
        switch filter.apps {
        case .allApps:
            break
        case .activeApp:
            guard let active = context.activePID, window.id.pid == active else { return false }
        case .allAppsExceptActive:
            if let active = context.activePID, window.id.pid == active { return false }
        }

        // Space scope. A window whose Space is unknown — because the private symbol
        // is unavailable, or because it is minimized and therefore on no Space — is
        // kept rather than dropped. Silently hiding windows when a lookup degrades
        // is worse than showing one too many.
        switch filter.spaces {
        case .allSpaces:
            break
        case .activeSpace:
            if let space = window.spaceID, let active = context.activeSpaceID, space != active {
                return false
            }
        case .visibleSpaces:
            if let space = window.spaceID, !context.visibleSpaceIDs.isEmpty,
               !context.visibleSpaceIDs.contains(space) {
                return false
            }
        }

        // Screen scope, with the same "unknown means keep" rule.
        switch filter.screens {
        case .allScreens:
            break
        case .activeScreen:
            if let display = window.displayID, let active = context.activeDisplayID, display != active {
                return false
            }
        }

        return true
    }

    private static func isHiddenByPolicy(_ window: WindowModel, filter: FilterSettings) -> Bool {
        if window.isApplicationEntry {
            return filter.appsWithNoWindows == .hide
        }
        if window.isMinimized && filter.minimized == .hide { return true }
        if window.isHidden && filter.hidden == .hide { return true }
        if window.isFullscreen && filter.fullscreen == .hide { return true }
        return false
    }

    // MARK: - 2. Sort

    static func sort(_ windows: [WindowModel],
                     apps: [pid_t: AppModel],
                     ordering: WindowOrdering) -> [WindowModel] {
        switch ordering {
        case .mostRecentlyUsed:
            return windows.stableSorted { $0.lastFocusedAt > $1.lastFocusedAt }

        case .leastRecentlyUsed:
            return windows.stableSorted { $0.lastFocusedAt < $1.lastFocusedAt }

        case .applicationLaunchOrder:
            return windows.stableSorted { lhs, rhs in
                let l = apps[lhs.id.pid]?.launchedAt ?? .distantPast
                let r = apps[rhs.id.pid]?.launchedAt ?? .distantPast
                if l != r { return l < r }
                // Within one app, fall back to MRU so the ordering is still useful.
                return lhs.lastFocusedAt > rhs.lastFocusedAt
            }

        case .alphabeticalByApp:
            return windows.stableSorted { lhs, rhs in
                let byApp = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
                if byApp != .orderedSame { return byApp == .orderedAscending }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

        case .spaceThenApp:
            return windows.stableSorted { lhs, rhs in
                // Windows with no known Space sort last; they are the minimized and
                // hidden ones, which are the least likely target.
                let l = lhs.spaceID ?? Int.max
                let r = rhs.spaceID ?? Int.max
                if l != r { return l < r }
                let byApp = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
                if byApp != .orderedSame { return byApp == .orderedAscending }
                return lhs.lastFocusedAt > rhs.lastFocusedAt
            }
        }
    }

    // MARK: - 3. Group

    /// Clusters windows by application, keeping each application at the position of
    /// its best-ranked window.
    static func groupByApplication(_ windows: [WindowModel]) -> [WindowModel] {
        var order: [pid_t] = []
        var buckets: [pid_t: [WindowModel]] = [:]

        for window in windows {
            if buckets[window.id.pid] == nil {
                order.append(window.id.pid)
                buckets[window.id.pid] = []
            }
            buckets[window.id.pid]?.append(window)
        }

        return order.flatMap { buckets[$0] ?? [] }
    }

    // MARK: - 4. Defer

    /// Moves `.showAtEnd` categories past everything else, preserving relative
    /// order within each tier.
    static func defer_(_ windows: [WindowModel], filter: FilterSettings) -> [WindowModel] {
        // A window can match more than one deferring policy (minimized *and*
        // hidden). It only needs to be deferred once, so tiers are coarse:
        // regular entries, then deferred windows, then deferred application
        // entries — which are the least useful thing in the list.
        func tier(_ window: WindowModel) -> Int {
            if window.isApplicationEntry {
                return filter.appsWithNoWindows == .showAtEnd ? 2 : 0
            }
            let deferred =
                (window.isMinimized && filter.minimized == .showAtEnd)
                || (window.isHidden && filter.hidden == .showAtEnd)
                || (window.isFullscreen && filter.fullscreen == .showAtEnd)
            return deferred ? 1 : 0
        }

        return windows.stableSorted { tier($0) < tier($1) }
    }

    // MARK: - 5. Promote

    /// Pulls the focused window to the front.
    ///
    /// With grouping enabled the whole application group moves, so that promoting
    /// one window does not tear its siblings away from it.
    static func promoteFocused(_ windows: [WindowModel], grouped: Bool) -> [WindowModel] {
        guard let focusedIndex = windows.firstIndex(where: \.isFocused) else { return windows }
        let focused = windows[focusedIndex]

        guard grouped else {
            var result = windows
            result.remove(at: focusedIndex)
            result.insert(focused, at: 0)
            return result
        }

        let group = windows.filter { $0.id.pid == focused.id.pid }
        let rest = windows.filter { $0.id.pid != focused.id.pid }
        let reorderedGroup = [focused] + group.filter { $0.id != focused.id }
        return reorderedGroup + rest
    }

    // MARK: - Search

    /// Narrows a built list to entries matching typed text.
    ///
    /// Matching is case- and diacritic-insensitive, and every whitespace-separated
    /// term must appear somewhere in the app name or window title. Requiring all
    /// terms lets "saf inv" find "Safari — Invoice" without matching everything
    /// that merely contains "s".
    public static func search(_ windows: [WindowModel], query: String) -> [WindowModel] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return windows }

        return windows.filter { window in
            let haystack = window.searchableText
            return terms.allSatisfy { term in
                haystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

// MARK: - Stable sorting

extension Array {
    /// A stable sort.
    ///
    /// `Array.sort` is not guaranteed stable, and instability here is visible to
    /// the user: two windows with identical focus timestamps would swap places
    /// between one press of the shortcut and the next.
    func stableSorted(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Element] {
        try enumerated()
            .sorted { lhs, rhs in
                if try areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if try areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
