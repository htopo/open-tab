import AppKit
import OpenTabCore
import OpenTabInput
import SwiftUI

/// Drives one switch, start to finish.
///
/// Owns the state machine and translates its effects into real work: showing the
/// panel, moving the selection, focusing a window. Nothing here decides *what*
/// should happen — that is the state machine's job — which keeps the tricky
/// interaction logic in a pure, testable type and leaves this as plumbing.
@MainActor
final class SwitcherController {

    private let registry: WindowRegistry
    private let symbolicHotkeys: SymbolicHotkeyManager
    private var machine: HotkeyStateMachine
    private var tap: EventTap?
    private let panel = OverlayPanel()

    /// Shortcuts in index order. Phase 8 replaces this with the settings store.
    private var shortcuts: [Shortcut]

    private var interaction: InteractionSettings
    private var afterRelease: AfterReleaseBehavior

    /// The list the current switch is operating on. Built once when the switch
    /// starts, so the selection cannot be invalidated by a window appearing
    /// mid-interaction.
    private var currentList: [WindowModel] = []
    private var searchQuery = ""
    private var unfilteredList: [WindowModel] = []

    private var holdTimer: Timer?

    /// Reported once per launch when the takeover is impossible, rather than on
    /// every reconcile.
    private var hasWarnedAboutSymbolicHotkeys = false

