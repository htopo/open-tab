import AppKit
import OpenTabAX
import OpenTabCore

/// Owns application lifetime and wires the subsystems together.
///
/// Deliberately thin: it constructs collaborators and forwards lifecycle events.
/// Anything with real behaviour lives in a library target so it can be tested
/// without a running application.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log which undocumented symbols resolved. When a future macOS removes one,
        // this line is the first thing worth looking at in a bug report.
        Log.app.notice("\(PrivateSymbols.describe(), privacy: .public)")

        menuBarController = MenuBarController(
            onQuit: { [weak self] in self?.quit() }
        )

        installSignalHandlers()
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

    // MARK: - Shutdown

    /// Everything that must happen before the process goes away, in an order that
    /// is safe to run from a signal handler as well as from AppKit teardown.
    ///
    /// Idempotent: `applicationWillTerminate` and a signal can both reach it.
    private func performShutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true

        // Phase 3 hooks symbolic-hotkey restoration in here. Restoring the user's
        // ⌘Tab is the single most important thing this app does on the way out.
    }

    private var hasShutDown = false

    private func quit() {
        NSApplication.shared.terminate(nil)
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
                Log.app.notice("Received signal \(sig); shutting down")
                self?.performShutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []
}
