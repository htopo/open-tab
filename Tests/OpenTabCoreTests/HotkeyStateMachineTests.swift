import Testing
@testable import OpenTabCore
@testable import OpenTabInput

/// The hold-and-cycle interaction, driven entirely by synthetic events.
///
/// No event tap, no window server, no overlay — which is the point of keeping the
/// machine pure. These cover the transitions that decide whether the app feels
/// native or broken, particularly the quick-tap path that must never flash a panel.
@Suite("Hotkey state machine")
struct HotkeyStateMachineTests {

    private func makeMachine(
        count: Int = 5,
        wrapAround: Bool = true,
        escapeCancels: Bool = true,
        hoverSelects: Bool = true,
        afterRelease: AfterReleaseBehavior = .focus
    ) -> HotkeyStateMachine {
        var machine = HotkeyStateMachine(
            interaction: InteractionSettings(
                mouseHoverSelects: hoverSelects,
                escapeCancels: escapeCancels,
                wrapAround: wrapAround
            ),
            afterRelease: afterRelease
        )
        machine.setCount(count)
        return machine
    }

    // MARK: - Quick tap

    /// The behaviour that makes OpenTab feel like the system switcher. A tap
    /// faster than the hold threshold must swap windows without the panel ever
    /// being shown.
    @Test("A quick tap swaps windows without showing the overlay")
    func quickTapNeverShowsOverlay() {
        var machine = makeMachine()

        let armed = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.state == .armed(shortcut: 0))
        #expect(!armed.contains(.showOverlay(shortcut: 0)))
        #expect(armed.contains(.startHoldTimer(0.150)))

