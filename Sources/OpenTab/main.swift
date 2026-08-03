import AppKit
import OpenTabCore

// OpenTab is an LSUIElement app: no Dock icon, no application menu bar of its own.
// The activation policy is set before the delegate runs so that nothing flashes a
// Dock tile during launch.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// Held for the lifetime of the process — top-level bindings in main.swift are
// globals, so this is not deallocated out from under NSApplication.
let appDelegate = AppDelegate()
application.delegate = appDelegate

Log.app.notice("OpenTab \(AppInfo.versionDescription, privacy: .public) starting")

application.run()
