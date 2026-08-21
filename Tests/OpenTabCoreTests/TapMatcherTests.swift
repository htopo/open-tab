import CoreGraphics
import Testing
@testable import OpenTabCore
@testable import OpenTabInput

/// The tap callback's decision logic.
///
/// Two things matter here and both are user-visible when wrong: which events get
/// *swallowed* (swallow too much and typing breaks system-wide; too little and
/// every switch also fires the focused app's own ⌘Tab binding), and whether an
/// exception app's keystrokes are passed through untouched.
@Suite("Event tap matching")
struct TapMatcherTests {

    private let tab = UInt16(0x30)
    private let backtick = UInt16(0x32)
    private let escape = UInt16(0x35)
    private let rightArrow = UInt16(0x7C)
    private let letterS = UInt16(0x01)

    private func config(
        shortcuts: [KeyCombo] = [.commandTab],
        active: Bool = false,
        modifiers: ModifierSet = [],
        passThrough: Bool = false,
        shiftSteps: Bool = true
    ) -> TapConfiguration {
        TapConfiguration(
            shortcuts: shortcuts,
            isSwitcherActive: active,
            activeModifiers: modifiers,
            passThroughEverything: passThrough,
            overlayKeyCodes: TapMatcher.defaultOverlayKeyCodes,
            shiftStepsBackwards: shiftSteps
        )
    }

    // MARK: - Shift as a step backwards

