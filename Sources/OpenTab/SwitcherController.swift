import AppKit
import OpenTabCore
import OpenTabInput
import OpenTabShot
import OpenTabUI
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
    private let capture: CaptureCoordinator
    private var machine: HotkeyStateMachine
    private var tap: EventTap?
    private let panel = OverlayPanel()

    /// Thumbnails for the current interaction. Seeded from cache when the overlay
    /// opens and filled in as fresh captures arrive.
    private var thumbnails: [WindowID: NSImage] = [:]

    /// Shortcuts in index order. Phase 8 replaces this with the settings store.
    private var shortcuts: [Shortcut]

    private var interaction: InteractionSettings
    private var afterRelease: AfterReleaseBehavior
    private var appearance: AppearanceSettings
    private var actionShortcuts: ActionShortcuts

    /// The appearance in force for the current interaction, after the active
    /// shortcut's overrides have been merged in.
    private var activeAppearance: AppearanceSettings = .default

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
         capture: CaptureCoordinator,
         shortcuts: [Shortcut] = Shortcut.defaults(),
         interaction: InteractionSettings = .default,
         appearance: AppearanceSettings = .default,
         actionShortcuts: ActionShortcuts = .default,
         symbolicHotkeys: SymbolicHotkeyManager = SymbolicHotkeyManager()) {
        self.registry = registry
        self.capture = capture
        self.shortcuts = shortcuts
        self.interaction = interaction
        self.appearance = appearance
        self.actionShortcuts = actionShortcuts
        self.afterRelease = appearance.afterRelease
        self.symbolicHotkeys = symbolicHotkeys
        self.machine = HotkeyStateMachine(interaction: interaction,
                                          afterRelease: appearance.afterRelease)

        panel.onClickOutside = { [weak self] in
            guard let self, self.interaction.clickOutsideDismisses else { return }
            self.dispatch(.cancelled)
        }

        // Thumbnails arrive after the overlay is already on screen. Each one
        // redraws only itself; the panel is never blocked waiting for them.
        capture.onThumbnail = { [weak self] id, image in
            guard let self, self.panel.isVisible else { return }
            self.thumbnails[id] = image
            self.refreshOverlayContent()
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
            // The tap has to claim whatever the action shortcuts use, or ⌘W would
            // reach the app underneath and close one of *its* windows instead.
            config.overlayKeyCodes = TapMatcher.defaultOverlayKeyCodes
                .union(self.actionShortcuts.claimedKeyCodes)
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

    func updateInteraction(_ newInteraction: InteractionSettings) {
        interaction = newInteraction
        machine.interaction = newInteraction
    }

    func updateActionShortcuts(_ newShortcuts: ActionShortcuts) {
        actionShortcuts = newShortcuts
        applyConfiguration()
    }

    func updateAppearance(_ newAppearance: AppearanceSettings) {
        appearance = newAppearance
        afterRelease = newAppearance.afterRelease
        machine.afterRelease = newAppearance.afterRelease
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
            activeAppearance = appearance.merging(shortcuts[index].appearance)
            machine.afterRelease = activeAppearance.afterRelease
            buildList(for: shortcuts[index])
            tap?.updateConfiguration { config in
                config.isSwitcherActive = true
                config.activeModifiers = self.shortcuts[index].combo.modifiers
            }
        }

        dispatch(.triggerPressed(shortcut: index, reversed: reversed))
    }

    private func handleOverlayKey(keyCode: UInt16, flags: CGEventFlags) {
        // A user-configured action wins over the built-in navigation defaults, so
        // rebinding "select next" to something else actually takes effect.
        let modifiers = ModifierSet(eventFlags: flags)
        if let action = actionShortcuts.action(forKeyCode: keyCode, modifiers: modifiers) {
            perform(action)
            return
        }

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
            break
        }
    }

    // MARK: - Actions on the selection

    /// Performs an action on the highlighted entry without closing the switcher.
    ///
    /// Staying open is deliberate: closing three windows in a row should take
    /// three keystrokes, not three full switcher invocations.
    private func perform(_ action: SwitcherAction) {
        switch action {
        case .selectNext:
            dispatch(.navigate(delta: 1))
            return
        case .selectPrevious:
            dispatch(.navigate(delta: -1))
            return
        default:
            break
        }

        let index = machine.selection
        guard currentList.indices.contains(index) else { return }
        let target = currentList[index]

        Log.overlay.notice(
            "\(action.displayName, privacy: .public) on \(target.qualifiedTitle, privacy: .public)"
        )

        let succeeded: Bool
        switch action {
        case .closeWindow:      succeeded = WindowActions.close(target)
        case .minimizeWindow:   succeeded = WindowActions.minimize(target)
        case .quitApp:          succeeded = WindowActions.quitApplication(target)
        case .hideApp:          succeeded = WindowActions.hideApplication(target)
        case .toggleFullscreen: succeeded = WindowActions.toggleFullscreen(target)
        case .selectNext, .selectPrevious: return
        }

        guard succeeded else {
            Log.overlay.notice("\(action.displayName, privacy: .public) was refused by the application")
            return
        }

        if action.mutatesWindowList {
            // Applications process these asynchronously — a close can raise a save
            // prompt — so the list is rebuilt after a short delay rather than
            // optimistically patched, which would show a window as gone when the
            // user is about to cancel the prompt.
            scheduleListRefresh()
        }
    }

    /// Rebuilds the visible list from the registry, keeping the selection sensible.
    private func scheduleListRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                guard let shortcutIndex = self.machine.state.shortcutIndex,
                      self.shortcuts.indices.contains(shortcutIndex) else { return }

                self.registry.reconcileInBackground()
                self.buildList(for: self.shortcuts[shortcutIndex])
                self.dispatch(.listCountChanged(self.currentList.count))
                self.refreshOverlayContent()
            }
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

        // The panel never becomes key, so it does not inherit appearance the way
        // an ordinary window does; the theme has to be applied explicitly.
        panel.setAppearance(nsAppearance(for: activeAppearance.theme))

        // Seed from cache so the very first frame has images. Anything missing
        // draws as an app icon and is replaced when its capture lands.
        thumbnails = capture.cachedThumbnails(for: currentList)

        refreshOverlayContent()
        panel.show(on: targetScreen())

        requestCaptures()
    }

    /// Asks for fresh captures, selected window first.
    ///
    /// Ordering matters more than it looks: captures are bounded to a handful at a
    /// time, so whatever is asked for first is what the user sees fill in first.
    private func requestCaptures() {
        guard activeAppearance.style == .thumbnails else { return }

        let metrics = SwitcherMetrics.resolve(activeAppearance.size, windowCount: currentList.count)
        capture.setThumbnailSize(CGSize(width: metrics.thumbnailWidth, height: metrics.thumbnailHeight))

        let selection = machine.selection
        let ordered = currentList.enumerated()
            .sorted { abs($0.offset - selection) < abs($1.offset - selection) }
            .map(\.element)

        capture.requestCaptures(for: ordered, scale: targetScreen().backingScaleFactor)
    }

    private func refreshOverlayContent() {
        let model = SwitcherViewModel(
            windows: currentList,
            selection: machine.selection,
            appearance: effectiveAppearance(),
            searchQuery: searchQuery,
            isSearching: {
                if case .searching = machine.state { return true }
                return false
            }(),
            thumbnails: thumbnails
        )

        panel.setContent(
            SwitcherOverlayView(
                model: model,
                onHover: { [weak self] index in self?.dispatch(.hovered(index: index)) },
                onClick: { [weak self] index in
                    self?.dispatch(.hovered(index: index))
                    self?.dispatch(.committed)
                },
                onSearchChange: { [weak self] query in self?.dispatch(.searchChanged(query)) }
            )
        )

        if panel.isVisible {
            panel.resizeToFit(on: targetScreen())
        }
    }

    private func targetScreen() -> NSScreen {
        OverlayPanel.screen(
            for: activeAppearance.screenPlacement,
            focusedWindowDisplay: currentList.first(where: \.isFocused)?.displayID
        )
    }

    /// The appearance actually used to draw, after accounting for what the system
    /// will permit.
    ///
    /// Without Screen Recording there are no thumbnails to draw, so the Thumbnails
    /// style silently becomes App Icons rather than rendering a grid of empty
    /// placeholders. The setting itself is left alone — Settings shows it disabled
    /// with an explanation and a Grant button, and it takes effect the moment
    /// permission is given.
    private func effectiveAppearance() -> AppearanceSettings {
        guard activeAppearance.style == .thumbnails, !capture.isPermitted else {
            return activeAppearance
        }
        var degraded = activeAppearance
        degraded.style = .appIcons
        return degraded
    }

    private func nsAppearance(for theme: SwitcherTheme) -> NSAppearance? {
        switch theme {
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }

    private func endInteraction() {
        holdTimer?.invalidate()
        holdTimer = nil
        panel.hide()
        currentList = []
        unfilteredList = []
        searchQuery = ""
        thumbnails = [:]

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
