import AppKit
import OpenTabCore

// Top-level code in main.swift already runs on the main thread, but the compiler
// does not infer main-actor isolation for it, so the AppKit setup is wrapped
// explicitly rather than scattering isolation annotations through the delegate.

// Held for the lifetime of the process: NSApplication.delegate is a weak
// reference, so something else has to own the delegate.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared

    // OpenTab is an LSUIElement app: no Dock icon and no menu bar of its own.
    // Set before the delegate runs so nothing flashes a Dock tile during launch.
    // Onboarding temporarily switches to .regular so its window can take focus.
    application.setActivationPolicy(.accessory)
    application.delegate = appDelegate

    Log.app.notice("OpenTab \(AppInfo.versionDescription, privacy: .public) starting")

    application.run()
}
