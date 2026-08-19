import CoreGraphics
import Foundation
import OpenTabCore

/// Everything the tap callback needs to decide what to do with a key event.
///
/// A value type, snapshotted under a lock and read on the tap thread. The tap
/// callback must not reach into the registry, the settings store, or anything
/// else that could block: macOS disables a tap whose callback takes too long, and
/// the visible symptom is the user's typing stuttering system-wide.
public struct TapConfiguration: Equatable, Sendable {

    /// Bindings in shortcut order; the index is the shortcut number.
    public var shortcuts: [KeyCombo]

    /// True while the switcher is armed or on screen.
    public var isSwitcherActive: Bool

    /// The modifiers of the shortcut that started the current interaction.
    /// Used to detect when the user has let go.
    public var activeModifiers: ModifierSet

    /// True when the frontmost application has an "Ignore shortcuts" exception.
    ///
    /// Set from the main thread on every application activation, never computed
    /// in the callback. This is what lets ⌘Tab reach a VM or remote-desktop guest.
    public var passThroughEverything: Bool

    /// Keys that belong to the switcher while it is on screen and must not reach
    /// the app underneath.
    public var overlayKeyCodes: Set<UInt16>

    /// Whether tapping ⇧ steps backwards, instead of ⇧ reversing Tab.
    public var shiftStepsBackwards: Bool

    /// Whether the space bar belongs to the switcher right now.
    ///
    /// Only true while the overlay is showing a Space-filtered list that holding
    /// space would widen. Otherwise the key is left alone, so a space typed into
    /// the search field is a space.
    public var claimsSpaceKey: Bool

    public init(
        shortcuts: [KeyCombo] = [],
        isSwitcherActive: Bool = false,
        activeModifiers: ModifierSet = [],
        passThroughEverything: Bool = false,
        overlayKeyCodes: Set<UInt16> = [],
        shiftStepsBackwards: Bool = true,
        claimsSpaceKey: Bool = false
    ) {
        self.shortcuts = shortcuts
        self.isSwitcherActive = isSwitcherActive
        self.activeModifiers = activeModifiers
        self.passThroughEverything = passThroughEverything
        self.overlayKeyCodes = overlayKeyCodes
        self.shiftStepsBackwards = shiftStepsBackwards
        self.claimsSpaceKey = claimsSpaceKey
    }
}

/// What the tap should do with one event.
public enum TapOutcome: Equatable, Sendable {
    /// Let it through untouched and do nothing.
    case ignore
    /// A shortcut fired.
    case trigger(shortcut: Int, reversed: Bool)
    /// The shortcut's modifiers came up.
    case modifiersReleased
    /// ⇧ was pressed on its own while the switcher was open.
    case stepBackward
    /// A key pressed or released while the overlay is on screen.
    ///
    /// Both halves are reported. Most keys act on the press and ignore the
    /// release — without `isKeyDown` to tell them apart, one arrow-key press
    /// moved the selection twice. Holding space to reveal other Spaces needs
    /// both.
    case overlayKey(keyCode: UInt16, flags: CGEventFlags, isKeyDown: Bool)
    /// A printable character typed while the overlay is on screen.
    case typed(String)

    /// Whether the originating event must be consumed rather than delivered.
    ///
    /// Swallowing is why the tap has to be a `.defaultTap` rather than listen-only:
    /// if ⌘Tab reached the focused application as well as OpenTab, every switch
    /// would also trigger whatever that app binds to ⌘Tab.
    public var swallowsEvent: Bool {
        switch self {
        case .ignore:
            false
        case .modifiersReleased, .stepBackward:
            // Modifier events must keep flowing. Consuming a ⌘ key-up would leave
            // every other app believing ⌘ is still held, and a swallowed ⇧ would
            // strand the shift state of every other application.
            false
        case .trigger, .overlayKey, .typed:
            true
        }
    }
}

/// The tap's decision logic, as a pure function.
///
/// Separated from `EventTap` so it can be exercised directly: constructing
/// synthetic `CGEvent`s and a live tap in tests would require Accessibility, which
/// CI cannot grant.
public enum TapMatcher {

    /// Keys the switcher claims while its overlay is visible.
    public static let defaultOverlayKeyCodes: Set<UInt16> = {
        var codes: Set<UInt16> = []
        for code in [kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter,
                     kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                     kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown] {
            codes.insert(UInt16(code))
        }
        return codes
    }()

