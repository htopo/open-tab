import AppKit
import OpenTabAX
import OpenTabCore
import OpenTabShot

/// Owns application lifetime and wires the subsystems together.
///
/// Deliberately thin: it constructs collaborators and forwards lifecycle events.
/// Anything with real behaviour lives in a library target so it can be tested
/// without a running application.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private var onboarding: OnboardingWindowController?
    private var permissions: PermissionsMonitor?

    /// True once the switcher subsystems have been started. Guards against
    /// starting them twice when a permission flickers.
    private var isRunning = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log which undocumented symbols resolved. When a future macOS removes one,
        // this line is the first thing worth looking at in a bug report.
        Log.app.notice("\(PrivateSymbols.describe(), privacy: .public)")

        installSignalHandlers()

        menuBarController = MenuBarController(
            onOpenSettings: { [weak self] in self?.showSettings() },
            onQuit: { [weak self] in self?.quit() }
        )

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

    // MARK: - Permission-driven startup

    private func permissionsChanged(from old: PermissionsMonitor.Snapshot,
                                    to new: PermissionsMonitor.Snapshot) {
        if !old.accessibility && new.accessibility {
            // The user just ticked the box. Start working immediately rather than
            // asking them to relaunch.
            startSwitcher()
            onboarding?.dismiss()
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
        guard permissions?.accessibility == true else { return }
        isRunning = true

        Log.app.notice("Accessibility available — starting switcher subsystems")

        // Phase 2 starts the window registry here.
        // Phase 3 installs the event tap and takes over the symbolic hotkeys.
    }

    private func stopSwitcher() {
        guard isRunning else { return }
        isRunning = false

        // Phase 3 releases the event tap and restores symbolic hotkeys here.
    }

    // MARK: - Actions

    private func showSettings() {
        // Phase 7 replaces this with the real settings window.
        Log.app.notice("Settings requested")
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Shutdown

    /// Everything that must happen before the process goes away, in an order that
    /// is safe to run from a signal handler as well as from AppKit teardown.
    ///
    /// Idempotent: `applicationWillTerminate` and a signal can both reach it.
    private func performShutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true

        permissions?.stop()

        // Phase 3 hooks symbolic-hotkey restoration in here. Restoring the user's
        // ⌘Tab is the single most important thing this app does on the way out.
    }

    private var hasShutDown = false

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

    private var signalSources: [DispatchSourceSignal] = []
}
