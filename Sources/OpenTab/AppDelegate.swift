import AppKit
import OpenTabAX
import OpenTabCore
import OpenTabInput
import OpenTabShot
import OpenTabUI

/// Owns application lifetime and wires the subsystems together.
///
/// Deliberately thin: it constructs collaborators, forwards lifecycle events, and
/// fans settings changes out to whoever cares. Anything with real behaviour lives
/// in a library target so it can be tested without a running application.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var permissions: PermissionsMonitor?
    private var registry: WindowRegistry?
    private var switcher: SwitcherController?
    private var capture: CaptureCoordinator?
    private var store: SettingsStore?
    private var updater: UpdateController?

    /// Tracks focus transitions so the outgoing window can be photographed before
    /// it stops being capturable.
    private var previouslyFocusedWindow: WindowID?

    /// True once the switcher subsystems have been started. Guards against
    /// starting them twice when a permission flickers.
    private var isRunning = false
    private var hasShutDown = false
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log which undocumented symbols resolved. When a future macOS removes one,
        // this line is the first thing worth looking at in a bug report.
        Log.app.notice("\(PrivateSymbols.describe(), privacy: .public)")

        installSignalHandlers()

        let store = SettingsStore()
        self.store = store
        store.onChange = { [weak self] old, new in
            self?.settingsChanged(from: old, to: new)
        }

        LoginItem.unregisterStaleDevelopmentEntry()
        LoginItem.setEnabled(store.settings.general.startAtLogin)
        updater = UpdateController(policy: store.settings.general.updatePolicy)

        menuBarController = MenuBarController(
            variant: store.settings.general.menuBarIconVariant,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onLogWindowList: { [weak self] in self?.logWindowList() },
            onQuit: { [weak self] in self?.quit() }
        )
        applyMenuBarVisibility(store.settings.general)

        let permissions = PermissionsMonitor(screenRecordingProbe: { ScreenRecordingPermission.isGranted })
        self.permissions = permissions
        permissions.onChange = { [weak self] old, new in
            self?.permissionsChanged(from: old, to: new)
        }
        permissions.start()

        Log.app.notice(
            "Launch permission state: accessibility=\(permissions.accessibility) screenRecording=\(permissions.screenRecording)"
        )

        if permissions.accessibility {
            startSwitcher()
        } else {
            presentOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("OpenTab terminating")
        performShutdown()
    }

    /// The app has no windows in its normal state, so it must not quit when the
    /// last one closes — that would kill the switcher the moment Settings closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Relaunching an already-running LSUIElement app is the only way back in when
    /// the menu-bar icon is hidden, so treat it as "show me the settings".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if permissions?.accessibility == false {
            presentOnboarding()
        } else {
            showSettings()
        }
        return true
    }

    // MARK: - Settings changes

    /// Fans a settings change out to the subsystems that care.
    ///
    /// Each is compared individually so that dragging one slider does not, for
    /// example, tear down and rebuild the event tap.
    private func settingsChanged(from old: Settings, to new: Settings) {
        if old.shortcuts != new.shortcuts {
            switcher?.updateShortcuts(new.shortcuts)
        }
        if old.interaction != new.interaction {
            switcher?.updateInteraction(new.interaction)
        }
        if old.appearance != new.appearance {
            switcher?.updateAppearance(new.appearance)
        }
        if old.actionShortcuts != new.actionShortcuts {
            switcher?.updateActionShortcuts(new.actionShortcuts)
        }
        if old.exceptions != new.exceptions {
            switcher?.updateExceptions(new.exceptions)
        }
        if old.gesture != new.gesture {
            switcher?.updateGesture(new.gesture)
        }
        if old.general.captureWindowsInBackground != new.general.captureWindowsInBackground {
            capture?.isBackgroundCaptureEnabled = new.general.captureWindowsInBackground
        }
        if old.general.startAtLogin != new.general.startAtLogin {
            LoginItem.setEnabled(new.general.startAtLogin)
        }
        if old.general.showMenuBarIcon != new.general.showMenuBarIcon
            || old.general.menuBarIconVariant != new.general.menuBarIconVariant {
            menuBarController?.setVariant(new.general.menuBarIconVariant)
            applyMenuBarVisibility(new.general)
        }
        if old.general.updatePolicy != new.general.updatePolicy {
            if updater?.isAvailable == true {
                updater?.apply(policy: new.general.updatePolicy)
            } else if new.general.updatePolicy != .never {
                // Switching away from "never" starts the updater that was
                // deliberately not created at launch.
                updater = UpdateController(policy: new.general.updatePolicy)
            }
        }
        if old.general.languageCode != new.general.languageCode {
            // macOS resolves an app's language at launch, so this takes effect on
            // the next start rather than now.
            LanguageOverride.apply(new.general.languageCode)
            Log.app.notice("Language override set; applies on next launch")
        }
    }

    private func applyMenuBarVisibility(_ general: GeneralSettings) {
        general.showMenuBarIcon ? menuBarController?.show() : menuBarController?.hide()
    }

    // MARK: - Permission-driven startup

    private func permissionsChanged(from old: PermissionsMonitor.Snapshot,
                                    to new: PermissionsMonitor.Snapshot) {
        if !old.accessibility && new.accessibility {
            // The user just ticked the box. Start working immediately rather than
            // asking them to relaunch.
            startSwitcher()
            onboarding?.dismiss()
        }

        if old.screenRecording != new.screenRecording {
            // Thumbnails become available or unavailable immediately; no relaunch.
            capture?.refreshPermission()
            Log.permissions.notice("Screen Recording now \(new.screenRecording ? "granted" : "denied")")
        }

        if old.accessibility && !new.accessibility {
            // Revoked mid-session, or the code signature changed underneath us.
            Log.permissions.error("Accessibility was revoked; suspending switcher")
            stopSwitcher()
            presentOnboarding()
        }
    }

    private func presentOnboarding() {
        guard let permissions else { return }
        if onboarding == nil {
            onboarding = OnboardingWindowController(permissions: permissions) { [weak self] in
                self?.startSwitcher()
            }
        }
        onboarding?.show()
    }

    /// Brings up everything that needs Accessibility. Idempotent.
    private func startSwitcher() {
        guard !isRunning else { return }
        guard permissions?.accessibility == true, let store else { return }
        isRunning = true

        Log.app.notice("Accessibility available — starting switcher subsystems")

        let registry = WindowRegistry()
        self.registry = registry

        let capture = CaptureCoordinator(
            isBackgroundCaptureEnabled: store.settings.general.captureWindowsInBackground
        )
        self.capture = capture
        capture.start()

        // Keep the capture layer's idea of what exists in step with the registry,
        // and take a last photograph of any window that is about to become
        // uncapturable. By the time a window reports itself minimized, macOS has
        // already stopped compositing it — losing focus is the last reliable moment.
        registry.onChange = { [weak self] in
            guard let self, let registry = self.registry else { return }
            capture.updateTrackedWindows(registry.windows)

            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            if let focused = registry.windows.first(where: \.isFocused) {
                if let previous = self.previouslyFocusedWindow, previous != focused.id,
                   let losing = registry.windows.first(where: { $0.id == previous }) {
                    capture.captureBeforeItBecomesUnavailable(losing, scale: scale)
                }
                self.previouslyFocusedWindow = focused.id
            }
        }

        registry.start()

        let switcher = SwitcherController(
            registry: registry,
            capture: capture,
            shortcuts: store.settings.shortcuts,
            interaction: store.settings.interaction,
            appearance: store.settings.appearance,
            actionShortcuts: store.settings.actionShortcuts,
            exceptions: store.settings.exceptions,
            gesture: store.settings.gesture
        )
        self.switcher = switcher
        switcher.start()
    }

    private func stopSwitcher() {
        guard isRunning else { return }
        isRunning = false

        // Order matters: the switcher restores the system's reserved shortcuts,
        // and that must happen whether or not anything else succeeds.
        switcher?.stop()
        switcher = nil

        capture?.stop()
        capture = nil

        registry?.stop()
        registry = nil
    }

    // MARK: - Settings window

    private func showSettings() {
        guard let store else { return }

        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store) { [weak self] in
                self?.makeSettingsEnvironment() ?? Self.fallbackEnvironment
            }
        }
        settingsWindow?.show()
    }

    private func makeSettingsEnvironment() -> SettingsEnvironment {
        SettingsEnvironment(
            screenRecordingGranted: permissions?.screenRecording ?? false,
            displayNames: NSScreen.screens.map(\.localizedName),
            availableLanguages: Self.shippedLanguages,
            symbolicHotkeysSupported: PrivateSymbols.canControlSymbolicHotKeys,
            onGrantScreenRecording: { [weak self] in
                ScreenRecordingPermission.request()
                self?.permissions?.openSettings(for: .screenRecording)
            },
            onRestoreSystemShortcuts: { [weak self] in
                self?.switcher?.restoreSystemShortcuts()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates()
            },
            onExportSettings: { [weak self] in
                self?.settingsWindow?.exportSettings()
            },
            onImportSettings: { [weak self] in
                self?.settingsWindow?.importSettings()
            },
            onResetSettings: { [weak self] in
                self?.resetSettingsAndRestart()
            },
            onQuit: { [weak self] in
                self?.quit()
            }
        )
    }

    /// Used only if the delegate has gone away while the window is still up.
    private static let fallbackEnvironment = SettingsEnvironment(
        screenRecordingGranted: false,
        displayNames: [],
        availableLanguages: [],
        symbolicHotkeysSupported: false,
        onGrantScreenRecording: {},
        onRestoreSystemShortcuts: {},
        onCheckForUpdates: {},
        onExportSettings: {},
        onImportSettings: {},
        onResetSettings: {},
        onQuit: { NSApplication.shared.terminate(nil) }
    )

    /// Localizations this build actually ships strings for.
    ///
    /// Read from the resource bundle rather than hard-coded, so the picker cannot
    /// offer a language whose strings are missing. Only English so far; the
    /// plumbing exists so that adding one is a resource change, not a code change.
    private static var shippedLanguages: [(code: String, name: String)] {
        LanguageOverride.availableLanguages.map { code in
            // Named in the language itself, which is what someone looking for
            // their own language will recognise.
            let locale = Locale(identifier: code)
            let name = locale.localizedString(forIdentifier: code)
                ?? Locale.current.localizedString(forIdentifier: code)
                ?? code
            return (code, name.localizedCapitalized)
        }
    }

    // MARK: - Actions

    private func checkForUpdates() {
        Log.updates.notice("Manual update check requested")
        updater?.checkForUpdates()
    }

    private func resetSettingsAndRestart() {
        store?.resetToDefaults()

        // Restore the system's shortcuts before relaunching, so the new process
        // starts from a clean slate rather than inheriting a claim it does not
        // know about.
        switcher?.stop()

        guard AppInfo.isBundled else {
            Log.app.notice("Reset complete; relaunch skipped (not running from a bundle)")
            NSApplication.shared.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Dumps what the registry currently believes is open, and how long reading it
    /// took.
    ///
    /// The timing is the point: the overlay has to be on screen in well under
    /// 100 ms, so the snapshot read has to be effectively free. If this ever
    /// reports milliseconds rather than microseconds, the incremental registry has
    /// stopped working and something is re-enumerating on the hot path.
    private func logWindowList() {
        guard let registry else {
            Log.registry.notice("Window list unavailable — switcher not running")
            return
        }

        let started = DispatchTime.now()
        let snapshot = registry.snapshot()
        let list = WindowListBuilder.build(
            windows: snapshot.windows,
            apps: snapshot.apps,
            context: snapshot.context
        )
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

        Log.registry.notice(
            "Window list: \(list.count) entries from \(snapshot.apps.count) apps, built in \(elapsedMS, format: .fixed(precision: 3))ms"
        )

        for (index, window) in list.enumerated() {
            var flags: [String] = []
            if window.isFocused { flags.append("focused") }
            if window.isMinimized { flags.append("minimized") }
            if window.isHidden { flags.append("hidden") }
            if window.isFullscreen { flags.append("fullscreen") }
            if window.isApplicationEntry { flags.append("no-windows") }

            let space = window.spaceID.map(String.init) ?? "-"
            let display = window.displayID.map(String.init) ?? "-"
            let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ","))]"

            Log.registry.notice(
                """
                \(String(format: "%3d", index), privacy: .public). \
                \(window.qualifiedTitle, privacy: .public) \
                (wid \(window.id.cgWindowID), pid \(window.id.pid), space \(space, privacy: .public), display \(display, privacy: .public))\
                \(suffix, privacy: .public)
                """
            )
        }
    }

    // MARK: - Shutdown

    /// Everything that must happen before the process goes away, in an order that
    /// is safe to run from a signal handler as well as from AppKit teardown.
    ///
    /// Idempotent: `applicationWillTerminate` and a signal can both reach it.
    private func performShutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true

        // First and unconditionally: give the user their ⌘Tab back. Everything
        // else here is housekeeping, but leaving a reserved shortcut disabled with
        // nothing bound to it is the worst failure this app can produce.
        switcher?.stop()
        switcher = nil

        capture?.stop()
        capture = nil

        registry?.stop()
        permissions?.stop()

        // Write any change made in the last half-second before the debounce fires.
        store?.flush()
    }

    /// AppKit does not deliver `applicationWillTerminate` for SIGINT/SIGTERM, and
    /// those are exactly the paths a developer hits with Ctrl-C or `killall`. A
    /// dispatch source keeps the handler off the (async-signal-unsafe) signal
    /// context and onto the main queue.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    Log.app.notice("Received signal \(sig); shutting down")
                    self?.performShutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
