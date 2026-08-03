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
    ///  3. **Raise the window.** This is what selects *this* window rather than
    ///     the app's frontmost one, and it is what triggers the Space switch when
    ///     the target lives elsewhere.
    ///  4. **Set the app frontmost.** Raising alone does not always bring the
    ///     application forward.
    ///  5. **Activate.** And activating alone does not reliably raise a *specific*
    ///     window. Steps 3 and 4 are both required; neither is redundant.
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

        guard let element = window.axElement else {
            Log.accessibility.error("Cannot focus \(window.appName, privacy: .public): no accessibility element")
            return false
        }

        if window.isMinimized {
            AX.setBool(element, AXAttribute.minimized, false)
        }

        if runningApp.isHidden {
            runningApp.unhide()
        }

        let raised = AX.perform(element, AXAction.raise)

        let appElement = AXUIElementCreateApplication(window.id.pid)
        AX.setMessagingTimeout(appElement, seconds: 1.0)
        AX.setBool(appElement, AXAttribute.frontmost, true)

        // `activate(options:)` with NSApplicationActivateIgnoringOtherApps is
        // deprecated as of macOS 14; the no-argument form is the supported path.
        let activated = runningApp.activate()

        Log.accessibility.debug(
            "Focus \(window.qualifiedTitle, privacy: .public): raised=\(raised) activated=\(activated)"
        )
        return raised || activated
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
