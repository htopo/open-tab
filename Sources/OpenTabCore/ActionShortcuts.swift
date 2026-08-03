import Carbon.HIToolbox
import Foundation

/// Something that can be done to the selected entry while the switcher is open.
public enum SwitcherAction: String, Codable, CaseIterable, Sendable {
    case closeWindow
    case minimizeWindow
    case quitApp
    case hideApp
    case toggleFullscreen
    case selectNext
    case selectPrevious

    public var displayName: String {
        switch self {
        case .closeWindow:      "Close window"
        case .minimizeWindow:   "Minimize window"
        case .quitApp:          "Quit app"
        case .hideApp:          "Hide app"
        case .toggleFullscreen: "Toggle fullscreen"
        case .selectNext:       "Select next"
        case .selectPrevious:   "Select previous"
        }
    }

    /// Whether performing this removes entries from the list, which means the
    /// switcher has to rebuild rather than just redraw.
    public var mutatesWindowList: Bool {
        switch self {
        case .closeWindow, .quitApp, .hideApp, .minimizeWindow: true
        case .toggleFullscreen, .selectNext, .selectPrevious:   false
        }
    }

    /// Whether this action destroys work if triggered by accident.
    ///
    /// Both are one keystroke away from a very similar safe action inside a
    /// switcher, so they route through the owning application's own confirmation
    /// rather than being performed outright.
    public var isDestructive: Bool {
        switch self {
        case .closeWindow, .quitApp: true
        default: false
        }
    }
}

/// One action's binding.
public struct ActionBinding: Codable, Equatable, Sendable {
    public var combo: KeyCombo
    public var isEnabled: Bool

    public init(combo: KeyCombo, isEnabled: Bool = true) {
        self.combo = combo
        self.isEnabled = isEnabled
    }
}

/// The "Shortcuts when active…" sheet.
///
/// These are only live while the overlay is on screen, which is what makes it
/// safe to bind ⌘W and ⌘Q — outside the switcher they belong to whatever app is
/// frontmost, and the event tap passes them straight through.
public struct ActionShortcuts: Codable, Equatable, Sendable {

    public var bindings: [SwitcherAction: ActionBinding]

    public init(bindings: [SwitcherAction: ActionBinding]) {
        self.bindings = bindings
    }

    public static let `default` = ActionShortcuts(bindings: [
        .closeWindow:      ActionBinding(combo: KeyCombo(keyCode: UInt16(kVK_ANSI_W), modifiers: .command)),
        .minimizeWindow:   ActionBinding(combo: KeyCombo(keyCode: UInt16(kVK_ANSI_M), modifiers: .command)),
        .quitApp:          ActionBinding(combo: KeyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: .command)),
        .hideApp:          ActionBinding(combo: KeyCombo(keyCode: UInt16(kVK_ANSI_H), modifiers: .command)),
        .toggleFullscreen: ActionBinding(combo: KeyCombo(keyCode: UInt16(kVK_ANSI_F), modifiers: .command)),
        .selectNext:       ActionBinding(combo: KeyCombo(keyCode: UInt16(kVK_RightArrow), modifiers: [])),
        .selectPrevious:   ActionBinding(combo: KeyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: [])),
    ])

    /// The action bound to a key event, if any.
    ///
    /// Disabled bindings match nothing, so turning one off genuinely hands the key
    /// back rather than silently swallowing it.
    public func action(forKeyCode keyCode: UInt16, modifiers: ModifierSet) -> SwitcherAction? {
        for (action, binding) in bindings where binding.isEnabled {
            // Compared exactly, including shift: ⌘W and ⌘⇧W are different
            // commands in most apps and should be here too.
            if binding.combo.keyCode == keyCode && binding.combo.modifiers == modifiers {
                return action
            }
        }
        return nil
    }

    public func binding(for action: SwitcherAction) -> ActionBinding? {
        bindings[action]
    }

    /// Every key code any enabled binding uses, so the event tap knows what to
    /// claim while the overlay is open.
    public var claimedKeyCodes: Set<UInt16> {
        Set(bindings.values.filter(\.isEnabled).map(\.combo.keyCode))
    }
}

/// Lets `[SwitcherAction: ActionBinding]` encode as a JSON object keyed by the
/// action name, rather than the flat alternating array Swift would otherwise
/// produce. The settings file is meant to be readable and hand-editable.
extension SwitcherAction: CodingKeyRepresentable {}
