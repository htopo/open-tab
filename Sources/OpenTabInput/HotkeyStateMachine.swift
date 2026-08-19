import Foundation
import OpenTabCore

/// Where the switcher is in its interaction cycle.
public enum HotkeyState: Equatable, Sendable {
    /// Nothing happening.
    case idle

    /// The shortcut fired but the hold threshold has not elapsed. No panel is
    /// visible. Releasing from here performs an instant swap with no flash, which
    /// is what makes a quick tap feel like the system switcher.
    case armed(shortcut: Int)

    /// The overlay is on screen.
    case visible(shortcut: Int)

    /// The overlay is on screen and keystrokes go to a search field rather than to
    /// navigation.
    case searching(shortcut: Int)

    public var shortcutIndex: Int? {
        switch self {
        case .idle: nil
        case .armed(let i), .visible(let i), .searching(let i): i
        }
    }

    public var isOverlayVisible: Bool {
        switch self {
        case .idle, .armed: false
        case .visible, .searching: true
        }
    }
}

/// Something that happened, from the event tap or the UI.
public enum HotkeyEvent: Equatable, Sendable {
    /// The trigger combination was pressed. `reversed` is ⇧ being held.
    case triggerPressed(shortcut: Int, reversed: Bool)
    /// All of the shortcut's modifier keys came up.
    case modifiersReleased
    /// The hold timer fired.
    case holdThresholdElapsed
    /// Escape, or a click outside the overlay.
    case cancelled
    /// Return, or a click on an entry.
    case committed
    /// Arrow-key or scroll navigation while the overlay is open.
    case navigate(delta: Int)
    /// The pointer moved onto an entry.
    case hovered(index: Int)
    /// A printable character was typed while the overlay was open.
    case typed(String)
    /// The search field content changed.
    case searchChanged(String)
    /// The list length changed underneath the selection.
    case listCountChanged(Int)
}

/// What the host should do in response.
///
/// The machine never performs side effects itself; it returns them. That is what
/// lets the whole interaction be driven by synthetic events in tests, with no
/// event tap, no window server, and no overlay.
public enum HotkeyEffect: Equatable, Sendable {
    case startHoldTimer(TimeInterval)
    case cancelHoldTimer
    case showOverlay(shortcut: Int)
    case hideOverlay
    /// Focus the previous window directly, without ever showing the panel.
    case performInstantSwap
    case setSelection(Int)
    case commitSelection(Int)
    case cancel
    case enterSearchMode
    case updateSearchQuery(String)
    case beginTrackingModifiers(Int)
}

/// The hold-and-cycle interaction, as a pure state machine.
///
/// This is the most subtle part of OpenTab, and the part most worth having
/// isolated from AppKit: every transition below is reachable from a test without
/// a running event tap.
///
/// ```
///        ┌──────┐  trigger pressed
///        │ IDLE │───────────────────────┐
///        └──▲───┘                       ▼
///           │  released early    ┌──────────────┐
///           │  ── instant swap ──│    ARMED     │
///           │                    └──────┬───────┘
///           │                           │ threshold elapsed
///           │                           │ or trigger pressed again
///           │  released          ┌──────▼───────┐
///           └────────────────────│   VISIBLE    │──── typing ───▶ SEARCHING
///              ── commit ──      └──────┬───────┘
///                                       │ Esc / click away
///                                       ▼  ── cancel ──
/// ```
public struct HotkeyStateMachine {

    public private(set) var state: HotkeyState = .idle

    /// Index into the currently built window list.
    public private(set) var selection: Int = 0

    /// How many entries the list currently holds.
    public private(set) var count: Int = 0

    public var interaction: InteractionSettings
    public var afterRelease: AfterReleaseBehavior

    public init(interaction: InteractionSettings = .default,
                afterRelease: AfterReleaseBehavior = .focus) {
        self.interaction = interaction
        self.afterRelease = afterRelease
    }

    // MARK: - Event handling

    public mutating func handle(_ event: HotkeyEvent) -> [HotkeyEffect] {
        switch state {
        case .idle:      return handleIdle(event)
        case .armed(let shortcut):     return handleArmed(event, shortcut: shortcut)
        case .visible(let shortcut):   return handleVisible(event, shortcut: shortcut)
        case .searching(let shortcut): return handleSearching(event, shortcut: shortcut)
        }
    }

    /// Moves the selection to a specific entry.
    ///
    /// For rebuilds that shift indices under the user without them navigating —
    /// revealing the windows a Space filter was hiding, say. Clamped, and
    /// ignored while idle.
    public mutating func setSelection(_ index: Int) {
        guard state != .idle else { return }
        selection = clamp(index)
    }

    /// Tells the machine how long the list is, so selection can be clamped and
    /// wrapped. Called whenever the list is rebuilt.
    public mutating func setCount(_ newCount: Int) {
        count = max(0, newCount)
        selection = clamp(selection)
    }

    // MARK: - IDLE

    private mutating func handleIdle(_ event: HotkeyEvent) -> [HotkeyEffect] {
        guard case .triggerPressed(let shortcut, let reversed) = event else { return [] }

        state = .armed(shortcut: shortcut)

        // Selection starts on the *second* entry. The first is the window the user
        // is already on, so "tap once" means "go to the one before this" — the
        // behaviour that makes ⌘Tab a toggle between two windows.
        selection = clamp(reversed ? -1 : 1)

        return [
            .beginTrackingModifiers(shortcut),
            .startHoldTimer(interaction.holdThreshold),
            .setSelection(selection),
        ]
    }

