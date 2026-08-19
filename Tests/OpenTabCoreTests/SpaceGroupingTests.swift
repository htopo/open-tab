import CoreGraphics
import Foundation
import Testing
@testable import OpenTabCore

/// Splitting the list into one column per Desktop.
@Suite("Space grouping")
struct SpaceGroupingTests {

    private func window(_ cgID: CGWindowID, space: Int?) -> WindowModel {
        WindowModel(
            id: WindowID(cgWindowID: cgID, pid: 100),
            kind: .window,
            title: "w\(cgID)",
            appBundleID: "com.example",
            appName: "App",
            spaceID: space
        )
    }

    /// Space IDs are opaque and do not start at one; the numbers shown to the
    /// user must.
    @Test("Desktops are numbered from one in Space order")
    func numbersStartAtOne() {
        let numbering = SpaceGrouping.numbering(for: [7, 1, 4])
        #expect(numbering == [1: 1, 4: 2, 7: 3])
    }

    @Test("Duplicate Space IDs do not consume a number")
    func duplicatesShareANumber() {
        let numbering = SpaceGrouping.numbering(for: [3, 3, 9])
        #expect(numbering == [3: 1, 9: 2])
    }

    /// The numbers are the navigation — pressing 3 means Desktop 3 — and that only
    /// reads as true if 3 is also always in the same place on screen. So the
    /// layout does not reshuffle around whichever Desktop the user is standing on.
    @Test("Columns run in Desktop order regardless of where the user is")
    func columnsFollowDesktopNumber() {
        let windows = [window(1, space: 9), window(2, space: 3), window(3, space: 5)]
        let numbering = SpaceGrouping.numbering(for: [3, 5, 9])

        let result = SpaceGrouping.sectioned(windows, currentSpaceID: 5, numbering: numbering)

        #expect(result.sections.map(\.number) == [1, 2, 3])
        #expect(result.sections.map(\.title) == ["Desktop 1", "Desktop 2", "Desktop 3"])
        #expect(result.windows.map(\.id.cgWindowID) == [2, 3, 1])
        // Current is marked in the heading, not by position.
        #expect(result.sections.map(\.isCurrent) == [false, true, false])
    }

    @Test("Standing on a different Desktop does not change the layout")
    func layoutIsIndependentOfCurrentDesktop() {
        let windows = [window(1, space: 9), window(2, space: 3), window(3, space: 5)]
        let numbering = SpaceGrouping.numbering(for: [3, 5, 9])

        let fromOne = SpaceGrouping.sectioned(windows, currentSpaceID: 3, numbering: numbering)
        let fromThree = SpaceGrouping.sectioned(windows, currentSpaceID: 9, numbering: numbering)

        #expect(fromOne.windows.map(\.id.cgWindowID) == fromThree.windows.map(\.id.cgWindowID))
        #expect(fromOne.sections.map(\.number) == fromThree.sections.map(\.number))
    }

    /// Every window has to be reachable: a range that misses one means a window
    /// the user can see but cannot select.
    @Test("Sections cover the whole list without gaps or overlap")
    func sectionsTileTheList() {
        let windows = [
            window(1, space: 1), window(2, space: 2), window(3, space: 1),
            window(4, space: 3), window(5, space: 2),
        ]
        let numbering = SpaceGrouping.numbering(for: [1, 2, 3])

        let result = SpaceGrouping.sectioned(windows, currentSpaceID: 2, numbering: numbering)

        #expect(result.windows.count == windows.count)
        let covered = result.sections.flatMap { Array($0.range) }
        #expect(covered == Array(0..<windows.count))
    }

    @Test("Order within a Desktop is preserved")
    func orderWithinADesktopIsKept() throws {
        let windows = [window(1, space: 2), window(2, space: 1), window(3, space: 2)]
        let numbering = SpaceGrouping.numbering(for: [1, 2])

        let result = SpaceGrouping.sectioned(windows, currentSpaceID: 2, numbering: numbering)

        let desktopTwo = try #require(result.sections.first { $0.number == 2 })
        #expect(Array(result.windows[desktopTwo.range]).map(\.id.cgWindowID) == [1, 3])
    }

    /// Minimized and hidden windows belong to no Desktop. They already appear when
    /// the switcher is narrowed to one, so they stay with the current column
    /// rather than forming a nameless extra one.
    @Test("Windows with no Desktop join the current column")
    func spacelessWindowsJoinTheCurrentColumn() throws {
        let windows = [window(1, space: nil), window(2, space: 4), window(3, space: 2)]
        let numbering = SpaceGrouping.numbering(for: [2, 4])

        let result = SpaceGrouping.sectioned(windows, currentSpaceID: 2, numbering: numbering)

        #expect(result.sections.count == 2)
        let current = try #require(result.sections.first { $0.isCurrent })
        #expect(Array(result.windows[current.range]).map(\.id.cgWindowID) == [1, 3])
    }

    @Test("An empty list produces no sections")
    func emptyListHasNoSections() {
        let result = SpaceGrouping.sectioned([], currentSpaceID: 1, numbering: [:])
        #expect(result.windows.isEmpty)
        #expect(result.sections.isEmpty)
    }
}
