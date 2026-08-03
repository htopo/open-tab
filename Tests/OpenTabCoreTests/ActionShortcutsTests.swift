import Carbon.HIToolbox
import Foundation
import Testing
@testable import OpenTabCore

/// Action bindings that are live only while the overlay is on screen.
///
/// That scoping is what makes it safe to bind ⌘W and ⌘Q at all: outside the
/// switcher those belong to whatever app is frontmost, and the event tap passes
/// them straight through.
@Suite("Action shortcuts")
struct ActionShortcutsTests {

    private let w = UInt16(kVK_ANSI_W)
    private let m = UInt16(kVK_ANSI_M)
    private let q = UInt16(kVK_ANSI_Q)
    private let f = UInt16(kVK_ANSI_F)

    // MARK: - Defaults

    @Test("Shipped defaults match the specification")
    func defaults() {
        let shortcuts = ActionShortcuts.default

        #expect(shortcuts.action(forKeyCode: w, modifiers: .command) == .closeWindow)
        #expect(shortcuts.action(forKeyCode: m, modifiers: .command) == .minimizeWindow)
        #expect(shortcuts.action(forKeyCode: q, modifiers: .command) == .quitApp)
        #expect(shortcuts.action(forKeyCode: UInt16(kVK_ANSI_H), modifiers: .command) == .hideApp)
        #expect(shortcuts.action(forKeyCode: f, modifiers: .command) == .toggleFullscreen)
    }

    @Test("Every action has a default binding")
    func everyActionIsBound() {
        let shortcuts = ActionShortcuts.default
        for action in SwitcherAction.allCases {
            #expect(shortcuts.binding(for: action) != nil, "\(action) has no default binding")
        }
    }

    // MARK: - Matching

    @Test("An unbound combination matches nothing")
    func unboundComboMatchesNothing() {
        #expect(ActionShortcuts.default.action(forKeyCode: w, modifiers: .option) == nil)
        #expect(ActionShortcuts.default.action(forKeyCode: UInt16(kVK_ANSI_Z), modifiers: .command) == nil)
    }

    /// ⌘W and ⌘⇧W are different commands in most apps, and should be here too.
    @Test("Matching is exact about shift")
    func matchingIsExactAboutShift() {
        #expect(ActionShortcuts.default.action(forKeyCode: w, modifiers: [.command, .shift]) == nil)
        #expect(ActionShortcuts.default.action(forKeyCode: w, modifiers: .command) == .closeWindow)
    }

    /// Turning a binding off must genuinely hand the key back, not silently
    /// swallow it — otherwise ⌘W would do nothing at all rather than reaching the
    /// app underneath.
    @Test("A disabled binding matches nothing")
    func disabledBindingIsInert() {
        var shortcuts = ActionShortcuts.default
        shortcuts.bindings[.closeWindow]?.isEnabled = false

        #expect(shortcuts.action(forKeyCode: w, modifiers: .command) == nil)
        #expect(shortcuts.action(forKeyCode: m, modifiers: .command) == .minimizeWindow)
    }

    @Test("A rebound action responds to its new combination")
    func rebinding() {
        var shortcuts = ActionShortcuts.default
        shortcuts.bindings[.closeWindow] = ActionBinding(
            combo: KeyCombo(keyCode: UInt16(kVK_Delete), modifiers: [.command, .shift])
        )

        #expect(shortcuts.action(forKeyCode: w, modifiers: .command) == nil)
        #expect(shortcuts.action(forKeyCode: UInt16(kVK_Delete),
                                 modifiers: [.command, .shift]) == .closeWindow)
    }

    // MARK: - Claimed keys

    /// The tap has to swallow these, or ⌘W would reach the app underneath and
    /// close one of *its* windows instead of the selected one.
    @Test("Claimed key codes cover every enabled binding")
    func claimedKeyCodes() {
        let claimed = ActionShortcuts.default.claimedKeyCodes

        #expect(claimed.contains(w))
        #expect(claimed.contains(m))
        #expect(claimed.contains(q))
        #expect(claimed.contains(f))
    }

    @Test("A disabled binding's key is not claimed")
    func disabledBindingIsNotClaimed() {
        var shortcuts = ActionShortcuts.default
        // Nothing else in the defaults uses W, so disabling close releases it.
        shortcuts.bindings[.closeWindow]?.isEnabled = false

        #expect(!shortcuts.claimedKeyCodes.contains(w))
    }

    // MARK: - Action metadata

    /// Actions that remove entries force a list rebuild; the others only redraw.
    @Test("List-mutating actions are correctly identified")
    func mutatingActions() {
        #expect(SwitcherAction.closeWindow.mutatesWindowList)
        #expect(SwitcherAction.quitApp.mutatesWindowList)
        #expect(SwitcherAction.hideApp.mutatesWindowList)
        #expect(SwitcherAction.minimizeWindow.mutatesWindowList)

        #expect(!SwitcherAction.toggleFullscreen.mutatesWindowList)
        #expect(!SwitcherAction.selectNext.mutatesWindowList)
        #expect(!SwitcherAction.selectPrevious.mutatesWindowList)
    }

    @Test("Destructive actions are correctly identified")
    func destructiveActions() {
        #expect(SwitcherAction.closeWindow.isDestructive)
        #expect(SwitcherAction.quitApp.isDestructive)
        #expect(!SwitcherAction.minimizeWindow.isDestructive)
        #expect(!SwitcherAction.hideApp.isDestructive)
    }

    @Test("Every action has a display name")
    func displayNames() {
        for action in SwitcherAction.allCases {
            #expect(!action.displayName.isEmpty)
        }
    }

    // MARK: - Persistence

    /// The settings file is meant to be readable and hand-editable, so the
    /// dictionary must encode as a keyed object rather than the flat alternating
    /// array Swift produces for non-CodingKeyRepresentable keys.
    @Test("Bindings encode as a keyed JSON object")
    func encodesAsKeyedObject() throws {
        let data = try JSONEncoder().encode(ActionShortcuts.default)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"closeWindow\""))
        #expect(json.contains("\"toggleFullscreen\""))

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let bindings = try #require(object?["bindings"] as? [String: Any])
        #expect(bindings["closeWindow"] != nil)
        #expect(bindings.count == SwitcherAction.allCases.count)
    }

    @Test("Bindings survive an encode/decode round trip")
    func roundTrip() throws {
        var original = ActionShortcuts.default
        original.bindings[.quitApp]?.isEnabled = false
        original.bindings[.closeWindow] = ActionBinding(
            combo: KeyCombo(keyCode: 99, modifiers: [.control, .option])
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActionShortcuts.self, from: data)

        #expect(decoded == original)
        #expect(decoded.action(forKeyCode: q, modifiers: .command) == nil)
        #expect(decoded.action(forKeyCode: 99, modifiers: [.control, .option]) == .closeWindow)
    }
}
