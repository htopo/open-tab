import AppKit
import OpenTabCore
import SwiftUI

/// The borderless panel the switcher draws in.
///
/// Every property set below is load-bearing, and getting one wrong breaks the
/// core interaction in a way that is hard to diagnose:
///
///  - **`.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`** keep the previously
///    focused application focused while the switcher is up. Without them the panel
///    steals focus, the app you are switching *away from* is no longer frontmost,
///    and the whole premise collapses.
///  - **`.fullScreenAuxiliary`** is what lets the overlay draw over a fullscreen
///    app instead of triggering a Space switch.
///  - **`.canJoinAllSpaces`** stops the panel dragging the user to whichever Space
///    it was created on.
///  - **`.popUpMenu` level** puts it above floating windows and fullscreen content.
///
/// There is one panel, repositioned per the "Show on" setting, rather than one per
/// screen: only one can be visible at a time, and a single panel keeps selection
/// state unambiguous.
@MainActor
final class OverlayPanel {

    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>

    /// Called when the user clicks outside the panel.
    var onClickOutside: (() -> Void)?

    private var clickMonitor: Any?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        // Excluded from the window server's own switcher and from screenshots of
        // "all windows", so OpenTab never appears in its own window list.
        panel.isExcludedFromWindowsMenu = true

        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hostingView
    }

    // MARK: - Content

    func setContent<Content: View>(_ content: Content) {
        hostingView.rootView = AnyView(content)
    }

    /// Applies the theme. The panel never becomes key, so it does not inherit
    /// appearance the way an ordinary window would — it has to be set explicitly.
    func setAppearance(_ appearance: NSAppearance?) {
        panel.appearance = appearance
    }

    // MARK: - Visibility

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel centred on `screen`, sized to its content.
    func show(on screen: NSScreen) {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        position(size: size, on: screen)

        // orderFrontRegardless rather than makeKeyAndOrderFront: the panel must
        // appear without taking key status away from the app underneath.
        panel.orderFrontRegardless()
        startWatchingForOutsideClicks()
    }

    /// Resizes to fit new content while staying centred.
    func resizeToFit(on screen: NSScreen) {
        hostingView.layoutSubtreeIfNeeded()
        position(size: hostingView.fittingSize, on: screen)
    }

    private func position(size: NSSize, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func hide() {
        stopWatchingForOutsideClicks()
        resignKeyIfNeeded()
        panel.orderOut(nil)
    }

    // MARK: - Search mode

    /// Takes key status so a text field can receive input.
    ///
    /// This is the one moment the panel is allowed to become key. It is given up
    /// again as soon as search mode ends, so the rest of the interaction keeps the
    /// underlying app focused.
    func becomeKeyForSearch() {
        guard !panel.isKeyWindow else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resignKeyIfNeeded() {
        guard panel.isKeyWindow else { return }
        panel.resignKey()
    }

    // MARK: - Click-away

    private func startWatchingForOutsideClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // A global monitor only sees clicks that land outside this app, which
            // is exactly the definition of "click away" here.
            MainActor.assumeIsolated { self?.onClickOutside?() }
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    // MARK: - Screen selection

    /// Resolves the "Multiple screens → Show on" setting to an actual screen.
    static func screen(for placement: ScreenPlacement, focusedWindowDisplay: CGDirectDisplayID?) -> NSScreen {
        let screens = NSScreen.screens
        let fallback = NSScreen.main ?? screens.first!

        switch placement {
        case .activeScreen:
            return fallback

        case .screenWithMouse:
            let location = NSEvent.mouseLocation
            return screens.first { $0.frame.contains(location) } ?? fallback

        case .screenWithFocusedWindow:
            guard let target = focusedWindowDisplay else { return fallback }
            return screens.first { screen in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return number.map { CGDirectDisplayID($0.uint32Value) } == target
            } ?? fallback

        case .specificDisplay(let name):
            return screens.first { $0.localizedName == name } ?? fallback
        }
    }
}

/// Where the overlay appears on a multi-display setup.
public enum ScreenPlacement: Equatable, Sendable {
    case activeScreen
    case screenWithMouse
    case screenWithFocusedWindow
    /// A display chosen by name, so the setting survives a reboot even though
    /// display IDs do not.
    case specificDisplay(name: String)
}
