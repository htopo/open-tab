import AppKit
import OpenTabCore
import OpenTabUI
import SwiftUI

/// Hosts the onboarding walkthrough in an ordinary window.
///
/// This is the one place OpenTab deliberately behaves like a foreground app: it
/// switches the activation policy to `.regular` so the window can take focus and
/// appear in the Dock while it is up, then switches back to `.accessory` on
/// dismissal. Without that, an LSUIElement app's window opens behind whatever the
/// user was doing and the walkthrough is never seen.
@MainActor
final class OnboardingWindowController {

    private var window: NSWindow?
    private let permissions: PermissionsMonitor
    private let onFinish: () -> Void

    init(permissions: PermissionsMonitor, onFinish: @escaping () -> Void) {
        self.permissions = permissions
        self.onFinish = onFinish
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let window {
            present(window)
            return
        }

        let content = OnboardingView(permissions: permissions) { [weak self] in
            self?.dismiss()
            self?.onFinish()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to OpenTab"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.isMovableByWindowBackground = true

        self.window = window
        present(window)

        Log.permissions.notice("Onboarding shown")
    }

    /// Brings the window to the front of whatever the user is doing.
    ///
    /// Switching activation policy and activating in the same run-loop turn does
    /// not work: AppKit has not finished promoting the process to a regular app
    /// yet, so the activation is dropped and the window opens silently behind
    /// everything. The user sees nothing at all happen, which is exactly how this
    /// was found. Ordering the window front happens immediately so it exists, and
    /// activation is deferred one turn so it actually takes effect.
    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)

        // Regardless of activation state, so the window is at least on screen
        // even if activation is refused.
        window.orderFrontRegardless()

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func dismiss() {
        guard let window else { return }
        window.orderOut(nil)
        self.window = nil

        // Back to a background utility with no Dock presence.
        NSApp.setActivationPolicy(.accessory)
        Log.permissions.notice("Onboarding dismissed")
    }
}