    init(registry: WindowRegistry,
         shortcuts: [Shortcut] = Shortcut.defaults(),
         interaction: InteractionSettings = .default,
         afterRelease: AfterReleaseBehavior = .focus,
         symbolicHotkeys: SymbolicHotkeyManager = SymbolicHotkeyManager()) {
        self.registry = registry
        self.shortcuts = shortcuts
        self.interaction = interaction
        self.afterRelease = afterRelease
        self.symbolicHotkeys = symbolicHotkeys
        self.machine = HotkeyStateMachine(interaction: interaction, afterRelease: afterRelease)

        panel.onClickOutside = { [weak self] in
            guard let self, self.interaction.clickOutsideDismisses else { return }
            self.dispatch(.cancelled)
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Repair before claiming anything. A previous run that was killed hard
        // leaves reserved shortcuts disabled with nothing bound to them.
        symbolicHotkeys.repairOnLaunch()

        let tap = EventTap(
            handler: { [weak self] outcome in self?.handle(outcome) },
            onUnavailable: { reason in
                Log.input.error("Input unavailable: \(String(describing: reason), privacy: .public)")
            }
        )
        self.tap = tap

        guard tap.install() else { return }
        applyConfiguration()
    }

    func stop() {
        holdTimer?.invalidate()
        holdTimer = nil
        panel.hide()
        tap?.uninstall()
        tap = nil

        // The single most important thing this app does on the way out.
        symbolicHotkeys.restoreAll()
    }

    /// Re-reads the shortcut list into the tap and the symbolic-hotkey manager.
    func applyConfiguration() {
        let enabled = shortcuts.filter(\.isEnabled)

        tap?.updateConfiguration { config in
            config.shortcuts = enabled.map(\.combo)
            config.overlayKeyCodes = TapMatcher.defaultOverlayKeyCodes
        }

        let results = symbolicHotkeys.reconcile(activeShortcuts: enabled.map(\.combo))

        if results.contains(.unavailable), !hasWarnedAboutSymbolicHotkeys {
            hasWarnedAboutSymbolicHotkeys = true
            warnSymbolicHotkeysUnavailable()
        }
    }

    func updateShortcuts(_ newShortcuts: [Shortcut]) {
        shortcuts = newShortcuts
        applyConfiguration()
    }

    func updateInteraction(_ newInteraction: InteractionSettings, afterRelease: AfterReleaseBehavior) {
        interaction = newInteraction
        self.afterRelease = afterRelease
        machine.interaction = newInteraction
        machine.afterRelease = afterRelease
    }

    /// Manual escape hatch for Settings → Controls → "Restore system shortcuts".
    func restoreSystemShortcuts() {
        symbolicHotkeys.forceRestoreEverything()
    }

    // MARK: - Tap events

    private func handle(_ outcome: TapOutcome) {
        switch outcome {
        case .ignore:
            break

        case .trigger(let shortcut, let reversed):
            beginOrAdvance(shortcut: shortcut, reversed: reversed)

        case .modifiersReleased:
            dispatch(.modifiersReleased)

        case .overlayKey(let keyCode, let flags):
            handleOverlayKey(keyCode: keyCode, flags: flags)

        case .typed(let text):
            dispatch(.typed(text))
        }
    }

    private func beginOrAdvance(shortcut index: Int, reversed: Bool) {
        guard shortcuts.indices.contains(index) else { return }

        // Build the list on the *first* press of an interaction only. Rebuilding
        // on every press would let the ordering shift under the user's fingers.
        if case .idle = machine.state {
            buildList(for: shortcuts[index])
            tap?.updateConfiguration { config in
                config.isSwitcherActive = true
                config.activeModifiers = self.shortcuts[index].combo.modifiers
            }
        }

        dispatch(.triggerPressed(shortcut: index, reversed: reversed))
    }

    private func handleOverlayKey(keyCode: UInt16, flags: CGEventFlags) {
        switch Int(keyCode) {
        case kVKEscape:
            dispatch(.cancelled)
        case kVKReturn, kVKKeypadEnter:
            dispatch(.committed)
        case kVKLeftArrow, kVKUpArrow:
            dispatch(.navigate(delta: -1))
        case kVKRightArrow, kVKDownArrow:
            dispatch(.navigate(delta: 1))
        default:
            // Phase 6 routes the ⌘W / ⌘M / ⌘Q / ⌘H / ⌘F action shortcuts here.
            break
        }
    }

    // MARK: - State machine

    private func dispatch(_ event: HotkeyEvent) {
        let effects = machine.handle(event)
        for effect in effects { apply(effect) }
    }

    private func apply(_ effect: HotkeyEffect) {
        switch effect {
        case .startHoldTimer(let interval):
            startHoldTimer(interval)

        case .cancelHoldTimer:
            holdTimer?.invalidate()
            holdTimer = nil

        case .beginTrackingModifiers:
            break // already handled when the interaction began

        case .showOverlay(let shortcut):
            showOverlay(for: shortcut)

        case .hideOverlay:
            endInteraction()

        case .performInstantSwap:
            // Nothing to hide — the panel was never shown. This is what makes a
            // quick tap flash-free.
            break

        case .setSelection(let index):
            updateSelection(index)

        case .commitSelection(let index):
            commit(index)

        case .cancel:
            endInteraction()

        case .enterSearchMode:
            panel.becomeKeyForSearch()

        case .updateSearchQuery(let query):
            applySearch(query)
        }
    }

    private func startHoldTimer(_ interval: TimeInterval) {
        holdTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatch(.holdThresholdElapsed) }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    // MARK: - List

    private func buildList(for shortcut: Shortcut) {
        let started = DispatchTime.now()
        let snapshot = registry.snapshot()

        unfilteredList = WindowListBuilder.build(
            windows: snapshot.windows,
            apps: snapshot.apps,
            filter: shortcut.filter,
            ordering: shortcut.ordering,
            context: snapshot.context
        )
        searchQuery = ""
        currentList = unfilteredList
        machine.setCount(currentList.count)

        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        Log.overlay.notice(
            "Built switcher list: \(self.currentList.count) entries in \(elapsedMS, format: .fixed(precision: 2))ms"
        )

        // Repair drift in the background. Never blocks this interaction.
        registry.reconcileInBackground()
    }

    private func applySearch(_ query: String) {
        searchQuery = query
        currentList = WindowListBuilder.search(unfilteredList, query: query)
        machine.setCount(currentList.count)
        refreshOverlayContent()
    }

    private func updateSelection(_ index: Int) {
        guard panel.isVisible else { return }
        refreshOverlayContent()
    }

    // MARK: - Overlay

    private func showOverlay(for shortcutIndex: Int) {
        guard !currentList.isEmpty else {
            Log.overlay.notice("Nothing to show — no windows matched")
            return
        }

        refreshOverlayContent()

        let screen = OverlayPanel.screen(
            for: .activeScreen,
            focusedWindowDisplay: currentList.first(where: \.isFocused)?.displayID
        )
        panel.show(on: screen)
    }

    /// Placeholder content. Phase 4 replaces this with the real switcher styles.
    private func refreshOverlayContent() {
        panel.setContent(
            PlaceholderOverlayView(
                windows: currentList,
                selection: machine.selection,
                query: searchQuery
            )
        )
        if panel.isVisible {
            panel.resizeToFit(on: OverlayPanel.screen(for: .activeScreen, focusedWindowDisplay: nil))
        }
    }

    private func endInteraction() {
        holdTimer?.invalidate()
        holdTimer = nil
        panel.hide()
        currentList = []
        unfilteredList = []
        searchQuery = ""

        tap?.updateConfiguration { config in
            config.isSwitcherActive = false
            config.activeModifiers = []
        }
    }

    private func commit(_ index: Int) {
        defer { endInteraction() }

        guard currentList.indices.contains(index) else {
            Log.overlay.notice("Commit ignored: selection \(index) out of range")
            return
        }

        let target = currentList[index]
        Log.overlay.notice("Focusing \(target.qualifiedTitle, privacy: .public)")

        if WindowActions.focus(target) {
            registry.noteFocus(target.id)
        }
    }

    // MARK: - Degraded mode

    private func warnSymbolicHotkeysUnavailable() {
        let alert = NSAlert()
        alert.messageText = "OpenTab cannot take over ⌘Tab on this version of macOS"
        alert.informativeText = """
        The system interface OpenTab uses to free up ⌘Tab is no longer available, \
        so the built-in application switcher will appear alongside OpenTab.

        You can avoid the overlap by choosing a shortcut macOS does not reserve — \
        ⌥Tab works well — in Settings → Controls.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }
}

// Carbon virtual key codes used for overlay navigation.
private let kVKReturn = 0x24
private let kVKTab = 0x30
private let kVKEscape = 0x35
private let kVKKeypadEnter = 0x4C
private let kVKLeftArrow = 0x7B
private let kVKRightArrow = 0x7C
private let kVKDownArrow = 0x7D
private let kVKUpArrow = 0x7E

/// Temporary overlay content for phase 3, replaced by the real styles in phase 4.
private struct PlaceholderOverlayView: View {
    let windows: [WindowModel]
    let selection: Int
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !query.isEmpty {
                Text("Search: \(query)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                HStack(spacing: 8) {
                    if let icon = window.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    Text(window.qualifiedTitle)
                        .lineLimit(1)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(index == selection ? Color.accentColor.opacity(0.85) : Color.clear)
                )
                .foregroundStyle(index == selection ? Color.white : Color.primary)
            }
        }
        .padding(12)
        .frame(width: 460)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// `NSVisualEffectView` bridged into SwiftUI for the panel background.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
