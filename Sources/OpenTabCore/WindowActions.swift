import AppKit
import ApplicationServices
import Foundation
import OpenTabAX

/// Operations performed on a selected window.
///
/// These run on the main actor and are all best-effort: an application can refuse
/// any of them, and a window can vanish between being listed and being acted on.
/// Every method reports success so the caller can decide whether to refresh.
@MainActor
public enum WindowActions {

    // MARK: - Focus

    /// Brings a window to the front and gives it keyboard focus.
    ///
    /// The order of these five steps is what makes it work reliably on macOS 14+,
    /// and each one is there for a reason:
    ///
    ///  1. **Un-minimize first.** A minimized window cannot be raised; the raise
    ///     would silently do nothing.
    ///  2. **Unhide the app.** Same problem one level up — a hidden app's windows
    ///     are not raisable.
    ///  3. **Make it the app's main window.** This is the step that decides which
    ///     Space macOS travels to. Activating an application sends you to the
    ///     Space holding its *main* window, so without this a window on another
    ///     Desktop is raised where it stands and the screen never moves — the app
    ///     comes forward on the Space you were already on, or nothing visible
    ///     happens at all.
    ///  4. **Raise the window.** This is what selects *this* window rather than
    ///     the app's frontmost one.
    ///  5. **Set the app frontmost.** Raising alone does not always bring the
    ///     application forward.
    ///  6. **Activate.** And activating alone does not reliably raise a *specific*
    ///     window. Steps 4 and 5 are both required; neither is redundant.
    ///
    /// Travelling between Desktops also depends on a system setting — Desktop &
    /// Dock → "When switching to an application, switch to a Space with open
    /// windows for the application". It is on by default. With it off, macOS
    /// deliberately stays put and no amount of asking will move it.
    @discardableResult
    public static func focus(_ window: WindowModel) -> Bool {
        guard let runningApp = NSRunningApplication(processIdentifier: window.id.pid) else {
            Log.accessibility.error("Cannot focus: pid \(window.id.pid) is gone")
            return false
        }

        // An application entry has no window to raise — just bring the app forward.
        guard !window.isApplicationEntry else {
            if runningApp.isHidden { runningApp.unhide() }
            let activated = runningApp.activate()
            Log.accessibility.debug("Activated app-only entry \(window.appName, privacy: .public): \(activated)")
            return activated
        }

        // Recovered from the window server because the application would not
        // publish it over Accessibility. There is no element to raise, and
        // activating an application does not travel between Desktops — only
        // raising a window on one does. So the Desktop is changed first.
        //
        // That is what makes the window reachable at all: applications that hide
        // windows from Accessibility typically hide the ones they are not showing,
        // and publish them once their Desktop is in front. Moving there turns an
        // unreachable window into an ordinary one, which `raiseOnceItAppears`
        // then picks up.
        guard let element = window.axElement else {
            if runningApp.isHidden { runningApp.unhide() }

            var travelled = false
            if let space = window.spaceID {
                travelled = PrivateSymbols.switchToSpace(space)
            }

            let activated = runningApp.activate()

            Log.accessibility.notice(
                """
                Focus \(window.qualifiedTitle, privacy: .public) with no accessibility element: \
                movedToDesktop=\(travelled) activated=\(activated) \
                space=\(window.spaceID.map(String.init) ?? "unknown", privacy: .public)
                """
            )

            raiseOnceItAppears(window)
            return activated
        }

        if window.isMinimized {
            AX.setBool(element, AXAttribute.minimized, false)
        }

        if runningApp.isHidden {
            runningApp.unhide()
        }

        let becameMain = AX.setBool(element, AXAttribute.main, true)
        let raised = AX.perform(element, AXAction.raise)

        let appElement = AXUIElementCreateApplication(window.id.pid)
        AX.setMessagingTimeout(appElement, seconds: 1.0)
        AX.setBool(appElement, AXAttribute.frontmost, true)

        // `activate(options:)` with NSApplicationActivateIgnoringOtherApps is
        // deprecated as of macOS 14; the no-argument form is the supported path.
        let activated = runningApp.activate()

        Log.accessibility.notice(
            """
            Focus \(window.qualifiedTitle, privacy: .public): \
            main=\(becameMain) raised=\(raised) activated=\(activated) \
            space=\(window.spaceID.map(String.init) ?? "unknown", privacy: .public)
            """
        )
        return raised || activated
    }

