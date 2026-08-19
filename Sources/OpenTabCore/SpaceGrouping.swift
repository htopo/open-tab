import Foundation

/// A contiguous run of one Desktop's windows inside the switcher list.
///
/// The overlay draws one column per section. Expressed as a range into the flat
/// list rather than as nested arrays so that selection stays a single integer —
/// every other part of the app, from the state machine to the event tap, works in
/// flat indices, and a two-dimensional selection would have to be threaded
/// through all of it for no benefit.
public struct SpaceSection: Equatable, Sendable {
    /// The user-facing number, as in "Desktop 3".
    public let number: Int
    public let range: Range<Int>
    /// The Desktop the user is currently on. Drawn first.
    public let isCurrent: Bool

    public init(number: Int, range: Range<Int>, isCurrent: Bool) {
        self.number = number
        self.range = range
        self.isCurrent = isCurrent
    }

    public var title: String { "Desktop \(number)" }
}

/// Splitting the switcher list into per-Desktop columns.
public enum SpaceGrouping {

    /// Assigns user-facing numbers to Space identifiers.
    ///
    /// The window server's Space IDs are opaque and do not start at one — a
    /// machine that has had Desktops added and removed can be sitting on IDs 1 and
    /// 7. They are allocated in creation order, so sorting them ascending and
    /// numbering from one reproduces Mission Control's order for anyone who has
    /// not dragged their Desktops around, and stays stable within a session for
    /// everyone else. That stability is what matters here: the numbers are how the
    /// user navigates, so they must not move between one press of the space bar
    /// and the next.
    public static func numbering(for spaceIDs: some Sequence<Int>) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (index, id) in Set(spaceIDs).sorted().enumerated() {
            result[id] = index + 1
        }
        return result
    }

    /// Reorders `windows` so each Desktop's windows are contiguous, and describes
    /// where each one starts and ends.
    ///
    /// The current Desktop comes first because it is the list the user was already
    /// looking at when they asked to see the others; the rest follow in Desktop
    /// order. Windows belonging to no Desktop — minimized and hidden ones, which
    /// the window server places nowhere — join the current Desktop's column, which
    /// is where they appear when the switcher is narrowed to one Desktop anyway.
    ///
    /// Order *within* a Desktop is untouched, so whatever sorting and grouping the
    /// list builder decided on still holds inside each column.
    public static func sectioned(
        _ windows: [WindowModel],
        currentSpaceID: Int?,
        numbering: [Int: Int]
    ) -> (windows: [WindowModel], sections: [SpaceSection]) {
        guard !windows.isEmpty else { return ([], []) }

        // Group, preserving order inside each bucket.
        var buckets: [Int?: [WindowModel]] = [:]
        var order: [Int?] = []
        for window in windows {
            let key: Int? = (window.spaceID == currentSpaceID) ? currentSpaceID : window.spaceID
            let bucket: Int? = (window.spaceID == nil) ? currentSpaceID : key
            if buckets[bucket] == nil { order.append(bucket) }
            buckets[bucket, default: []].append(window)
        }

        // Current Desktop first, then by Desktop number, then by raw ID for
        // anything the numbering does not know about.
        let sortedKeys = order.sorted { lhs, rhs in
            if lhs == currentSpaceID { return true }
            if rhs == currentSpaceID { return false }
            let l = lhs.flatMap { numbering[$0] } ?? Int.max
            let r = rhs.flatMap { numbering[$0] } ?? Int.max
            if l != r { return l < r }
            return (lhs ?? Int.max) < (rhs ?? Int.max)
        }

        var ordered: [WindowModel] = []
        var sections: [SpaceSection] = []
        ordered.reserveCapacity(windows.count)

        for key in sortedKeys {
            guard let group = buckets[key], !group.isEmpty else { continue }
            let start = ordered.count
            ordered.append(contentsOf: group)
            sections.append(
                SpaceSection(
                    number: key.flatMap { numbering[$0] } ?? 0,
                    range: start..<ordered.count,
                    isCurrent: key == currentSpaceID
                )
            )
        }

        return (ordered, sections)
    }
}
