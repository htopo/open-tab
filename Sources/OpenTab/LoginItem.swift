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
        guard isRegisterable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Whether this build should be allowed to register itself.
    ///
    /// A build running out of `dist/` or `.build/` is a development build. macOS
    /// records the *path* of a login item, so registering one would leave a stale
    /// entry pointing into a build tree that gets deleted on the next clean — and
    /// the user would have to hunt through System Settings to find out why macOS
    /// complains about a missing login item every morning.
    static var isRegisterable: Bool {
        guard AppInfo.isBundled else { return false }

        let path = Bundle.main.bundleURL.path
        let developmentMarkers = ["/dist/", "/.build/", "/DerivedData/"]
        return !developmentMarkers.contains { path.contains($0) }
    }

    /// Brings registration in line with the setting.
    ///
    /// Errors are logged rather than surfaced: the user may have denied the
    /// request in System Settings, which is their prerogative and not a failure
    /// worth an alert.
    static func setEnabled(_ enabled: Bool) {
        guard isRegisterable else {
            Log.app.debug("Login item ignored: development build or not bundled")
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
        guard isRegisterable else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// Removes a registration left behind by an earlier build.
    ///
    /// Called at launch by development builds, which never register but may have
    /// done so before this guard existed.
    static func unregisterStaleDevelopmentEntry() {
        guard AppInfo.isBundled, !isRegisterable else { return }
        guard SMAppService.mainApp.status == .enabled else { return }

        try? SMAppService.mainApp.unregister()
        Log.app.notice("Removed a login item registered by a development build")
    }
}
