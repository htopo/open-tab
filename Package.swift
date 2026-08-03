// swift-tools-version:5.9
//
// OpenTab — a window switcher for macOS.
//
// Tools version is pinned to 5.9 (rather than 6.x) so the package builds on the
// stock toolchain of every supported CI image and on Command Line Tools installs
// without Xcode. The app is built with `swift build` and assembled into a bundle
// by Scripts/bundle.sh; there is deliberately no .xcodeproj.

import PackageDescription

let package = Package(
    name: "OpenTab",
    // Base language for the localized strings in OpenTabUI/Resources. Adding a
    // language means adding a <code>.lproj directory beside en.lproj.
    defaultLocalization: "en",
    platforms: [
        // 14.0 is driven by SCScreenshotManager.captureImage(contentFilter:configuration:),
        // the only non-deprecated way to grab a single window image. See PLAN §2.1.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OpenTab", targets: ["OpenTab"]),
        .library(name: "OpenTabCore", targets: ["OpenTabCore"]),
    ],
    targets: [
        // Typed wrappers over AXUIElement, AX observers, and dlsym-resolved access to
        // the undocumented CoreGraphics symbols. No app logic lives here.
        .target(name: "OpenTabAX"),

        // Window/app models, registry, ordering, filtering, exceptions, settings.
        // Pure logic — no running UI and no TCC permissions required, so it is the
        // part of the app that unit tests can cover.
        .target(name: "OpenTabCore", dependencies: ["OpenTabAX"]),

        // ScreenCaptureKit thumbnail capture, cache, invalidation, background refresh.
        .target(name: "OpenTabShot", dependencies: ["OpenTabCore"]),

        // CGEventTap management, the hotkey state machine, symbolic-hotkey takeover
        // and restore, and the trackpad gesture trigger.
        .target(name: "OpenTabInput", dependencies: ["OpenTabCore", "OpenTabAX"]),

        // SwiftUI view content: overlay, settings panes, onboarding.
        // Owns the localized strings, so adding a language is a resource change.
        .target(
            name: "OpenTabUI",
            dependencies: ["OpenTabCore", "OpenTabShot"],
            resources: [.process("Resources")]
        ),

        // AppDelegate, menu-bar item, NSPanel overlay host, wiring, lifecycle.
        .executableTarget(
            name: "OpenTab",
            dependencies: ["OpenTabCore", "OpenTabAX", "OpenTabShot", "OpenTabInput", "OpenTabUI"]
        ),

        .testTarget(
            name: "OpenTabCoreTests",
            dependencies: ["OpenTabCore", "OpenTabAX", "OpenTabInput", "OpenTabShot"]
        ),
    ]
)
