import AppKit
import OpenTabCore
import OpenTabUI
import SwiftUI
import UniformTypeIdentifiers

/// Hosts the settings window.
///
/// Like onboarding, this temporarily switches the activation policy to `.regular`
/// so the window can take focus and appear in the Dock. An LSUIElement app's
/// window otherwise opens behind whatever the user was doing.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let store: SettingsStore
    private let environmentProvider: () -> SettingsEnvironment

    init(store: SettingsStore, environmentProvider: @escaping () -> SettingsEnvironment) {
        self.store = store
        self.environmentProvider = environmentProvider
    }

    func show() {
        if let window {
            activate(window)
            return
        }

        let content = SettingsWindowView(store: store, environment: environmentProvider())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenTab Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setFrameAutosaveName("OpenTabSettingsWindow")
        window.delegate = self
        window.center()

        self.window = window
        activate(window)
    }

    /// Same activation-policy race as onboarding: promoting the process to a
    /// regular app and activating in one run-loop turn silently drops the
    /// activation, and the window opens behind everything.
    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.orderFrontRegardless()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Back to being a background utility. Deferred so AppKit finishes closing
        // before the policy change, which otherwise leaves a stray Dock tile.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = NSApp.setActivationPolicy(.accessory)
            }
        }
        // Written now rather than on the debounce, so closing the window and
        // quitting immediately cannot lose the last change.
        store.flush()
    }

    // MARK: - Import / export panels

    /// Presents a save panel and writes the settings document.
    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export OpenTab Settings"
        panel.nameFieldStringValue = "OpenTab-Settings.json"
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(to: url)
        } catch {
            presentError("Could not export settings", error)
        }
    }

    /// Presents an open panel and replaces the current settings.
    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import OpenTab Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importSettings(from: url)
        } catch {
            presentError("Could not import settings", error)
        }
    }

    private func presentError(_ message: String, _ error: Error) {
        Log.settings.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")

        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
