import ApplicationServices
import Foundation

/// Accessibility notifications for one application.
///
/// This is what makes the switcher fast enough to be usable. A full AX
/// enumeration takes hundreds of milliseconds with a normal number of apps open,
/// which is far too slow to run on every hotkey press. Instead the registry is
/// built once and then kept current from these notifications, so opening the
/// switcher is a read of already-correct state.
///
/// One observer is created per application. They are torn down when the app
/// terminates; leaking them keeps the target process's accessibility machinery
/// alive and slowly degrades system performance.
public final class AXAppObserver {

    /// Notifications that can change what the switcher should display.
    public static let windowNotifications: [String] = [
        kAXWindowCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String,
        kAXTitleChangedNotification as String,
        kAXApplicationHiddenNotification as String,
        kAXApplicationShownNotification as String,
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
    ]

    public let pid: pid_t
    public let applicationElement: AXUIElement

    private var observer: AXObserver?
    private let handler: (String, AXUIElement) -> Void
    private var registered: [String] = []

    /// - Parameters:
    ///   - pid: the application to watch.
    ///   - messagingTimeout: cap on how long any AX call to this app may block.
    ///     Applied to the application element, which covers its whole subtree.
    ///   - handler: called on the main run loop with (notification name, element).
    public init?(pid: pid_t,
                 messagingTimeout: Float = 1.0,
                 handler: @escaping (String, AXUIElement) -> Void) {
        self.pid = pid
        self.handler = handler
        self.applicationElement = AXUIElementCreateApplication(pid)

        // Guard every call to this app. An unresponsive application would
        // otherwise block the enumeration thread indefinitely, which is a common
        // real-world failure rather than a theoretical one.
        AX.setMessagingTimeout(applicationElement, seconds: messagingTimeout)

        var observer: AXObserver?
        let result = AXObserverCreate(pid, Self.callback, &observer)
        guard result == .success, let observer else {
            AXLog.ax.debug("AXObserverCreate failed for pid \(pid): \(result.rawValue)")
            return nil
        }
        self.observer = observer

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    deinit {
        invalidate()
    }

    // MARK: - Registration

    /// Subscribes to `notifications`, ignoring any the app refuses.
    ///
    /// Refusal is normal: not every application implements every notification, and
    /// a failure on one must not prevent the rest from being registered.
    public func observe(_ notifications: [String] = AXAppObserver.windowNotifications) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for notification in notifications {
            let result = AXObserverAddNotification(
                observer, applicationElement, notification as CFString, refcon
            )
            if result == .success {
                registered.append(notification)
            } else if result != .notificationAlreadyRegistered {
                AXLog.ax.debug("pid \(self.pid) refused \(notification, privacy: .public): \(result.rawValue)")
            }
        }
    }

    public func invalidate() {
        guard let observer else { return }

        for notification in registered {
            AXObserverRemoveNotification(observer, applicationElement, notification as CFString)
        }
        registered.removeAll()

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        self.observer = nil
    }

    // MARK: - Callback

    fileprivate func handle(notification: String, element: AXUIElement) {
        handler(notification, element)
    }

    /// C trampoline. `refcon` carries an unretained pointer back to the Swift
    /// object; the observer is removed in `invalidate()` before deallocation, so
    /// the pointer cannot outlive its owner.
    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<AXAppObserver>.fromOpaque(refcon).takeUnretainedValue()
        observer.handle(notification: notification as String, element: element)
    }
}