    /// - Parameter previousFlags: the modifier state at the previous event. Needed
    ///   because `.flagsChanged` reports the *resulting* state, not what changed;
    ///   telling a ⇧ press from a ⇧ release means comparing the two.
    public static func evaluate(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        characters: String?,
        config: TapConfiguration,
        previousFlags: CGEventFlags = []
    ) -> TapOutcome {

        // An exception app is frontmost: OpenTab is deliberately invisible.
        // Checked first so that nothing below can accidentally claim an event.
        if config.passThroughEverything { return .ignore }

        switch type {
        case .flagsChanged:
            guard config.isSwitcherActive, !config.activeModifiers.isEmpty else { return .ignore }

            // "Released" means none of the shortcut's modifiers are still down.
            // Requiring *all* of them to be down to stay open would end the
            // interaction the moment a user let go of ⇧ while reversing.
            let stillHeld = ModifierSet(eventFlags: flags)
            if stillHeld.isDisjoint(with: config.activeModifiers) { return .modifiersReleased }

            // ⇧ going down on its own steps backwards. Only the transition counts:
            // acting on the resulting state would repeat on every subsequent
            // modifier event for as long as ⇧ stayed down.
            let shiftWentDown = flags.contains(.maskShift) && !previousFlags.contains(.maskShift)
            if config.shiftStepsBackwards, shiftWentDown { return .stepBackward }

            return .ignore

        case .keyDown:
            // A shortcut press always wins, including while the overlay is open —
            // that is how repeat-to-cycle works.
            for (index, combo) in config.shortcuts.enumerated()
            where combo.matches(keyCode: keyCode, flags: flags) {
                // ⇧ has one role at a time. Once the switcher is up and ⇧ is
                // stepping backwards by itself, letting it also reverse Tab would
                // make a single ⌘⇧Tab move two entries. On the opening press
                // there is nothing to step back from, so ⇧ still means "start at
                // the end" — its only unambiguous use.
                let shiftIsStepping = config.shiftStepsBackwards && config.isSwitcherActive
                let reversed = flags.contains(.maskShift) && !shiftIsStepping
                return .trigger(shortcut: index, reversed: reversed)
            }

            guard config.isSwitcherActive else { return .ignore }

            if keyCode == spaceKeyCode, config.claimsSpaceKey {
                return .overlayKey(keyCode: keyCode, flags: flags, isKeyDown: true)
            }

            if config.overlayKeyCodes.contains(keyCode) {
                return .overlayKey(keyCode: keyCode, flags: flags, isKeyDown: true)
            }

            // Printable characters start search filtering. Anything with ⌘ or ⌃
            // held is a command rather than text, and is routed as an overlay key
            // so the action shortcuts (⌘W, ⌘M, …) can claim it.
            let modifiers = ModifierSet(eventFlags: flags)
            if modifiers.contains(.command) || modifiers.contains(.control) {
                return .overlayKey(keyCode: keyCode, flags: flags, isKeyDown: true)
            }
            if let characters, !characters.isEmpty, characters.allSatisfy(\.isPrintable) {
                return .typed(characters)
            }
            return .ignore

        case .keyUp:
            // Key-ups for keys we swallowed on the way down must also be swallowed,
            // or the focused app sees an unbalanced release.
            guard config.isSwitcherActive else { return .ignore }
            let isClaimed = config.shortcuts.contains { $0.keyCode == keyCode }
                || config.overlayKeyCodes.contains(keyCode)
                || (keyCode == spaceKeyCode && config.claimsSpaceKey)
            return isClaimed ? .overlayKey(keyCode: keyCode, flags: flags, isKeyDown: false) : .ignore

        default:
            return .ignore
        }
    }
}

private extension Character {
    /// Text-bearing rather than a control code. Newline and tab are excluded
    /// because they are navigation in this context, not content.
    var isPrintable: Bool {
        !isNewline && self != "\t" && !unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

// Carbon key constants, imported here so TapMatcher does not pull in all of
// Carbon.HIToolbox at every call site.
private let kVK_Escape = 0x35
private let kVK_Return = 0x24
private let kVK_ANSI_KeypadEnter = 0x4C
private let kVK_LeftArrow = 0x7B
private let kVK_RightArrow = 0x7C
private let kVK_DownArrow = 0x7D
private let kVK_UpArrow = 0x7E
private let kVK_Home = 0x73
private let kVK_End = 0x77
private let kVK_PageUp = 0x74
private let kVK_PageDown = 0x79
private let spaceKeyCode = UInt16(0x31)
