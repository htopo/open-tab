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
    private let highlighter = WindowPreviewHighlighter()
    private let gestures = GestureMonitor()

    /// Thumbnails for the current interaction. Seeded from cache when the overlay
    /// opens and filled in as fresh captures arrive.
    private var thumbnails: [WindowID: NSImage] = [:]

    /// Shortcuts in index order. Phase 8 replaces this with the settings store.
    private var shortcuts: [Shortcut]

    private var interaction: InteractionSettings
    private var afterRelease: AfterReleaseBehavior
    private var appearance: AppearanceSettings
    private var actionShortcuts: ActionShortcuts
    private var exceptions: [ExceptionRule]
    private var gestureSettings: GestureSettings

    /// Watches which application is frontmost so the tap knows, synchronously,
    /// whether to pass everything through. Computing this inside the tap callback
    /// would mean querying `NSWorkspace` on the tap thread, which is exactly the
    /// kind of work that gets a tap disabled for overrunning.
    private var activationObserver: (any NSObjectProtocol)?

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

    /// Where the pointer was when the overlay opened, until it has moved.
    ///
    /// SwiftUI reports a hover the moment a view appears under the cursor, with
    /// no movement involved. The overlay appears centred on screen, which is very
    /// often exactly where the pointer is resting — so opening the switcher
    /// selected whatever entry happened to land under it, and releasing ⌘ focused
    /// a window the user never chose. Hover only counts once the pointer has
    /// actually moved.
    private var pointerAnchor: NSPoint?

    /// True while the space bar is held and the list has been widened to every
    /// Space. Reset at the end of every interaction — a held key at the moment
    /// the overlay closes must not leak into the next one.
    private var isOtherSpacesRevealed = false

    /// Pending collapse back to one Desktop after the space bar came up.
    ///
    /// See `setOtherSpacesRevealed`.
    private var collapseTimer: Timer?

    /// Drives the repeat while ⇧ is held down. See `beginShiftRepeat`.
    private var shiftRepeatTimer: Timer?

    /// Watches the input layer for the two failures that are otherwise silent.
    /// See `checkInputHealth`.
    private var watchdogTimer: Timer?

    /// When the active interaction's modifiers were first seen to be up.
    /// nil whenever they are down, or no interaction is running.
    private var modifiersUpSince: Date?

    /// Last value handed to the tap, so only changes are logged.
    private var isPassingShortcutsThrough = false

    /// How often the input layer is checked. Two calls, both cheap: one mach
    /// port query and one read of the current modifier state.
    private static let watchdogInterval: TimeInterval = 2

    /// How long an interaction may sit with its modifiers already released
    /// before it is treated as stranded. Long enough that no real release can
    /// be mistaken for one — a release the tap did see commits in milliseconds.
    private static let strandedGrace: TimeInterval = 1

    /// How long a release of the space bar waits before narrowing the list again.
    ///
    /// Releasing ⌘ and the space bar together is one gesture to the user, but the
    /// keyboard reports two events in whatever order the fingers happened to
    /// leave. Space first meant the list narrowed and the selection jumped home a
    /// few milliseconds before ⌘ committed it — so letting go of both at once
    /// switched to the wrong window, and the only way to reach another Desktop
    /// was to release ⌘ first and hold space a moment longer. Two hundred
    /// milliseconds is far longer than any real gap between two fingers lifting
    /// and short enough that a deliberate release still feels immediate.
    private static let collapseGrace: TimeInterval = 0.2

    /// Suppresses the selection animation for one redraw.
    ///
    /// Set when the panel changes shape — the Desktop columns appearing or
    /// disappearing — where an animated highlight has nothing meaningful to
    /// travel between.
    private var suppressesSelectionAnimation = false

    /// Desktop columns for the current list. Empty unless the space bar is held.
    private var spaceSections: [SpaceSection] = []

    /// Space identifier to user-facing Desktop number.
    ///
    /// Computed from every window the registry knows about, not just the ones on
    /// screen, so the numbers do not shift when the list changes underneath.
    private var desktopNumbering: [Int: Int] = [:]

    /// Reported once per launch when the takeover is impossible, rather than on
    /// every reconcile.
    private var hasWarnedAboutSymbolicHotkeys = false

    init(registry: WindowRegistry,
         capture: CaptureCoordinator,
         shortcuts: [Shortcut] = Shortcut.defaults(),
         interaction: InteractionSettings = .default,
         appearance: AppearanceSettings = .default,
         actionShortcuts: ActionShortcuts = .default,
         exceptions: [ExceptionRule] = ExceptionRule.shippedDefaults,
         gesture: GestureSettings = .default,
         symbolicHotkeys: SymbolicHotkeyManager = SymbolicHotkeyManager()) {
        self.registry = registry
        self.capture = capture
        self.shortcuts = shortcuts
        self.interaction = interaction
        self.appearance = appearance
        self.actionShortcuts = actionShortcuts
        self.exceptions = exceptions
        self.gestureSettings = gesture
        self.afterRelease = appearance.afterRelease
        self.symbolicHotkeys = symbolicHotkeys
        self.machine = HotkeyStateMachine(interaction: interaction,
                                          afterRelease: appearance.afterRelease)

        panel.onClickOutside = { [weak self] in
            guard let self, self.interaction.clickOutsideDismisses else { return }
            self.dispatch(.cancelled)
        }

        panel.onScroll = { [weak self] delta in
            guard let self, self.interaction.scrollNavigates else { return }
            self.navigate(delta, source: "scroll")
        }

        // The gesture opens the switcher with whichever shortcut is first, so it
        // inherits that shortcut's filtering and appearance rather than needing
        // its own parallel configuration.
        gestures.onTrigger = { [weak self] in
            self?.beginOrAdvance(shortcut: 0, reversed: false)
        }
        gestures.onNavigate = { [weak self] delta in
            self?.navigate(delta, source: "gesture")
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
        observeFrontmostApplication()
        gestures.update(settings: gestureSettings)
        applyConfiguration()
        startWatchdog()
    }

    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        holdTimer?.invalidate()
        holdTimer = nil
        collapseTimer?.invalidate()
        collapseTimer = nil
        endShiftRepeat()
        panel.hide()
        highlighter.tearDown()
        gestures.stop()
        tap?.uninstall()
        tap = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

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
            config.shiftStepsBackwards = self.interaction.shiftStepsBackwards
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
        // The tap decides what ⇧ means, so it needs this too.
        applyConfiguration()
    }

    func updateActionShortcuts(_ newShortcuts: ActionShortcuts) {
        actionShortcuts = newShortcuts
        applyConfiguration()
    }

    func updateExceptions(_ newExceptions: [ExceptionRule]) {
        exceptions = newExceptions
        updatePassThroughState()
    }

    func updateGesture(_ newGesture: GestureSettings) {
        gestureSettings = newGesture
        gestures.update(settings: newGesture)
    }

    // MARK: - Input health

    /// Starts the periodic check on the input layer.
    ///
    /// Both failures it looks for share one property that makes them worth
    /// polling for: they leave no trace. A shortcut that never arrives writes
    /// nothing to the log, because every line the switcher emits is written by
    /// code that only runs once the event has already reached it. So the only
    /// way to see either is to go and look.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInputHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func checkInputHealth() {
        // A disabled tap announces itself by delivering a `.tapDisabledBy…`
        // event, which the tap re-enables on. That is the path that works. The
        // path that does not is a tap disabled while it is not delivering
        // anything — nothing arrives to announce it, and ⌘Tab is simply dead
        // until something else happens to call this. Until now the only
        // somethings were waking from sleep and a display change.
        tap?.revalidate()
        recoverStrandedInteraction()
    }

    /// Ends an interaction whose modifiers are demonstrably no longer held.
    ///
    /// The switcher stays open for as long as its modifiers are down, and it
    /// learns they came up from a `.flagsChanged` event. That event is not
    /// guaranteed: another process's tap sits ahead of ours in the chain and
    /// may consume it, and a tap that is briefly disabled misses whatever
    /// passed while it was.
    ///
    /// The interaction is then stranded, and the symptom is not a visible stuck
    /// panel — it is ⌘Tab appearing to do nothing at all. The machine reads the
    /// next press as "advance the selection" of a session the user abandoned,
    /// so no list is built and no window is focused.
    ///
    /// The physical modifier state is readable without an event, which is what
    /// makes the repair possible: `flagsState` asks the window server what is
    /// held right now rather than replaying what we were told.
    private func recoverStrandedInteraction() {
        let index: Int
        switch machine.state {
        case .idle, .searching:
            // Searching releases the modifiers on purpose — that is what puts
            // the keyboard into the search field.
            modifiersUpSince = nil
            return
        case .armed(let shortcut), .visible(let shortcut):
            index = shortcut
        }

        // "Hold" keeps the panel up after release by design.
        guard afterRelease == .focus, shortcuts.indices.contains(index) else {
            modifiersUpSince = nil
            return
        }

        let held = ModifierSet(eventFlags: CGEventSource.flagsState(.combinedSessionState))
        guard held.isDisjoint(with: shortcuts[index].combo.modifiers) else {
            modifiersUpSince = nil
            return
        }

        guard let since = modifiersUpSince else {
            modifiersUpSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= Self.strandedGrace else { return }
        modifiersUpSince = nil

        // Logged as an error with the tap's event count: a count that is still
        // climbing says the tap is alive and this one event was lost, and a
        // frozen one says the tap has stopped delivering entirely. Those are
        // different bugs with the same symptom.
        Log.input.error(
            """
            Interaction stranded: modifiers released without an event reaching us. \
            Recovering. state=\(String(describing: self.machine.state), privacy: .public) \
            tapEvents=\(self.tap?.eventsSeen ?? 0)
            """
        )
        for effect in machine.abandon() { apply(effect) }
    }

    // MARK: - Exceptions

    /// Recomputes whether the tap should pass everything through, and caches the
    /// answer where the tap callback can read it without doing any work.
    private func observeFrontmostApplication() {
        updatePassThroughState()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePassThroughState() }
        }
    }

    private func updatePassThroughState() {
        let shouldPassThrough = ExceptionEngine.shouldIgnoreShortcuts(
            rules: exceptions,
            context: exceptionContext()
        )

        tap?.updateConfiguration { config in
            config.passThroughEverything = shouldPassThrough
        }

        // Both edges, at notice rather than debug. While this is on, the tap
        // declines every event before any other rule runs, so a value that got
        // stuck on would look exactly like a switcher that had stopped
        // existing — and the log would say nothing either way.
        guard shouldPassThrough != isPassingShortcutsThrough else { return }
        isPassingShortcutsThrough = shouldPassThrough

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if shouldPassThrough {
            Log.input.notice("Passing shortcuts through to \(frontmost, privacy: .public)")
        } else {
            Log.input.notice("Claiming shortcuts again; frontmost is \(frontmost, privacy: .public)")
        }
    }

    private func exceptionContext() -> ExceptionEngine.Context {
        ExceptionEngine.Context(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            fullscreenBundleIDs: Set(
                registry.windows.filter(\.isFullscreen).map(\.appBundleID)
            )
        )
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

        case .stepBackward(let isPressed):
            if isPressed { beginShiftRepeat() } else { endShiftRepeat() }

        case .overlayKey(let keyCode, let flags, let isKeyDown):
            handleOverlayKey(keyCode: keyCode, flags: flags, isKeyDown: isKeyDown)

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

        let wasIdle = machine.state == .idle
        dispatch(.triggerPressed(shortcut: index, reversed: reversed))

        // Logged from the second press onwards, so a held Tab autorepeating
        // through the list is as visible in the log as a runaway scroll.
        if !wasIdle {
            Log.overlay.notice(
                "Navigate by tab: \(reversed ? -1 : 1) → selection \(self.machine.selection)"
            )
        }
    }

    /// Whether the space bar currently belongs to the switcher.
    ///
    /// Search mode is excluded: there a space is a space. Everywhere else it can
    /// only be held-to-reveal, because the overlay has no text input to type into.
    private var isSpaceKeyClaimed: Bool {
        guard panel.isVisible,
              let index = machine.state.shortcutIndex,
              shortcuts.indices.contains(index),
              shortcuts[index].filter.canRevealOtherSpaces
        else { return false }
        if case .searching = machine.state { return false }
        return true
    }

    /// Widens the list to every Space while the space bar is held, and narrows it
    /// again on release.
    ///
    /// The highlighted *window* is preserved rather than the highlighted index:
    /// revealing inserts entries, so holding the index still would slide the
    /// selection onto a different window under the user's eyes.
    private func setOtherSpacesRevealed(_ revealed: Bool) {
        // Any pending collapse is settled by whatever happens next: pressing
        // space again cancels it, and the timer firing performs it.
        collapseTimer?.invalidate()
        collapseTimer = nil

        guard isOtherSpacesRevealed != revealed else { return }

        // Narrowing waits. Widening does not — the user is asking to see
        // something and has to see it at once.
        guard revealed else {
            let timer = Timer.scheduledTimer(withTimeInterval: Self.collapseGrace, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyOtherSpacesRevealed(false) }
            }
            RunLoop.main.add(timer, forMode: .common)
            collapseTimer = timer
            return
        }

        applyOtherSpacesRevealed(true)
    }

    private func applyOtherSpacesRevealed(_ revealed: Bool) {
        collapseTimer?.invalidate()
        collapseTimer = nil

        guard isOtherSpacesRevealed != revealed else { return }
        guard let index = machine.state.shortcutIndex,
              shortcuts.indices.contains(index) else { return }

        isOtherSpacesRevealed = revealed
        buildList(for: shortcuts[index])

        // Only one Desktop in play, so there was nothing to reveal. Pressing space
        // asked a question with no answer, and the honest response is to do
        // nothing at all — not to move the selection to the top, which is what the
        // "go to the first other Desktop, or else the start of the list" fallback
        // did on a machine with a single Desktop.
        if revealed, spaceSections.count <= 1 {
            isOtherSpacesRevealed = false
            spaceSections = []
            buildList(for: shortcuts[index])
            updateSpaceKeyClaim()
            return
        }

        dispatch(.listCountChanged(currentList.count))

        // Revealing jumps to the first entry of the next Desktop; letting go
        // returns to the top of the list that was there before. The selection is
        // not preserved across the change on purpose: the point of the gesture is
        // to go somewhere else, and coming back should leave you where you
        // started rather than wherever the peek wandered to.
        if revealed, let next = spaceSections.first(where: { !$0.isCurrent }) {
            machine.setSelection(next.range.lowerBound)
        } else {
            machine.setSelection(0)
        }

        // Newly revealed windows have no thumbnail yet, and the panel has to
        // resize for the extra columns.
        thumbnails.merge(capture.cachedThumbnails(for: currentList)) { existing, _ in existing }

        suppressesSelectionAnimation = true
        refreshOverlayContent()
        suppressesSelectionAnimation = false

        requestCaptures()
        updatePreviewHighlight()
        updateSpaceKeyClaim()

        Log.overlay.notice(
            """
            Other Spaces \(revealed ? "revealed" : "hidden", privacy: .public): \
            \(self.currentList.count) entries in \(self.spaceSections.count) Desktop(s), \
            selection \(self.machine.selection)
            """
        )
    }

    /// Jumps the selection to the first entry of a Desktop, by its number.
    ///
    /// Only reachable while the columns are on screen, which is also the only time
    /// the numbers are visible — asking someone to press 2 without showing them
    /// which Desktop is 2 would be a guessing game.
    private func selectDesktop(number: Int) {
        guard let section = spaceSections.first(where: { $0.number == number }) else {
            Log.overlay.notice("No Desktop \(number) in the current list")
            return
        }
        machine.setSelection(section.range.lowerBound)
        refreshOverlayContent()
        updatePreviewHighlight()
        Log.overlay.notice("Jumped to Desktop \(number), selection \(self.machine.selection)")
    }

    private func handleOverlayKey(keyCode: UInt16, flags: CGEventFlags, isKeyDown: Bool) {
        // Space is the one key with a meaning on both edges: hold to reveal the
        // Spaces the filter is hiding, let go to hide them again.
        if keyCode == kVKSpace, isSpaceKeyClaimed {
            setOtherSpacesRevealed(isKeyDown)
            return
        }

        // Everything else acts on the press. The release is claimed only so the
        // application underneath does not see an unbalanced key-up; acting on it
        // as well moved the selection two entries per arrow press.
        guard isKeyDown else { return }

        if spaceSections.count > 1,
           let digit = TapMatcher.digitKeyCodesInOrder.firstIndex(of: keyCode) {
            selectDesktop(number: digit + 1)
            return
        }

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
            navigate(-1, source: "arrow")
        case kVKRightArrow, kVKDownArrow:
            navigate(1, source: "arrow")
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
            navigate(1, source: "shortcut")
            return
        case .selectPrevious:
            navigate(-1, source: "shortcut")
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
            // Only the UI. A `.commitSelection` may follow in the same batch and
            // still needs the list.
            hideOverlayUI()

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
            // A space is a space once there is a field to type it into.
            updateSpaceKeyClaim()

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

        // Exception rules run before the shortcut's own filters. A window hidden
        // by a per-app rule should not be resurrected by a permissive filter.
        let permitted = ExceptionEngine.filter(
            snapshot.windows,
            rules: exceptions,
            context: exceptionContext()
        )

        // Holding space widens the Space scope for as long as it is held; nothing
        // else about the shortcut's filtering changes.
        var filter = shortcut.filter
        if isOtherSpacesRevealed { filter.spaces = .allSpaces }

        unfilteredList = WindowListBuilder.build(
            windows: permitted,
            apps: snapshot.apps,
            filter: filter,
            ordering: shortcut.ordering,
            context: snapshot.context
        )
        searchQuery = ""

        // Split into Desktop columns only while the space bar is revealing them.
        // The rest of the time a single list is what the user asked for, and the
        // extra reordering would move entries around for no reason.
        if isOtherSpacesRevealed {
            desktopNumbering = SpaceGrouping.numbering(
                for: snapshot.windows.compactMap(\.spaceID)
            )
            let grouped = SpaceGrouping.sectioned(
                unfilteredList,
                currentSpaceID: snapshot.context.activeSpaceID,
                numbering: desktopNumbering
            )
            unfilteredList = grouped.windows
            spaceSections = grouped.sections
        } else {
            spaceSections = []
        }

        currentList = unfilteredList
        machine.setCount(currentList.count)

        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

        // The registry count alongside the list length is what separates "the
        // filter dropped it" from "we never knew about it" — two very different
        // bugs that look identical from the switcher.
        let contents = currentList
            .map { "\($0.appName)@\($0.spaceID.map(String.init) ?? "-")" }
            .joined(separator: ", ")
        Log.overlay.notice(
            """
            Built switcher list: \(self.currentList.count) of \(snapshot.windows.count) known \
            in \(elapsedMS, format: .fixed(precision: 2))ms — \(contents, privacy: .public)
            """
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

    /// Steps back once, then keeps stepping for as long as ⇧ is held.
    ///
    /// Holding Tab advances through the list because the system repeats key-down
    /// events. It generates none for modifier keys, so ⇧ stepped once and then sat
    /// there — the same gesture behaving differently in each direction, for a
    /// reason that is invisible from the outside.
    ///
    /// The rate comes from the user's own Keyboard settings, so it matches every
    /// other held key on the machine rather than a number picked here. Both are
    /// clamped: a delay of zero would start repeating before the user could let go
    /// of a single press, and an interval of zero would spin the run loop.
    private func beginShiftRepeat() {
        navigate(-1, source: "shift")

        shiftRepeatTimer?.invalidate()
        let delay = max(NSEvent.keyRepeatDelay, 0.15)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startShiftRepeating() }
        }
        RunLoop.main.add(timer, forMode: .common)
        shiftRepeatTimer = timer
    }

    private func startShiftRepeating() {
        shiftRepeatTimer?.invalidate()
        let interval = max(NSEvent.keyRepeatInterval, 0.02)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.navigate(-1, source: "shift") }
        }
        RunLoop.main.add(timer, forMode: .common)
        shiftRepeatTimer = timer
    }

    private func endShiftRepeat() {
        shiftRepeatTimer?.invalidate()
        shiftRepeatTimer = nil
    }

    /// Moves the selection and records what moved it.
    ///
    /// Logged because the selection can be moved by five different things —
    /// scroll, trackpad gesture, ⇧, arrow keys, a rebound action — and when it
    /// ends up somewhere the user did not put it, which one was responsible is
    /// the entire question. A runaway shows up here as a burst of lines from one
    /// source, which is how trackpad momentum was caught sliding the selection to
    /// the far end of the list after the user's fingers had already left.
    private func navigate(_ delta: Int, source: String) {
        dispatch(.navigate(delta: delta))
        Log.overlay.notice(
            "Navigate by \(source, privacy: .public): \(delta) → selection \(self.machine.selection)"
        )
    }

    /// Routes a hover, once the pointer has earned the right to be listened to.
    private func handleHover(index: Int) {
        if let anchor = pointerAnchor {
            let now = NSEvent.mouseLocation
            let dx = now.x - anchor.x
            let dy = now.y - anchor.y
            // A few points of slack: a hand resting on the trackpad emits tiny
            // movements that are not a choice.
            guard (dx * dx + dy * dy) > 16 else { return }
            pointerAnchor = nil
        }
        dispatch(.hovered(index: index))
    }

    private func updateSelection(_ index: Int) {
        guard panel.isVisible else { return }
        refreshOverlayContent()
        updatePreviewHighlight()
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

        pointerAnchor = NSEvent.mouseLocation

        refreshOverlayContent()
        panel.show(on: targetScreen(), fadeDuration: fadeInDuration)
        gestures.setSwitcherOpen(true)
        updateSpaceKeyClaim()

        // Alpha is checked after the fade should have finished, not before it
        // starts: a panel that is up, correctly sized, and invisible is the one
        // failure mode this surface has that looks like nothing happening at all.
        //
        // Tied to the generation of the panel this call put up. A switch short
        // enough to commit before the fade finishes — a quick ⌘Tab — is already
        // fading back out when the check lands, and an alpha on its way to zero
        // was being reported as the very bug this is here to catch.
        let expected = fadeInDuration
        let generation = panel.visibilityGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + expected + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                guard self.panel.visibilityGeneration == generation else { return }
                guard self.panel.alphaForLogging < 0.95 else { return }
                Log.overlay.error(
                    "Overlay is on screen but transparent: alpha=\(self.panel.alphaForLogging)"
                )
            }
        }

        updatePreviewHighlight()
        requestCaptures()
    }

    /// Fade durations, zeroed when motion should be suppressed.
    ///
    /// Honours the system's own "reduce motion" setting as well as OpenTab's
    /// toggle: a user who asked the OS to reduce motion should not have to ask
    /// again here.
    private var shouldAnimate: Bool {
        MotionPreference.shouldAnimate(
            userReduceAnimations: activeAppearance.animations.reduceAnimations
        )
    }

    private var fadeInDuration: TimeInterval {
        shouldAnimate ? activeAppearance.animations.fadeInDuration : 0
    }

    private var fadeOutDuration: TimeInterval {
        shouldAnimate ? activeAppearance.animations.fadeOutDuration : 0
    }

    /// Lights up the real window behind the overlay, when the setting is on.
    private func updatePreviewHighlight() {
        guard activeAppearance.previewSelectedWindow else {
            highlighter.hide()
            return
        }
        guard currentList.indices.contains(machine.selection) else {
            highlighter.hide()
            return
        }
        highlighter.show(for: currentList[machine.selection])
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
            thumbnails: thumbnails,
            windowCounts: windowCountsByApplication(),
            // Searching collapses back to one list: the columns describe Desktops,
            // and a filtered list is no longer a description of any Desktop.
            spaceSections: searchQuery.isEmpty ? spaceSections : [],
            animatesSelection: !suppressesSelectionAnimation
        )

        panel.setContent(
            SwitcherOverlayView(
                model: model,
                onHover: { [weak self] index in self?.handleHover(index: index) },
                onClick: { [weak self] index in
                    guard let self else { return }
                    // Not `.hovered`, which the state machine drops when hover
                    // selection is off. A click is unambiguous: it commits what
                    // was clicked, whatever the pointer is otherwise allowed to do.
                    self.machine.setSelection(index)
                    self.dispatch(.committed)
                },
                onSearchChange: { [weak self] query in self?.dispatch(.searchChanged(query)) }
            )
        )

        if panel.isVisible {
            panel.resizeToFit(on: targetScreen())
        }
    }

    /// How many windows each application contributes to the current list.
    ///
    /// Counted over the *visible* list rather than the whole registry, so the
    /// badge agrees with what is on screen — a filter that hid three of an app's
    /// four windows should not leave a "4" next to the one that survived.
    /// Application-only entries are excluded; they represent no window.
    private func windowCountsByApplication() -> [pid_t: Int] {
        var counts: [pid_t: Int] = [:]
        for window in currentList where !window.isApplicationEntry {
            counts[window.id.pid, default: 0] += 1
        }
        return counts
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

    /// Takes the overlay off screen and stops the machinery that only runs while
    /// it is up.
    ///
    /// Deliberately does **not** discard the window list. The state machine emits
    /// `.hideOverlay` before `.commitSelection`, so anything cleared here is gone
    /// by the time the selected window is looked up — which is exactly how commit
    /// used to silently do nothing after a held ⌘Tab: the list was empty, every
    /// index was out of range, and the switch was dropped. Clearing is a separate
    /// step that runs after the selection has been consumed.
    private func hideOverlayUI() {
        holdTimer?.invalidate()
        holdTimer = nil
        collapseTimer?.invalidate()
        collapseTimer = nil
        // A repeat left running past the end of the interaction would keep moving
        // a selection nobody is looking at.
        endShiftRepeat()
        panel.hide(fadeDuration: fadeOutDuration)
        highlighter.hide()
        gestures.setSwitcherOpen(false)

        tap?.updateConfiguration { config in
            config.isSwitcherActive = false
            config.activeModifiers = []
            config.claimsSpaceKey = false
            config.claimsDigitKeys = false
        }
    }

    /// Tells the tap whether to swallow the space bar and the digits right now.
    ///
    /// The digits are claimed only while the Desktop columns are actually drawn.
    /// Taking them any earlier would break typing a number into the search field,
    /// and taking them when there is nothing to jump to would swallow a keystroke
    /// to no effect.
    private func updateSpaceKeyClaim() {
        let claimsSpace = isSpaceKeyClaimed
        let claimsDigits = spaceSections.count > 1
        tap?.updateConfiguration { config in
            config.claimsSpaceKey = claimsSpace
            config.claimsDigitKeys = claimsDigits
        }
    }

    /// Drops everything belonging to the finished interaction.
    private func clearInteractionState() {
        currentList = []
        unfilteredList = []
        searchQuery = ""
        thumbnails = [:]
        isOtherSpacesRevealed = false
        spaceSections = []
        pointerAnchor = nil
    }

    private func endInteraction() {
        hideOverlayUI()
        clearInteractionState()
    }

    private func commit(_ index: Int) {
        // Ordered so the list is still intact for the lookup above it: hide the
        // overlay, act on the selection, and only then forget it.
        defer { endInteraction() }

        guard currentList.indices.contains(index) else {
            Log.overlay.notice(
                "Commit ignored: selection \(index) out of range (list has \(self.currentList.count))"
            )
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
private let kVKSpace = UInt16(0x31)
private let kVKTab = 0x30
private let kVKEscape = 0x35
private let kVKKeypadEnter = 0x4C
private let kVKLeftArrow = 0x7B
private let kVKRightArrow = 0x7C
private let kVKDownArrow = 0x7D
private let kVKUpArrow = 0x7E
