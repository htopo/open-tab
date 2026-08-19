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

    @Test("The current Desktop comes first, the rest in Desktop order")
    func currentDesktopLeads() {
        let windows = [window(1, space: 9), window(2, space: 3), window(3, space: 5)]
        let numbering = SpaceGrouping.numbering(for: [3, 5, 9])

        let result = SpaceGrouping.sectioned(windows, currentSpaceID: 5, numbering: numbering)

        #expect(result.windows.map(\.id.cgWindowID) == [3, 2, 1])
        #expect(result.sections.map(\.number) == [2, 1, 3])
        #expect(result.sections.first?.isCurrent == true)
        #expect(result.sections.map(\.title) == ["Desktop 2", "Desktop 1", "Desktop 3"])
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
    func orderWithinADesktopIsKept() {
        let windows = [window(1, space: 2), window(2, space: 1), window(3, space: 2)]
        let numbering = SpaceGrouping.numbering(for: [1, 2])

        let result = SpaceGrouping.sectioned(windows, currentSpaceID: 2, numbering: numbering)

        #expect(result.windows.prefix(2).map(\.id.cgWindowID) == [1, 3])
    }

    /// Minimized and hidden windows belong to no Desktop. They already appear when
    /// the switcher is narrowed to one, so they stay with the current column
    /// rather than forming a nameless extra one.
    @Test("Windows with no Desktop join the current column")
    func spacelessWindowsJoinTheCurrentColumn() {
        let windows = [window(1, space: nil), window(2, space: 4), window(3, space: 2)]
        let numbering = SpaceGrouping.numbering(for: [2, 4])

        let result = SpaceGrouping.sectioned(windows, currentSpaceID: 2, numbering: numbering)

        #expect(result.sections.count == 2)
        let current = result.sections[0]
        #expect(current.isCurrent)
        #expect(Array(result.windows[current.range]).map(\.id.cgWindowID) == [1, 3])
    }

    @Test("An empty list produces no sections")
    func emptyListHasNoSections() {
        let result = SpaceGrouping.sectioned([], currentSpaceID: 1, numbering: [:])
        #expect(result.windows.isEmpty)
        #expect(result.sections.isEmpty)
    }
}
