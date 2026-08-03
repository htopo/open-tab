import AppKit
import OpenTabCore
import Sparkle

/// Software updates, via Sparkle.
///
/// Sparkle rather than anything Apple-provided because OpenTab is distributed
/// outside the App Store and is not notarized. Sparkle's appcast is signed with
/// its own EdDSA key pair, which is completely independent of Apple code signing,
/// so update integrity does not depend on having a Developer ID.
@MainActor
final class UpdateController {

    private var updaterController: SPUStandardUpdaterController?

    /// True when the updater started successfully.
    ///
    /// It cannot start outside an app bundle, so `swift run` builds and the test
    /// suite get a no-op rather than a crash.
    var isAvailable: Bool { updaterController != nil }

    init(policy: UpdatePolicy) {
        guard AppInfo.isBundled else {
            Log.updates.debug("Updater not started: not running from an app bundle")
            return
        }
        guard policy != .never else {
            // Honouring "never" means not starting the updater at all, rather than
            // starting it and telling it not to check. A user who turned updates
            // off should get no update machinery running.
            Log.updates.notice("Updater not started: update policy is 'never'")
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        apply(policy: policy)

        Log.updates.notice("Updater started (policy: \(policy.rawValue, privacy: .public))")
    }

    // MARK: - Policy

    func apply(policy: UpdatePolicy) {
        guard let updater = updaterController?.updater else { return }

        updater.automaticallyChecksForUpdates = policy.checksAutomatically
        updater.automaticallyDownloadsUpdates = policy.downloadsAutomatically

        Log.updates.debug(
            "Update policy: checks=\(policy.checksAutomatically) downloads=\(policy.downloadsAutomatically)"
        )
    }

    // MARK: - Manual check

    /// Runs a user-initiated check.
    ///
    /// Sparkle presents its own windows, and an LSUIElement app cannot bring one
    /// to the front, so the activation policy is raised for the duration. It is
    /// lowered again when the app next has no visible windows — dropping it
    /// immediately would leave Sparkle's dialog behind other applications.
    func checkForUpdates() {
        guard let updaterController else {
            presentUnavailableNotice()
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)

        scheduleActivationPolicyRestore()
    }

    private func scheduleActivationPolicyRestore() {
        // Poll rather than guess a duration: an update check can take seconds and
        // the user may then sit on the "install?" dialog for minutes.
        var elapsed: TimeInterval = 0
        let interval: TimeInterval = 1.0

        func check() {
            elapsed += interval
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }

            if !hasVisibleWindow || elapsed > 600 {
                NSApp.setActivationPolicy(.accessory)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                MainActor.assumeIsolated { check() }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            MainActor.assumeIsolated { check() }
        }
    }

    private func presentUnavailableNotice() {
        let alert = NSAlert()
        alert.messageText = "Updates are not available in this build"
        alert.informativeText = AppInfo.isBundled
            ? "Update checking is turned off in Settings → General."
            : "OpenTab is running from a development build rather than an installed app."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
