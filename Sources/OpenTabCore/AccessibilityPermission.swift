import ApplicationServices
import Foundation

/// Accessibility authorisation, which OpenTab cannot function without.
///
/// Three separate subsystems depend on it — window enumeration, focusing a
/// specific window, and the keyboard event tap — so there is no degraded mode to
/// fall back to. When it is missing the app shows onboarding and waits.
public enum AccessibilityPermission {

    /// Whether this process is currently trusted.
    ///
    /// This must be re-read rather than cached. macOS keys the grant to the app's
    /// designated requirement, so it can stop applying after an update without any
    /// notification, and the user can revoke it at any time from System Settings.
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Checks trust and, if absent, asks macOS to show the "grant access" prompt.
    ///
    /// The prompt also adds OpenTab to the Accessibility list in a disabled state,
    /// which is what makes the checkbox available for the user to tick. macOS only
    /// shows the dialog once per app, so callers must always offer the "Open System
    /// Settings" path as well.
    @discardableResult
    public static func requestPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let granted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        Log.permissions.notice("Accessibility prompt requested; granted=\(granted)")
        return granted
    }

    /// Deep link to the Accessibility list in System Settings.
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}
