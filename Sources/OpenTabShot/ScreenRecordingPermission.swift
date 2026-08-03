import CoreGraphics
import Foundation
import OpenTabCore

/// Screen Recording authorisation, which gates thumbnails and nothing else.
///
/// OpenTab must remain fully usable when this is denied: the switcher falls back
/// to app icons and the Thumbnails style is disabled with an inline explanation.
/// Treat a denial as a downgrade, never as an error.
public enum ScreenRecordingPermission {

    /// Whether this process may currently capture window images.
    ///
    /// `CGPreflightScreenCaptureAccess` does not prompt, so it is safe to poll.
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks the system to prompt for Screen Recording access.
    ///
    /// The prompt appears at most once per app *install*; afterwards macOS
    /// silently returns false and the user has to grant it in System Settings.
    /// Callers should therefore always offer a "Open System Settings" path too.
    ///
    /// - Returns: true if access is already granted or was granted immediately.
    @discardableResult
    public static func request() -> Bool {
        if isGranted { return true }
        let granted = CGRequestScreenCaptureAccess()
        Log.permissions.notice("Screen Recording request returned \(granted)")
        return granted
    }

    /// Deep link to the Screen Recording list in System Settings.
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}
