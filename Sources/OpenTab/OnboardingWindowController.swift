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
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
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

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        Log.permissions.notice("Onboarding shown")
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