        let released = machine.handle(.modifiersReleased)
        #expect(machine.state == .idle)
        #expect(released.contains(.performInstantSwap))
        #expect(released.contains(.commitSelection(1)))
        #expect(!released.contains(.hideOverlay))
        #expect(!released.contains(where: { if case .showOverlay = $0 { return true }; return false }))
    }

    /// Selection starts on the second entry, so one tap goes to the previous
    /// window rather than re-focusing the current one.
    @Test("Selection starts on the second entry")
    func selectionStartsOnPreviousWindow() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 1)
    }

    @Test("A reversed first press selects the last entry")
    func reversedFirstPressSelectsLast() {
        var machine = makeMachine(count: 5)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: true))
        #expect(machine.selection == 4)
    }

    // MARK: - Hold

    @Test("The hold threshold shows the overlay")
    func holdThresholdShowsOverlay() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))

        let effects = machine.handle(.holdThresholdElapsed)
        #expect(machine.state == .visible(shortcut: 0))
        #expect(effects.contains(.showOverlay(shortcut: 0)))
    }

    /// A second press means the user is cycling, not tapping, so waiting out the
    /// rest of the threshold would feel unresponsive.
    @Test("A second press before the threshold shows the overlay immediately")
    func secondPressShowsOverlayEarly() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))

        let effects = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.state == .visible(shortcut: 0))
        #expect(effects.contains(.cancelHoldTimer))
        #expect(effects.contains(.showOverlay(shortcut: 0)))
        #expect(machine.selection == 2)
    }

    @Test("Releasing while visible commits the selection")
    func releaseWhileVisibleCommits() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))

        let effects = machine.handle(.modifiersReleased)
        #expect(machine.state == .idle)
        #expect(effects.contains(.hideOverlay))
        #expect(effects.contains(.commitSelection(2)))
    }

    /// `.hideOverlay` is emitted *before* `.commitSelection`, so whatever handles
    /// it must not throw away the window list — the commit still has to look the
    /// selected window up in it. Getting this wrong made every held ⌘Tab a no-op:
    /// the overlay appeared, the selection moved, and releasing switched nothing.
    @Test("Commit emits hideOverlay before commitSelection")
    func hideOverlayPrecedesCommit() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        let effects = machine.handle(.modifiersReleased)
        let hideIndex = effects.firstIndex(of: .hideOverlay)
        let commitIndex = effects.firstIndex { if case .commitSelection = $0 { true } else { false } }

        #expect(hideIndex != nil)
        #expect(commitIndex != nil)
        if let hideIndex, let commitIndex {
            #expect(hideIndex < commitIndex)
        }
    }

    /// A ⇧ tap inside the hold window means the user is choosing, not tapping
    /// through. Waiting out the remaining milliseconds would swallow the step.
    @Test("Navigating during the hold window opens the overlay")
    func navigatingWhileArmedShowsOverlay() {
        var machine = makeMachine(count: 4)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.state == .armed(shortcut: 0))

        let effects = machine.handle(.navigate(delta: -1))
        #expect(machine.state == .visible(shortcut: 0))
        #expect(effects.contains(.cancelHoldTimer))
        #expect(effects.contains(.showOverlay(shortcut: 0)))
        // From the initial selection of 1, one step back is the current window.
        #expect(machine.selection == 0)
    }

    // MARK: - Cycling

    @Test("Repeated presses advance the selection")
    func repeatedPressesAdvance() {
        var machine = makeMachine(count: 4)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 2)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 3)
    }

    @Test("Shift reverses direction")
    func shiftReverses() {
        var machine = makeMachine(count: 4)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)
        #expect(machine.selection == 1)

        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: true))
        #expect(machine.selection == 0)
    }

    @Test("Wrap-around cycles past both ends")
    func wrapAroundCycles() {
        var machine = makeMachine(count: 3, wrapAround: true)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)
        #expect(machine.selection == 1)

        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 2)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 0)   // wrapped forwards
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: true))
        #expect(machine.selection == 2)   // wrapped backwards
    }

    @Test("Without wrap-around the selection clamps at the ends")
    func clampWithoutWrapAround() {
        var machine = makeMachine(count: 3, wrapAround: false)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 2)

        _ = machine.handle(.navigate(delta: -10))
        #expect(machine.selection == 0)
    }

    @Test("Arrow navigation moves the selection")
    func arrowNavigation() {
        var machine = makeMachine(count: 5)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        _ = machine.handle(.navigate(delta: 2))
        #expect(machine.selection == 3)
        _ = machine.handle(.navigate(delta: -1))
        #expect(machine.selection == 2)
    }

    // MARK: - Cancellation

    @Test("Escape cancels without committing")
    func escapeCancels() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        let effects = machine.handle(.cancelled)
        #expect(machine.state == .idle)
        #expect(effects.contains(.hideOverlay))
        #expect(effects.contains(.cancel))
        #expect(!effects.contains(where: { if case .commitSelection = $0 { return true }; return false }))
    }

    @Test("Escape does nothing when the setting is off")
    func escapeCanBeDisabled() {
        var machine = makeMachine(escapeCancels: false)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        let effects = machine.handle(.cancelled)
        #expect(effects.isEmpty)
        #expect(machine.state == .visible(shortcut: 0))
    }

    /// Cancelling while armed must also kill the pending timer, or the overlay
    /// would appear after the interaction had already ended.
    @Test("Cancelling while armed stops the hold timer")
    func cancelWhileArmedStopsTimer() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))

        let effects = machine.handle(.cancelled)
        #expect(effects.contains(.cancelHoldTimer))
        #expect(machine.state == .idle)
    }

    // MARK: - After-release behaviours

    @Test("Hold keeps the panel open after release")
    func holdBehaviourKeepsPanelOpen() {
        var machine = makeMachine(afterRelease: .hold)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        let effects = machine.handle(.modifiersReleased)
        #expect(effects.isEmpty)
        #expect(machine.state == .visible(shortcut: 0))

        let committed = machine.handle(.committed)
        #expect(committed.contains(.commitSelection(1)))
        #expect(machine.state == .idle)
    }

    @Test("Search enters search mode on release")
    func searchBehaviourEntersSearchMode() {
        var machine = makeMachine(afterRelease: .search)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        let effects = machine.handle(.modifiersReleased)
        #expect(effects.contains(.enterSearchMode))
        #expect(machine.state == .searching(shortcut: 0))
    }

    /// Typing filters regardless of the after-release setting.
    @Test("Typing a character enters search mode")
    func typingEntersSearchMode() {
        var machine = makeMachine(afterRelease: .focus)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        let effects = machine.handle(.typed("s"))
        #expect(effects.contains(.enterSearchMode))
        #expect(effects.contains(.updateSearchQuery("s")))
        #expect(machine.state == .searching(shortcut: 0))
    }

    /// After filtering, leaving the selection where it was would point at an
    /// unrelated window.
    @Test("Changing the search query resets the selection to the top")
    func searchResetsSelection() {
        var machine = makeMachine(afterRelease: .search)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)
        _ = machine.handle(.navigate(delta: 3))
        #expect(machine.selection == 4)

        _ = machine.handle(.modifiersReleased)
        let effects = machine.handle(.searchChanged("saf"))
        #expect(machine.selection == 0)
        #expect(effects.contains(.setSelection(0)))
    }

    @Test("Cycling still works while searching")
    func cyclingWorksWhileSearching() {
        var machine = makeMachine(count: 3, afterRelease: .search)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)
        _ = machine.handle(.modifiersReleased)

        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 2)
    }

    @Test("Modifier release is ignored once searching")
    func modifierReleaseIgnoredWhileSearching() {
        var machine = makeMachine(afterRelease: .search)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)
        _ = machine.handle(.modifiersReleased)

        let effects = machine.handle(.modifiersReleased)
        #expect(effects.isEmpty)
        #expect(machine.state == .searching(shortcut: 0))
    }

    // MARK: - Hover

    @Test("Hover selects when enabled")
    func hoverSelects() {
        var machine = makeMachine(hoverSelects: true)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        let effects = machine.handle(.hovered(index: 3))
        #expect(machine.selection == 3)
        #expect(effects.contains(.setSelection(3)))
    }

    @Test("Hover does nothing when disabled")
    func hoverCanBeDisabled() {
        var machine = makeMachine(hoverSelects: false)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        let effects = machine.handle(.hovered(index: 3))
        #expect(effects.isEmpty)
        #expect(machine.selection == 1)
    }

    @Test("Hovering the current selection produces no effect")
    func redundantHoverIsIgnored() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        #expect(machine.handle(.hovered(index: 1)).isEmpty)
    }

    // MARK: - Edge cases

    /// A window can close while the switcher is open. The selection must stay in
    /// range rather than committing to an index that no longer exists.
    @Test("A shrinking list clamps the selection")
    func shrinkingListClampsSelection() {
        var machine = makeMachine(count: 5, wrapAround: false)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)
        _ = machine.handle(.navigate(delta: 3))
        #expect(machine.selection == 4)

        _ = machine.handle(.listCountChanged(2))
        #expect(machine.selection <= 1)
    }

    @Test("An empty list keeps the selection at zero")
    func emptyListIsSafe() {
        var machine = makeMachine(count: 0)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 0)

        _ = machine.handle(.holdThresholdElapsed)
        _ = machine.handle(.navigate(delta: 5))
        #expect(machine.selection == 0)
    }

    @Test("A single-window list stays on that window")
    func singleWindowList() {
        var machine = makeMachine(count: 1)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 0)

        _ = machine.handle(.holdThresholdElapsed)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        #expect(machine.selection == 0)
    }

    @Test("Events in the idle state other than a trigger are ignored")
    func idleIgnoresStrayEvents() {
        var machine = makeMachine()
        #expect(machine.handle(.modifiersReleased).isEmpty)
        #expect(machine.handle(.holdThresholdElapsed).isEmpty)
        #expect(machine.handle(.committed).isEmpty)
        #expect(machine.handle(.navigate(delta: 1)).isEmpty)
        #expect(machine.state == .idle)
    }

    /// Holding the trigger down produces a stream of presses; none of them may
    /// leave the machine in an inconsistent state.
    @Test("Rapid repeated triggering stays consistent")
    func rapidTriggeringIsStable() {
        var machine = makeMachine(count: 6)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)

        for _ in 0..<200 {
            _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
            #expect((0..<6).contains(machine.selection))
        }
        #expect(machine.state == .visible(shortcut: 0))

        _ = machine.handle(.modifiersReleased)
        #expect(machine.state == .idle)
    }

    @Test("A full interaction returns to idle with the selection reset")
    func fullCycleReturnsToIdle() {
        var machine = makeMachine()
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.holdThresholdElapsed)
        _ = machine.handle(.triggerPressed(shortcut: 0, reversed: false))
        _ = machine.handle(.modifiersReleased)

        #expect(machine.state == .idle)
        #expect(machine.selection == 0)
    }
}
