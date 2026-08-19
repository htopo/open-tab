import CoreGraphics
import Foundation
import Testing
@testable import OpenTabCore

// MARK: - Fixtures

/// Builds window models without touching a real window server.
///
/// `axElement` and `appIcon` stay nil throughout; nothing in the list pipeline
/// reads them, which is precisely why the pipeline is a pure function.
private enum Fixture {

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// - Parameter age: seconds before `epoch` that this window last had focus.
    ///   Larger means older, so `age: 0` is the most recently used.
    static func window(
        _ cgID: CGWindowID,
        pid: pid_t = 100,
        app: String = "Safari",
        title: String = "",
        age: TimeInterval = 0,
        minimized: Bool = false,
        hidden: Bool = false,
        fullscreen: Bool = false,
        space: Int? = 1,
        display: CGDirectDisplayID? = 1,
        focused: Bool = false,
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> WindowModel {
        WindowModel(
            id: WindowID(cgWindowID: cgID, pid: pid),
            kind: .window,
            title: title.isEmpty ? "\(app) window \(cgID)" : title,
            appBundleID: "com.example.\(app.lowercased())",
            appName: app,
            isMinimized: minimized,
            isHidden: hidden,
            isFullscreen: fullscreen,
            spaceID: space,
            displayID: display,
            frame: frame,
            lastFocusedAt: epoch.addingTimeInterval(-age),
            isFocused: focused
        )
    }

    static func appEntry(pid: pid_t, app: String) -> WindowModel {
        WindowModel(
            id: .application(pid: pid),
            kind: .applicationWithNoWindows,
            appBundleID: "com.example.\(app.lowercased())",
            appName: app
        )
    }

    static func app(_ pid: pid_t, name: String, launchedAgo: TimeInterval) -> AppModel {
        AppModel(
            id: pid,
            bundleID: "com.example.\(name.lowercased())",
            name: name,
            launchedAt: epoch.addingTimeInterval(-launchedAgo)
        )
    }
}

private extension Array where Element == WindowModel {
    /// Window IDs in order, for readable assertions.
    var ids: [CGWindowID] { map(\.id.cgWindowID) }
}

// MARK: - Ordering

@Suite("Window ordering")
struct WindowOrderingTests {

    @Test("Most recently used puts the newest first")
    func mostRecentlyUsed() {
        let windows = [
            Fixture.window(1, age: 300),
            Fixture.window(2, age: 10),
            Fixture.window(3, age: 100),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(ordering: .mostRecentlyUsed, activeWindowFirst: false)
        )

        #expect(result.ids == [2, 3, 1])
    }

    @Test("Least recently used puts the oldest first")
    func leastRecentlyUsed() {
        let windows = [
            Fixture.window(1, age: 300),
            Fixture.window(2, age: 10),
            Fixture.window(3, age: 100),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(ordering: .leastRecentlyUsed, activeWindowFirst: false)
        )

        #expect(result.ids == [1, 3, 2])
    }

    @Test("Application launch order sorts by app, then MRU within an app")
    func applicationLaunchOrder() {
        let windows = [
            Fixture.window(1, pid: 200, app: "Notes", age: 50),
            Fixture.window(2, pid: 100, app: "Safari", age: 90),
            Fixture.window(3, pid: 100, app: "Safari", age: 10),
        ]
        let apps = [
            pid_t(100): Fixture.app(100, name: "Safari", launchedAgo: 5000),
            pid_t(200): Fixture.app(200, name: "Notes", launchedAgo: 1000),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            apps: apps,
            ordering: OrderingSettings(ordering: .applicationLaunchOrder, activeWindowFirst: false)
        )

        // Safari launched first, and within it the more recent window leads.
        #expect(result.ids == [3, 2, 1])
    }

    @Test("Alphabetical sorts by app name then window title")
    func alphabeticalByApp() {
        let windows = [
            Fixture.window(1, pid: 300, app: "Xcode", title: "Alpha"),
            Fixture.window(2, pid: 100, app: "Notes", title: "Zebra"),
            Fixture.window(3, pid: 100, app: "Notes", title: "Apple"),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(ordering: .alphabeticalByApp, activeWindowFirst: false)
        )

        #expect(result.ids == [3, 2, 1])
    }

    @Test("Space then app groups by Space, unknown Spaces last")
    func spaceThenApp() {
        let windows = [
            Fixture.window(1, pid: 100, app: "Safari", space: 2),
            Fixture.window(2, pid: 200, app: "Notes", space: 1),
            Fixture.window(3, pid: 300, app: "Xcode", space: nil),
            Fixture.window(4, pid: 100, app: "Safari", space: 1),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(ordering: .spaceThenApp, activeWindowFirst: false)
        )

        // Space 1 (Notes before Safari alphabetically), then Space 2, then unknown.
        #expect(result.ids == [2, 4, 1, 3])
    }