    @Test("Pressing shift while the switcher is open steps backwards")
    func shiftPressStepsBackwards() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: [.maskCommand, .maskShift],
            characters: nil, config: config(active: true, modifiers: .command),
            previousFlags: .maskCommand
        )
        #expect(outcome == .stepBackward(isPressed: true))
    }

    /// Only the press counts. Acting on the resulting state instead would fire
    /// again on every modifier event for as long as ⇧ stayed down.
    @Test("Holding shift does not step repeatedly")
    func heldShiftDoesNotRepeat() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: [.maskCommand, .maskShift],
            characters: nil, config: config(active: true, modifiers: .command),
            previousFlags: [.maskCommand, .maskShift]
        )
        #expect(outcome == .ignore)
    }

    /// The release is reported, but as an end rather than a step: it is what
    /// stops the repeat that holding ⇧ started. Treating it as another step would
    /// move the selection one further every time the user let go.
    @Test("Releasing shift ends the repeat without stepping")
    func releasingShiftEndsTheRepeat() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: .maskCommand,
            characters: nil, config: config(active: true, modifiers: .command),
            previousFlags: [.maskCommand, .maskShift]
        )
        #expect(outcome == .stepBackward(isPressed: false))
    }

    @Test("Shift before the switcher is open does nothing")
    func shiftWhileIdleDoesNothing() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: [.maskCommand, .maskShift],
            characters: nil, config: config(active: false, modifiers: .command),
            previousFlags: .maskCommand
        )
        #expect(outcome == .ignore)
    }

    /// A stepping ⇧ must not also reverse Tab, or one ⌘⇧Tab moves two entries.
    @Test("Shift does not reverse Tab once the switcher is open")
    func shiftDoesNotAlsoReverseTab() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: [.maskCommand, .maskShift],
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .trigger(shortcut: 0, reversed: false))
    }

    /// The opening press is the one place ⇧ can still mean "start at the end":
    /// there is nothing to step back from yet.
    @Test("Shift still opens the switcher at the last entry")
    func shiftReversesTheOpeningPress() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: [.maskCommand, .maskShift],
            characters: nil, config: config(active: false, modifiers: .command)
        )
        #expect(outcome == .trigger(shortcut: 0, reversed: true))
    }

    @Test("With the option off, shift reverses Tab and never steps on its own")
    func classicShiftBehaviour() {
        let stepping = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: [.maskCommand, .maskShift],
            characters: nil,
            config: config(active: true, modifiers: .command, shiftSteps: false),
            previousFlags: .maskCommand
        )
        #expect(stepping == .ignore)

        let reversing = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: [.maskCommand, .maskShift],
            characters: nil,
            config: config(active: true, modifiers: .command, shiftSteps: false)
        )
        #expect(reversing == .trigger(shortcut: 0, reversed: true))
    }

    /// ⇧ is a modifier every other application is also tracking. Swallowing the
    /// event would leave them all believing ⇧ is still down.
    @Test("A shift step does not swallow the event")
    func shiftStepDoesNotSwallow() {
        #expect(!TapOutcome.stepBackward(isPressed: true).swallowsEvent)
        #expect(!TapOutcome.stepBackward(isPressed: false).swallowsEvent)
    }

    // MARK: - Holding space to reveal other Spaces

    private let spaceBar = UInt16(0x31)

    private func spaceConfig(claims: Bool) -> TapConfiguration {
        TapConfiguration(
            shortcuts: [.commandTab],
            isSwitcherActive: true,
            activeModifiers: .command,
            overlayKeyCodes: TapMatcher.defaultOverlayKeyCodes,
            claimsSpaceKey: claims
        )
    }

    @Test("Both edges of the space bar are reported when it is claimed")
    func spaceBarReportsBothEdges() {
        let down = TapMatcher.evaluate(
            type: .keyDown, keyCode: spaceBar, flags: .maskCommand,
            characters: " ", config: spaceConfig(claims: true)
        )
        #expect(down == .overlayKey(keyCode: spaceBar, flags: .maskCommand, isKeyDown: true))

        let up = TapMatcher.evaluate(
            type: .keyUp, keyCode: spaceBar, flags: .maskCommand,
            characters: nil, config: spaceConfig(claims: true)
        )
        #expect(up == .overlayKey(keyCode: spaceBar, flags: .maskCommand, isKeyDown: false))
    }

    /// Nothing to reveal, or a search field to type into: the space bar is a
    /// space bar and must reach whatever is listening.
    @Test("An unclaimed space bar is left alone")
    func unclaimedSpaceBarIsNotTaken() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: spaceBar, flags: [],
            characters: " ", config: spaceConfig(claims: false)
        )
        #expect(outcome == .typed(" "))

        let up = TapMatcher.evaluate(
            type: .keyUp, keyCode: spaceBar, flags: [],
            characters: nil, config: spaceConfig(claims: false)
        )
        #expect(up == .ignore)
    }

    /// The release is claimed only so the application underneath does not see an
    /// unbalanced key-up. Acting on it moved the selection twice per press.
    @Test("Key-up is distinguishable from key-down")
    func keyUpIsMarked() {
        let down = TapMatcher.evaluate(
            type: .keyDown, keyCode: rightArrow, flags: [],
            characters: nil, config: config(active: true, modifiers: .command)
        )
        let up = TapMatcher.evaluate(
            type: .keyUp, keyCode: rightArrow, flags: [],
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(down == .overlayKey(keyCode: rightArrow, flags: [], isKeyDown: true))
        #expect(up == .overlayKey(keyCode: rightArrow, flags: [], isKeyDown: false))
        #expect(down != up)
    }

    // MARK: - Desktop digits

    @Test("Digits are claimed only while the Desktop columns are up")
    func digitsClaimedOnlyWithColumns() {
        let one = TapMatcher.digitKeyCodesInOrder[0]

        let withColumns = TapMatcher.evaluate(
            type: .keyDown, keyCode: one, flags: .maskCommand, characters: "1",
            config: TapConfiguration(shortcuts: [.commandTab], isSwitcherActive: true,
                                     activeModifiers: .command, claimsDigitKeys: true)
        )
        #expect(withColumns == .overlayKey(keyCode: one, flags: .maskCommand, isKeyDown: true))

        // Without columns a digit is a character, and must reach the search field.
        let without = TapMatcher.evaluate(
            type: .keyDown, keyCode: one, flags: [], characters: "1",
            config: TapConfiguration(shortcuts: [.commandTab], isSwitcherActive: true,
                                     activeModifiers: .command, claimsDigitKeys: false)
        )
        #expect(without == .typed("1"))
    }

    /// The codes are not contiguous — 5 and 6 are swapped relative to the rest —
    /// so the order is the mapping and getting it wrong sends the user to the
    /// wrong Desktop.
    @Test("Digit codes are in Desktop order")
    func digitCodesAreOrdered() {
        #expect(TapMatcher.digitKeyCodesInOrder.count == 9)
        #expect(TapMatcher.digitKeyCodesInOrder[4] == 0x17)  // 5
        #expect(TapMatcher.digitKeyCodesInOrder[5] == 0x16)  // 6
        #expect(Set(TapMatcher.digitKeyCodesInOrder).count == 9)
    }

    // MARK: - Triggering

    @Test("The bound combination fires its shortcut")
    func boundComboTriggers() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: .maskCommand,
            characters: nil, config: config()
        )
        #expect(outcome == .trigger(shortcut: 0, reversed: false))
    }

    @Test("Shift marks the trigger as reversed")
    func shiftReverses() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: [.maskCommand, .maskShift],
            characters: nil, config: config()
        )
        #expect(outcome == .trigger(shortcut: 0, reversed: true))
    }

    @Test("The shortcut index matches its position in the list")
    func shortcutIndexIsPositional() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: backtick, flags: .maskAlternate,
            characters: nil, config: config(shortcuts: [.commandTab, .optionBacktick])
        )
        #expect(outcome == .trigger(shortcut: 1, reversed: false))
    }

    @Test("The wrong modifier does not trigger")
    func wrongModifierDoesNotTrigger() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: .maskControl,
            characters: nil, config: config()
        )
        #expect(outcome == .ignore)
    }

    @Test("A bare key does not trigger")
    func bareKeyDoesNotTrigger() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: [],
            characters: "\t", config: config()
        )
        #expect(outcome == .ignore)
    }

    /// Cycling is a repeated press of the same combination while the overlay is up.
    @Test("The trigger still fires while the switcher is open")
    func triggerRepeatsWhileOpen() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: .maskCommand,
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .trigger(shortcut: 0, reversed: false))
    }

    // MARK: - Swallowing

    /// If ⌘Tab reached the focused app as well, every switch would also fire that
    /// app's own binding for it.
    @Test("Trigger events are swallowed")
    func triggersAreSwallowed() {
        #expect(TapOutcome.trigger(shortcut: 0, reversed: false).swallowsEvent)
    }

    @Test("Overlay keys and typed characters are swallowed")
    func overlayInputIsSwallowed() {
        #expect(TapOutcome.overlayKey(keyCode: 0x35, flags: [], isKeyDown: true).swallowsEvent)
        #expect(TapOutcome.typed("s").swallowsEvent)
    }

    /// Consuming a ⌘ key-up would leave every other app believing ⌘ is still held.
    @Test("Modifier events are never swallowed")
    func modifierEventsPassThrough() {
        #expect(!TapOutcome.modifiersReleased.swallowsEvent)
    }

    @Test("Unmatched events pass through")
    func ignoredEventsPassThrough() {
        #expect(!TapOutcome.ignore.swallowsEvent)
    }

    // MARK: - Modifier release

    @Test("Dropping every shortcut modifier reports a release")
    func releasingAllModifiersReports() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: [],
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .modifiersReleased)
    }

    @Test("Still holding the modifier is not a release")
    func holdingModifierIsNotARelease() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: .maskCommand,
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .ignore)
    }

    /// Letting go of ⇧ mid-reverse must not end the interaction.
    @Test("Releasing shift while still holding command is not a release")
    func releasingShiftAloneIsNotARelease() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: .maskCommand,
            characters: nil, config: config(active: true, modifiers: [.command])
        )
        #expect(outcome == .ignore)
    }

    @Test("Modifier changes are ignored when the switcher is not active")
    func modifiersIgnoredWhenIdle() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: [],
            characters: nil, config: config(active: false, modifiers: .command)
        )
        #expect(outcome == .ignore)
    }

    // MARK: - Overlay keys

    @Test("Navigation keys are claimed while the overlay is open")
    func navigationKeysClaimed() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: rightArrow, flags: [],
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .overlayKey(keyCode: rightArrow, flags: [], isKeyDown: true))
    }

    @Test("Escape is claimed while the overlay is open")
    func escapeClaimed() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: escape, flags: [],
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .overlayKey(keyCode: escape, flags: [], isKeyDown: true))
    }

    @Test("Navigation keys are ignored when the overlay is closed")
    func navigationIgnoredWhenClosed() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: rightArrow, flags: [],
            characters: nil, config: config(active: false)
        )
        #expect(outcome == .ignore)
    }

    @Test("A printable character becomes search input")
    func printableCharacterTyped() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: letterS, flags: [],
            characters: "s", config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .typed("s"))
    }

    /// Command-modified keys are the action shortcuts (⌘W, ⌘M, …), not text.
    @Test("A command-modified key is an action, not typed text")
    func commandKeyIsNotTypedText() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: letterS, flags: .maskCommand,
            characters: "s", config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .overlayKey(keyCode: letterS, flags: .maskCommand, isKeyDown: true))
    }

    /// An unbalanced release would leave the focused app thinking a key is stuck.
    @Test("Key-ups for claimed keys are also claimed")
    func keyUpsForClaimedKeysAreClaimed() {
        let outcome = TapMatcher.evaluate(
            type: .keyUp, keyCode: tab, flags: .maskCommand,
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .overlayKey(keyCode: tab, flags: .maskCommand, isKeyDown: false))
    }

    @Test("Key-ups for unclaimed keys pass through")
    func keyUpsForOtherKeysPassThrough() {
        let outcome = TapMatcher.evaluate(
            type: .keyUp, keyCode: letterS, flags: [],
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .ignore)
    }

    // MARK: - Exception pass-through

    /// The reason the exceptions feature exists: a VM or remote-desktop client
    /// needs ⌘Tab to reach the guest OS.
    @Test("Pass-through mode ignores the bound shortcut entirely")
    func passThroughIgnoresTrigger() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: tab, flags: .maskCommand,
            characters: nil, config: config(passThrough: true)
        )
        #expect(outcome == .ignore)
        #expect(!outcome.swallowsEvent)
    }

    @Test("Pass-through mode overrides an already-open switcher")
    func passThroughBeatsActiveState() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: escape, flags: [],
            characters: nil,
            config: config(active: true, modifiers: .command, passThrough: true)
        )
        #expect(outcome == .ignore)
    }

    @Test("Pass-through mode ignores modifier changes")
    func passThroughIgnoresModifiers() {
        let outcome = TapMatcher.evaluate(
            type: .flagsChanged, keyCode: 0, flags: [],
            characters: nil,
            config: config(active: true, modifiers: .command, passThrough: true)
        )
        #expect(outcome == .ignore)
    }

    // MARK: - Key combo matching

    /// Otherwise ⌘⇧Tab would fail to match a ⌘Tab binding and cycling backwards
    /// would close the overlay.
    @Test("Combo matching ignores shift")
    func comboMatchingIgnoresShift() {
        #expect(KeyCombo.commandTab.matches(keyCode: tab, flags: [.maskCommand, .maskShift]))
        #expect(KeyCombo.commandTab.matches(keyCode: tab, flags: .maskCommand))
    }

    @Test("Combo matching requires the exact non-shift modifiers")
    func comboMatchingIsStrictAboutOtherModifiers() {
        #expect(!KeyCombo.commandTab.matches(keyCode: tab, flags: [.maskCommand, .maskAlternate]))
        #expect(!KeyCombo.commandTab.matches(keyCode: tab, flags: []))
    }

    @Test("A modifierless binding cannot drive hold-and-cycle")
    func modifierlessBindingIsRejected() {
        let bare = KeyCombo(keyCode: tab, modifiers: [])
        #expect(!bare.isUsableAsHoldShortcut)
        #expect(KeyCombo.commandTab.isUsableAsHoldShortcut)
    }

    @Test("Display strings use the standard modifier order")
    func displayStringOrder() {
        let combo = KeyCombo(keyCode: tab, modifiers: [.command, .shift, .option, .control])
        #expect(combo.displayString.hasPrefix("⌃⌥⇧⌘"))
    }
}