    // MARK: - ARMED

    private mutating func handleArmed(_ event: HotkeyEvent, shortcut: Int) -> [HotkeyEffect] {
        switch event {
        case .holdThresholdElapsed:
            state = .visible(shortcut: shortcut)
            return [.showOverlay(shortcut: shortcut)]

        case .triggerPressed(_, let reversed):
            // A second press before the threshold means the user is cycling, not
            // tapping. Show the panel immediately rather than waiting out the
            // remaining milliseconds.
            state = .visible(shortcut: shortcut)
            selection = advanced(by: reversed ? -1 : 1)
            return [.cancelHoldTimer, .showOverlay(shortcut: shortcut), .setSelection(selection)]

        case .modifiersReleased:
            // The quick tap. No panel was ever shown, so there is nothing to hide.
            state = .idle
            let target = selection
            selection = 0
            return [.cancelHoldTimer, .performInstantSwap, .commitSelection(target)]

        case .navigate(let delta):
            // Navigating during the hold window — a ⇧ tap, a scroll — means the
            // user is choosing rather than tapping through. Show the panel now,
            // exactly as a second trigger press does.
            state = .visible(shortcut: shortcut)
            selection = advanced(by: delta)
            return [.cancelHoldTimer, .showOverlay(shortcut: shortcut), .setSelection(selection)]

        case .cancelled:
            state = .idle
            selection = 0
            return [.cancelHoldTimer, .cancel]

        case .listCountChanged(let newCount):
            setCount(newCount)
            return [.setSelection(selection)]

        default:
            return []
        }
    }

    // MARK: - VISIBLE

    private mutating func handleVisible(_ event: HotkeyEvent, shortcut: Int) -> [HotkeyEffect] {
        switch event {
        case .triggerPressed(_, let reversed):
            selection = advanced(by: reversed ? -1 : 1)
            return [.setSelection(selection)]

        case .navigate(let delta):
            selection = advanced(by: delta)
            return [.setSelection(selection)]

        case .hovered(let index):
            guard interaction.mouseHoverSelects, index != selection else { return [] }
            selection = clamp(index)
            return [.setSelection(selection)]

        case .modifiersReleased:
            switch afterRelease {
            case .focus:
                return commit()
            case .hold:
                // Panel stays up; Return or a click is now required.
                return []
            case .search:
                state = .searching(shortcut: shortcut)
                return [.enterSearchMode]
            }

        case .committed:
            return commit()

        case .cancelled:
            guard interaction.escapeCancels else { return [] }
            return cancel()

        case .typed(let text):
            // Typing a printable character starts filtering, whatever the
            // after-release setting says.
            state = .searching(shortcut: shortcut)
            return [.enterSearchMode, .updateSearchQuery(text)]

        case .listCountChanged(let newCount):
            setCount(newCount)
            return [.setSelection(selection)]

        case .holdThresholdElapsed, .searchChanged:
            return []
        }
    }

    // MARK: - SEARCHING

    private mutating func handleSearching(_ event: HotkeyEvent, shortcut: Int) -> [HotkeyEffect] {
        switch event {
        case .searchChanged(let query):
            // Filtering changes the list, so the selection returns to the top —
            // leaving it where it was would point at an unrelated window.
            selection = 0
            return [.updateSearchQuery(query), .setSelection(0)]

        case .triggerPressed(_, let reversed):
            selection = advanced(by: reversed ? -1 : 1)
            return [.setSelection(selection)]

        case .navigate(let delta):
            selection = advanced(by: delta)
            return [.setSelection(selection)]

        case .hovered(let index):
            guard interaction.mouseHoverSelects, index != selection else { return [] }
            selection = clamp(index)
            return [.setSelection(selection)]

        case .committed:
            return commit()

        case .cancelled:
            guard interaction.escapeCancels else { return [] }
            return cancel()

        case .listCountChanged(let newCount):
            setCount(newCount)
            return [.setSelection(selection)]

        case .modifiersReleased, .holdThresholdElapsed, .typed:
            // Modifiers are irrelevant once the field has focus.
            return []
        }
    }

    // MARK: - Shared transitions

    private mutating func commit() -> [HotkeyEffect] {
        let target = selection
        state = .idle
        selection = 0
        return [.hideOverlay, .commitSelection(target)]
    }

    private mutating func cancel() -> [HotkeyEffect] {
        state = .idle
        selection = 0
        return [.hideOverlay, .cancel]
    }

    // MARK: - Selection arithmetic

    /// Moves the selection, wrapping or clamping per settings.
    private func advanced(by delta: Int) -> Int {
        guard count > 0 else { return 0 }

        if interaction.wrapAround {
            // Modulo that stays correct for negative deltas larger than count.
            let raw = (selection + delta) % count
            return raw < 0 ? raw + count : raw
        }
        return min(max(selection + delta, 0), count - 1)
    }

    /// Brings an index into range, wrapping when enabled so that the initial
    /// "second entry" selection still works in a one-window list.
    private func clamp(_ index: Int) -> Int {
        guard count > 0 else { return 0 }
        if interaction.wrapAround {
            let raw = index % count
            return raw < 0 ? raw + count : raw
        }
        return min(max(index, 0), count - 1)
    }
}
