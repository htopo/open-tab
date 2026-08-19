import CoreGraphics
import Foundation
import Testing
@testable import OpenTabCore

/// Which window the registry believes is focused.
///
/// This is load-bearing for the thing the app exists to do. "Active window
/// first" promotes the focused window to the top of the list, and the selection
/// starts on the *second* entry — so getting focus wrong by one window means
/// ⌘Tab selects the window the user is already looking at, and releasing the
/// key appears to do nothing at all.
///
/// The failure it guards against is a race, not a logic error: enumeration runs
/// in the background and answers as of the moment it *started*. Opening the
/// switcher kicks off a pass; the user commits a switch a few hundred
/// milliseconds later; the pass then lands carrying the previous focus and
/// overwrites the new one. Switching twice in quick succession was enough to hit
/// it, and nothing slower ever did.
@Suite("Focus reconciliation")
struct FocusReconciliationTests {

    private func window(_ cgID: CGWindowID, pid: pid_t = 100, focused: Bool = false) -> WindowModel {
        WindowModel(
            id: WindowID(cgWindowID: cgID, pid: pid),
            kind: .window,
            title: "window \(cgID)",
            appBundleID: "com.example.app",
            appName: "App",
            isFocused: focused
        )
    }

    @Test("The recorded window becomes the focused one")
    func recordedWindowWins() {
        let stale = [window(1, focused: true), window(2)]
        let target = WindowID(cgWindowID: 2, pid: 100)

        let result = WindowRegistry.reconcilingFocus(in: stale, toRecorded: target)

        #expect(result.first { $0.isFocused }?.id == target)
        #expect(result.filter(\.isFocused).count == 1)
    }

    /// A per-application refresh only ever sees one app's windows, so it can
    /// raise a second flag without lowering the first. Two focused windows makes
    /// the ordering depend on which one the sort happens to reach first.
    @Test("Exactly one window ends up focused")
    func onlyOneWindowIsFocused() {
        let doubled = [
            window(1, pid: 100, focused: true),
            window(2, pid: 200, focused: true),
            window(3, pid: 300),
        ]

        let result = WindowRegistry.reconcilingFocus(
            in: doubled,
            toRecorded: WindowID(cgWindowID: 3, pid: 300)
        )

        #expect(result.filter(\.isFocused).map(\.id) == [WindowID(cgWindowID: 3, pid: 300)])
    }

    /// The recorded window can have closed between the record and the pass.
    /// Flagging nothing is correct; flagging something arbitrary is not.
    @Test("A window that has gone leaves nothing focused")
    func vanishedWindowLeavesNothingFocused() {
        let list = [window(1, focused: true), window(2)]

        let result = WindowRegistry.reconcilingFocus(
            in: list,
            toRecorded: WindowID(cgWindowID: 99, pid: 100)
        )

        #expect(result.allSatisfy { !$0.isFocused })
    }

    /// The end-to-end shape of the bug, expressed against the list builder: with
    /// focus correctly recorded, the entry the selection lands on is the window
    /// the user came *from*, never the one they are on.
    @Test("After a switch, the second entry is the previous window")
    func selectionLandsOnThePreviousWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var justFocused = window(2, pid: 200)
        justFocused.lastFocusedAt = now
        var previous = window(1, pid: 100)
        previous.lastFocusedAt = now.addingTimeInterval(-5)

        // The enumeration still believes the old window has focus.
        let stale = [previous, justFocused].map { model -> WindowModel in
            var copy = model
            copy.isFocused = copy.id == previous.id
            return copy
        }

        let corrected = WindowRegistry.reconcilingFocus(in: stale, toRecorded: justFocused.id)

        let list = WindowListBuilder.build(
            windows: corrected,
            filter: FilterSettings(),
            ordering: OrderingSettings(groupByApplication: false),
            context: FilterContext()
        )

        #expect(list.first?.id == justFocused.id)
        // Index 1 is where the selection starts on a plain ⌘Tab.
        #expect(list.count > 1)
        #expect(list[1].id == previous.id)
    }
}