    /// Instability here is user-visible: two windows with identical timestamps
    /// would swap places between one press of the shortcut and the next.
    @Test("Equal sort keys preserve input order")
    func tiesAreStable() {
        let windows = (1...8).map { Fixture.window(CGWindowID($0), age: 42) }

        let first = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(ordering: .mostRecentlyUsed, activeWindowFirst: false)
        )
        let second = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(ordering: .mostRecentlyUsed, activeWindowFirst: false)
        )

        #expect(first.ids == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(first.ids == second.ids)
    }
}

// MARK: - Active window first

@Suite("Active window promotion")
struct ActiveWindowFirstTests {

    @Test("Focused window moves to the front")
    func focusedIsPromoted() {
        let windows = [
            Fixture.window(1, age: 10),
            Fixture.window(2, age: 500, focused: true),
            Fixture.window(3, age: 100),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(ordering: .mostRecentlyUsed, activeWindowFirst: true)
        )

        #expect(result.ids == [2, 1, 3])
    }

    @Test("Promotion is off when the setting is off")
    func promotionCanBeDisabled() {
        let windows = [
            Fixture.window(1, age: 10),
            Fixture.window(2, age: 500, focused: true),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(ordering: .mostRecentlyUsed, activeWindowFirst: false)
        )

        #expect(result.ids == [1, 2])
    }

    @Test("Nothing focused leaves the order untouched")
    func noFocusedWindowIsSafe() {
        let windows = [Fixture.window(1, age: 10), Fixture.window(2, age: 20)]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(activeWindowFirst: true)
        )

        #expect(result.ids == [1, 2])
    }

    /// Promoting one window must not tear its siblings away from their group.
    @Test("With grouping on, the focused window's whole app moves")
    func promotionMovesTheGroup() {
        let windows = [
            Fixture.window(1, pid: 200, app: "Notes", age: 10),
            Fixture.window(2, pid: 100, app: "Safari", age: 20),
            Fixture.window(3, pid: 100, app: "Safari", age: 900, focused: true),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(
                ordering: .mostRecentlyUsed,
                groupByApplication: true,
                activeWindowFirst: true
            )
        )

        // Focused window leads, its group follows, other apps after.
        #expect(result.ids == [3, 2, 1])
    }
}

// MARK: - Grouping

@Suite("Grouping by application")
struct GroupingTests {

    @Test("Windows of one app are clustered at that app's best position")
    func clustersByApp() {
        let windows = [
            Fixture.window(1, pid: 100, app: "Safari", age: 10),
            Fixture.window(2, pid: 200, app: "Notes", age: 20),
            Fixture.window(3, pid: 100, app: "Safari", age: 30),
            Fixture.window(4, pid: 200, app: "Notes", age: 40),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(
                ordering: .mostRecentlyUsed,
                groupByApplication: true,
                activeWindowFirst: false
            )
        )

        #expect(result.ids == [1, 3, 2, 4])
    }

    @Test("Grouping off interleaves by the primary order")
    func withoutGroupingOrderIsPurelyByKey() {
        let windows = [
            Fixture.window(1, pid: 100, app: "Safari", age: 10),
            Fixture.window(2, pid: 200, app: "Notes", age: 20),
            Fixture.window(3, pid: 100, app: "Safari", age: 30),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            ordering: OrderingSettings(
                ordering: .mostRecentlyUsed,
                groupByApplication: false,
                activeWindowFirst: false
            )
        )

        #expect(result.ids == [1, 2, 3])
    }
}

// MARK: - Filtering

@Suite("Filtering")
struct FilteringTests {

    // MARK: Application scope

    @Test("Active app scope keeps only the frontmost app's windows")
    func activeAppScope() {
        let windows = [
            Fixture.window(1, pid: 100, app: "Safari"),
            Fixture.window(2, pid: 200, app: "Notes"),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(apps: .activeApp),
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(activePID: 100)
        )

        #expect(result.ids == [1])
    }

    @Test("All-apps-except-active drops the frontmost app's windows")
    func allAppsExceptActiveScope() {
        let windows = [
            Fixture.window(1, pid: 100, app: "Safari"),
            Fixture.window(2, pid: 200, app: "Notes"),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(apps: .allAppsExceptActive),
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(activePID: 100)
        )

        #expect(result.ids == [2])
    }

