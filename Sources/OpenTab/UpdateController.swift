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

    /// Whether this build carries the EdDSA public key Sparkle verifies with.
    ///
    /// Without it Sparkle cannot check any signature, so it puts up a modal alert
    /// during startup. In an LSUIElement app that alert never comes to the front —
    /// it is invisible, and it blocks the main dispatch queue, which wedges the
    /// whole app: no onboarding window, and signal handlers never fire because
    /// their dispatch sources sit behind the modal run loop.
    ///
    /// So an unconfigured Sparkle is treated as "no updater" rather than started
    /// and left to complain. Development builds have no key; the release process
    /// adds one.
    static var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").isEmpty
    }

    init(policy: UpdatePolicy) {
        guard AppInfo.isBundled else {
            Log.updates.debug("Updater not started: not running from an app bundle")
            return
        }
        guard Self.isConfigured else {
            Log.updates.notice("Updater not started: this build has no SUPublicEDKey")
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
        alert.informativeText = {
            if !AppInfo.isBundled {
                return "OpenTab is running from a development build rather than an installed app."
            }
            if !Self.isConfigured {
                return "This build was not published through the release process, so it cannot verify updates."
            }
            return "Update checking is turned off in Settings → General."
        }()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