    /// Retries the raise after the application has come forward.
    ///
    /// Applications that hide their windows from Accessibility often hide only the
    /// ones they are not currently showing — a browser publishes the window on the
    /// Desktop you are standing on and nothing else. Bringing the application
    /// forward can change what it is willing to publish, so the window that could
    /// not be raised a moment ago may be raisable now.
    ///
    /// This matters because activating an application alone does not travel to
    /// another Desktop; only raising a window there does. Without it, picking a
    /// browser window parked on Desktop 3 brought the browser forward where you
    /// already were.
    ///
    /// Best effort by construction: it gives up quietly, and every attempt is
    /// cheap. Two tries, because the window list is republished asynchronously
    /// and the first attempt often lands too early.
    private static func raiseOnceItAppears(_ window: WindowModel, attempt: Int = 0) {
        let delays: [TimeInterval] = [0.12, 0.35]
        guard attempt < delays.count else {
            Log.accessibility.notice(
                """
                \(window.appName, privacy: .public) never published window \
                \(window.id.cgWindowID) — it stays on its own Desktop
                """
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            MainActor.assumeIsolated {
                let appElement = AXUIElementCreateApplication(window.id.pid)
                AX.setMessagingTimeout(appElement, seconds: 1.0)

                let match = AX.elements(appElement, AXAttribute.windows).first {
                    AX.windowID(of: $0) == window.id.cgWindowID
                }

                guard let match else {
                    raiseOnceItAppears(window, attempt: attempt + 1)
                    return
                }

                AX.setBool(match, AXAttribute.main, true)
                let raised = AX.perform(match, AXAction.raise)
                Log.accessibility.notice(
                    """
                    \(window.appName, privacy: .public) published window \
                    \(window.id.cgWindowID) after activating; raised=\(raised)
                    """
                )
            }
        }
    }

    // MARK: - Window operations

    /// Closes a window by pressing its close button.
    ///
    /// There is no "close" action in the accessibility API — pressing the button
    /// is the supported route, and it correctly triggers an app's save prompt
    /// rather than discarding work.
    @discardableResult
    public static func close(_ window: WindowModel) -> Bool {
        guard let element = window.axElement, !window.isApplicationEntry else { return false }
        guard let button = AX.element(element, AXAttribute.closeButton) else {
            Log.accessibility.debug("\(window.appName, privacy: .public) window has no close button")
            return false
        }
        return AX.perform(button, AXAction.press)
    }

    @discardableResult
    public static func minimize(_ window: WindowModel) -> Bool {
        guard let element = window.axElement, !window.isApplicationEntry else { return false }
        guard AX.isSettable(element, AXAttribute.minimized) else { return false }
        return AX.setBool(element, AXAttribute.minimized, true)
    }

    @discardableResult
    public static func deminimize(_ window: WindowModel) -> Bool {
        guard let element = window.axElement, !window.isApplicationEntry else { return false }
        return AX.setBool(element, AXAttribute.minimized, false)
    }

    /// Toggles fullscreen.
    ///
    /// Checks settability first: asking an app to fullscreen a window it will not
    /// resize produces a silent no-op that reads as a bug in OpenTab.
    @discardableResult
    public static func toggleFullscreen(_ window: WindowModel) -> Bool {
        guard let element = window.axElement, !window.isApplicationEntry else { return false }
        guard AX.isSettable(element, AXAttribute.fullScreen) else {
            Log.accessibility.debug("\(window.appName, privacy: .public) refuses fullscreen changes")
            return false
        }
        return AX.setBool(element, AXAttribute.fullScreen, !window.isFullscreen)
    }

    // MARK: - Application operations

    @discardableResult
    public static func hideApplication(_ window: WindowModel) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.id.pid) else { return false }
        return app.hide()
    }

    @discardableResult
    public static func unhideApplication(_ window: WindowModel) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.id.pid) else { return false }
        return app.unhide()
    }

    /// Asks an application to quit.
    ///
    /// Deliberately `terminate()` rather than `forceTerminate()`: this is bound to
    /// ⌘Q inside a switcher, where a mis-press is easy, and an app that wants to
    /// prompt about unsaved work must be allowed to.
    @discardableResult
    public static func quitApplication(_ window: WindowModel) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.id.pid) else { return false }
        return app.terminate()
    }
}