    @Test("All apps keeps everything")
    func allAppsScope() {
        let windows = [
            Fixture.window(1, pid: 100),
            Fixture.window(2, pid: 200),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(apps: .allApps),
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(activePID: 100)
        )

        #expect(result.count == 2)
    }

    // MARK: Space scope

    @Test("Active Space scope keeps only that Space")
    func activeSpaceScope() {
        let windows = [
            Fixture.window(1, space: 1),
            Fixture.window(2, space: 2),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(spaces: .activeSpace),
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(activeSpaceID: 1)
        )

        #expect(result.ids == [1])
    }

    /// Holding the space bar widens the Space scope and nothing else. Modelled
    /// here as the filter change the controller makes, so the peek is covered by
    /// the same tests as the scopes it moves between.
    @Test("Widening the Space scope brings the other Spaces back")
    func revealingOtherSpacesWidensTheList() {
        let windows = [
            Fixture.window(1, space: 1),
            Fixture.window(2, space: 2),
        ]

        var filter = FilterSettings(spaces: .activeSpace)
        #expect(filter.canRevealOtherSpaces)

        filter.spaces = .allSpaces
        let revealed = WindowListBuilder.build(
            windows: windows,
            filter: filter,
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(activeSpaceID: 1)
        )

        #expect(revealed.ids == [1, 2])
        // Nothing left to reveal once the list already spans every Space, which
        // is why the space bar stays a typed character there.
        #expect(!filter.canRevealOtherSpaces)
    }

    @Test("Turning the peek off leaves nothing for the space bar to do")
    func peekCanBeDisabled() {
        let filter = FilterSettings(spaces: .activeSpace, spaceKeyRevealsOtherSpaces: false)
        #expect(!filter.canRevealOtherSpaces)
    }

    @Test("Visible Spaces scope keeps every on-screen Space")
    func visibleSpacesScope() {
        let windows = [
            Fixture.window(1, space: 1),
            Fixture.window(2, space: 2),
            Fixture.window(3, space: 3),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(spaces: .visibleSpaces),
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(visibleSpaceIDs: [1, 3])
        )

        #expect(result.ids == [1, 3])
    }

    /// Silently hiding windows when a lookup degrades is worse than showing one
    /// too many — the user would conclude the app is broken.
    @Test("Windows with an unknown Space survive Space filtering")
    func unknownSpaceIsKept() {
        let windows = [
            Fixture.window(1, space: nil),
            Fixture.window(2, space: 2),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(spaces: .activeSpace),
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(activeSpaceID: 1)
        )

        #expect(result.ids == [1])
    }

    // MARK: Screen scope

    @Test("Active screen scope keeps only that display")
    func activeScreenScope() {
        let windows = [
            Fixture.window(1, display: 1),
            Fixture.window(2, display: 2),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(screens: .activeScreen),
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(activeDisplayID: 2)
        )

        #expect(result.ids == [2])
    }

    @Test("Windows with an unknown display survive screen filtering")
    func unknownDisplayIsKept() {
        let windows = [Fixture.window(1, display: nil)]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(screens: .activeScreen),
            ordering: OrderingSettings(activeWindowFirst: false),
            context: FilterContext(activeDisplayID: 9)
        )

