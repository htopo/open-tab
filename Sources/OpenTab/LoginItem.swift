import Foundation
import OpenTabCore
import ServiceManagement

/// Registration as a login item.
///
/// `SMAppService.mainApp` is the modern replacement for the deprecated
/// `SMLoginItemSetEnabled` and for writing into the user's Login Items list by
/// hand. It only works for an app inside a bundle, so a `swift run` build silently
/// does nothing here rather than failing.
enum LoginItem {

    static var isEnabled: Bool {
        guard AppInfo.isBundled else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Brings registration in line with the setting.
    ///
    /// Errors are logged rather than surfaced: the user may have denied the
    /// request in System Settings, which is their prerogative and not a failure
    /// worth an alert.
    static func setEnabled(_ enabled: Bool) {
        guard AppInfo.isBundled else {
            Log.app.debug("Login item ignored: not running from an app bundle")
            return
        }

        let service = SMAppService.mainApp
        do {
            switch (enabled, service.status) {
            case (true, .enabled):
                return
            case (true, _):
                try service.register()
                Log.app.notice("Registered as a login item")
            case (false, .enabled):
                try service.unregister()
                Log.app.notice("Unregistered as a login item")
            case (false, _):
                return
            }
        } catch {
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True when macOS is holding the registration pending user approval, which is
    /// worth telling the user about because the app will not actually start at
    /// login until they approve it.
    static var requiresApproval: Bool {
        guard AppInfo.isBundled else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }
}
