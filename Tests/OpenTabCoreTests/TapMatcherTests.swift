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
        passThrough: Bool = false
    ) -> TapConfiguration {
        TapConfiguration(
            shortcuts: shortcuts,
            isSwitcherActive: active,
            activeModifiers: modifiers,
            passThroughEverything: passThrough,
            overlayKeyCodes: TapMatcher.defaultOverlayKeyCodes
        )
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
        #expect(TapOutcome.overlayKey(keyCode: 0x35, flags: []).swallowsEvent)
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
        #expect(outcome == .overlayKey(keyCode: rightArrow, flags: []))
    }

    @Test("Escape is claimed while the overlay is open")
    func escapeClaimed() {
        let outcome = TapMatcher.evaluate(
            type: .keyDown, keyCode: escape, flags: [],
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .overlayKey(keyCode: escape, flags: []))
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
        #expect(outcome == .overlayKey(keyCode: letterS, flags: .maskCommand))
    }

    /// An unbalanced release would leave the focused app thinking a key is stuck.
    @Test("Key-ups for claimed keys are also claimed")
    func keyUpsForClaimedKeysAreClaimed() {
        let outcome = TapMatcher.evaluate(
            type: .keyUp, keyCode: tab, flags: .maskCommand,
            characters: nil, config: config(active: true, modifiers: .command)
        )
        #expect(outcome == .overlayKey(keyCode: tab, flags: .maskCommand))
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