        #expect(result.ids == [1])
    }

    // MARK: Visibility policies

    @Test("Hide removes minimized windows", arguments: [
        (VisibilityPolicy.hide, [CGWindowID(1)]),
        (VisibilityPolicy.show, [CGWindowID(1), CGWindowID(2)]),
    ])
    func minimizedHidePolicy(policy: VisibilityPolicy, expected: [CGWindowID]) {
        let windows = [
            Fixture.window(1),
            Fixture.window(2, minimized: true),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(minimized: policy),
            ordering: OrderingSettings(activeWindowFirst: false)
        )

        #expect(result.ids == expected)
    }

    @Test("Hide removes hidden-app windows")
    func hiddenHidePolicy() {
        let windows = [Fixture.window(1), Fixture.window(2, hidden: true)]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(hidden: .hide),
            ordering: OrderingSettings(activeWindowFirst: false)
        )

        #expect(result.ids == [1])
    }

    @Test("Hide removes fullscreen windows")
    func fullscreenHidePolicy() {
        let windows = [Fixture.window(1), Fixture.window(2, fullscreen: true)]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(fullscreen: .hide),
            ordering: OrderingSettings(activeWindowFirst: false)
        )

        #expect(result.ids == [1])
    }

    @Test("Hide removes application entries")
    func appsWithNoWindowsHidePolicy() {
        let windows = [Fixture.window(1), Fixture.appEntry(pid: 900, app: "Calculator")]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(appsWithNoWindows: .hide),
            ordering: OrderingSettings(activeWindowFirst: false)
        )

        #expect(result.count == 1)
        #expect(result.ids == [1])
    }

    // MARK: Deferral

    @Test("Show at the end pushes minimized windows past the rest")
    func minimizedDeferred() {
        let windows = [
            Fixture.window(1, age: 100, minimized: true),
            Fixture.window(2, age: 200),
            Fixture.window(3, age: 300),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(minimized: .showAtEnd),
            ordering: OrderingSettings(ordering: .mostRecentlyUsed, activeWindowFirst: false)
        )

        #expect(result.ids == [2, 3, 1])
    }

    /// Deferring after sorting is what keeps the deferred group internally
    /// ordered; deferring first would scramble it.
    @Test("Deferred windows keep their relative order")
    func deferredGroupStaysSorted() {
        let windows = [
            Fixture.window(1, age: 500, minimized: true),
            Fixture.window(2, age: 100, minimized: true),
            Fixture.window(3, age: 300),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(minimized: .showAtEnd),
            ordering: OrderingSettings(ordering: .mostRecentlyUsed, activeWindowFirst: false)
        )

        #expect(result.ids == [3, 2, 1])
    }

    @Test("Application entries sort after deferred windows")
    func applicationEntriesGoLast() {
        let windows = [
            Fixture.appEntry(pid: 900, app: "Calculator"),
            Fixture.window(1, minimized: true),
            Fixture.window(2),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(minimized: .showAtEnd, appsWithNoWindows: .showAtEnd),
            ordering: OrderingSettings(ordering: .mostRecentlyUsed, activeWindowFirst: false)
        )

        #expect(result.map(\.kind) == [.window, .window, .applicationWithNoWindows])
        #expect(result[0].id.cgWindowID == 2)
        #expect(result[1].id.cgWindowID == 1)
    }

    @Test("A window matching several deferral policies is deferred once")
    func multipleDeferralsCollapse() {
        let windows = [
            Fixture.window(1, minimized: true, hidden: true, fullscreen: true),
            Fixture.window(2),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(
                minimized: .showAtEnd,
                hidden: .showAtEnd,
                fullscreen: .showAtEnd
            ),
            ordering: OrderingSettings(activeWindowFirst: false)
        )

        #expect(result.ids == [2, 1])
    }

    @Test("Show at the end still shows: nothing is dropped")
    func deferralNeverDropsWindows() {
        let windows = [
            Fixture.window(1, minimized: true),
            Fixture.window(2, hidden: true),
            Fixture.window(3, fullscreen: true),
            Fixture.appEntry(pid: 900, app: "Calculator"),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(
                minimized: .showAtEnd,
                hidden: .showAtEnd,
                fullscreen: .showAtEnd,
                appsWithNoWindows: .showAtEnd
            ),
            ordering: OrderingSettings(activeWindowFirst: false)
        )

        #expect(result.count == 4)
    }
}

// MARK: - Composition

@Suite("Pipeline composition")
struct CompositionTests {

    /// The documented order is exclude → sort → group → defer → promote. This
    /// exercises all five at once; a change to any stage's position shows up here.
    @Test("All five stages compose in the documented order")
    func fullPipeline() {
        let windows = [
            Fixture.window(10, pid: 100, app: "Safari", age: 900, minimized: true),
            Fixture.window(11, pid: 100, app: "Safari", age: 50),
            Fixture.window(12, pid: 200, app: "Notes", age: 20, focused: true),
            Fixture.window(13, pid: 200, app: "Notes", age: 800),
            Fixture.window(14, pid: 300, app: "Mail", age: 10, space: 7),
            Fixture.appEntry(pid: 400, app: "Calculator"),
        ]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(
                spaces: .activeSpace,        // drops Mail (Space 7)
                minimized: .showAtEnd,       // defers Safari window 10
                appsWithNoWindows: .showAtEnd // defers Calculator
            ),
            ordering: OrderingSettings(
                ordering: .mostRecentlyUsed,
                groupByApplication: true,
                activeWindowFirst: true
            ),
            context: FilterContext(activeSpaceID: 1)
        )

        // Mail excluded; Notes promoted (focused) and grouped; Safari next;
        // minimized Safari window deferred; Calculator last.
        #expect(result.ids == [12, 13, 11, 10, 0])
        #expect(result.last?.isApplicationEntry == true)
    }

    @Test("An empty input yields an empty list")
    func emptyInput() {
        #expect(WindowListBuilder.build(windows: []).isEmpty)
    }

    @Test("Filtering everything out yields an empty list rather than crashing")
    func everythingFiltered() {
        let windows = [Fixture.window(1, minimized: true)]

        let result = WindowListBuilder.build(
            windows: windows,
            filter: FilterSettings(minimized: .hide),
            ordering: OrderingSettings(activeWindowFirst: true)
        )

        #expect(result.isEmpty)
    }

    @Test("Defaults match the specified shipping configuration")
    func shippingDefaults() {
        let filter = FilterSettings.default
        #expect(filter.apps == .allApps)
        #expect(filter.spaces == .allSpaces)
        #expect(filter.screens == .allScreens)
        #expect(filter.minimized == .show)
        #expect(filter.hidden == .show)
        #expect(filter.fullscreen == .show)
        #expect(filter.appsWithNoWindows == .showAtEnd)

        let ordering = OrderingSettings.default
        #expect(ordering.ordering == .mostRecentlyUsed)
        #expect(ordering.groupByApplication == false)
        #expect(ordering.activeWindowFirst == true)
    }
}

// MARK: - Search

@Suite("Search filtering")
struct SearchTests {

    private var windows: [WindowModel] {
        [
            Fixture.window(1, pid: 100, app: "Safari", title: "Invoice for March"),
            Fixture.window(2, pid: 200, app: "Notes", title: "Shopping list"),
            Fixture.window(3, pid: 300, app: "Xcode", title: "OpenTab"),
        ]
    }

    @Test("Matches on app name")
    func matchesAppName() {
        #expect(WindowListBuilder.search(windows, query: "notes").ids == [2])
    }

    @Test("Matches on window title")
    func matchesTitle() {
        #expect(WindowListBuilder.search(windows, query: "shopping").ids == [2])
    }

    @Test("Matching is case insensitive")
    func caseInsensitive() {
        #expect(WindowListBuilder.search(windows, query: "SAFARI").ids == [1])
    }

    /// Requiring every term is what lets a two-word query narrow rather than widen.
    @Test("Every term must match")
    func allTermsRequired() {
        #expect(WindowListBuilder.search(windows, query: "saf inv").ids == [1])
        #expect(WindowListBuilder.search(windows, query: "saf shopping").isEmpty)
    }

    @Test("An empty query returns everything")
    func emptyQueryPassesThrough() {
        #expect(WindowListBuilder.search(windows, query: "").count == 3)
        #expect(WindowListBuilder.search(windows, query: "   ").count == 3)
    }

    @Test("No match yields an empty list")
    func noMatch() {
        #expect(WindowListBuilder.search(windows, query: "zzzz").isEmpty)
    }
}

/// Seeding the most-recently-used order for windows never seen focused.
///
/// MRU can only know about focus changes observed since launch. What it does with
/// everything else decides the list a user sees the first time they press ⌘Tab,
/// and decided — before this — that all of it was equally ancient.
@Suite("Focus time seeding")
struct FocusSeedTests {

    /// The window server lists front to back, so a lower depth is a window seen
    /// more recently.
    @Test("Windows nearer the front seed as more recently used")
    func frontWindowsSeedNewer() {
        let front = WindowDiscovery.seededFocusTime(zOrder: 0)
        let middle = WindowDiscovery.seededFocusTime(zOrder: 3)
        let back = WindowDiscovery.seededFocusTime(zOrder: 12)

        #expect(front > middle)
        #expect(middle > back)
    }

    /// A window the server has no depth for must not outrank one it does.
    @Test("An unknown depth seeds oldest")
    func unknownDepthSeedsOldest() {
        #expect(WindowDiscovery.seededFocusTime(zOrder: nil)
                < WindowDiscovery.seededFocusTime(zOrder: 100_000))
    }

    /// Otherwise the first real focus would not move a window to the front, which
    /// is the whole point of the ordering.
    @Test("Any real focus outranks every seed")
    func realFocusOutranksSeeds() {
        let now = Date()
        #expect(WindowDiscovery.seededFocusTime(zOrder: 0) < now)
        #expect(WindowDiscovery.seededFocusTime(zOrder: -50) < now)
    }

    /// The failure this replaces: every unseen window sharing one timestamp, so
    /// their order came from whatever the enumeration happened to do, and the
    /// first touch sent one of them flying up the list.
    @Test("Seeds are distinct rather than all equal")
    func seedsAreDistinct() {
        let seeds = (0..<8).map { WindowDiscovery.seededFocusTime(zOrder: $0) }
        #expect(Set(seeds).count == seeds.count)
        #expect(seeds == seeds.sorted(by: >))
    }
}
