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

    /// Called with a selection delta when the user scrolls, if scroll navigation
    /// is enabled. Set before the panel is first shown.
    var onScroll: ((Int) -> Void)?

    private var clickMonitor: Any?
    private var scrollMonitor: Any?
    private var accumulatedScroll: CGFloat = 0

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
    ///
    /// - Parameter fadeDuration: 0 shows it instantly. The switcher is a
    ///   latency-critical surface, so the fade is deliberately short and is
    ///   skipped entirely when motion is reduced.
    func show(on screen: NSScreen, fadeDuration: TimeInterval = 0) {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        position(size: size, on: screen)

        if fadeDuration > 0 {
            panel.alphaValue = 0
            // orderFrontRegardless rather than makeKeyAndOrderFront: the panel
            // must appear without taking key status away from the app underneath.
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

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

    func hide(fadeDuration: TimeInterval = 0) {
        stopWatchingForOutsideClicks()
        resignKeyIfNeeded()

        guard fadeDuration > 0, panel.isVisible else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            // Guard against a new switch having started during the fade — ordering
            // out then would hide a panel the user is actively looking at.
            guard let panel, panel.alphaValue < 0.05 else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
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
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                // A global monitor only sees clicks that land outside this app,
                // which is exactly the definition of "click away" here.
                MainActor.assumeIsolated { self?.onClickOutside?() }
            }
        }

        // Scroll is monitored globally too: the panel never becomes key, so scroll
        // events are delivered to whatever is underneath rather than to us.
        if scrollMonitor == nil, onScroll != nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleScroll(event) }
            }
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        accumulatedScroll = 0
    }

    /// Converts continuous trackpad scrolling into discrete selection steps.
    ///
    /// A trackpad emits a stream of small deltas; forwarding each one would send
    /// the selection flying across the list. Accumulating to a threshold makes one
    /// deliberate two-finger swipe move one entry.
    private func handleScroll(_ event: NSEvent) {
        // Momentum is not input. After a trackpad flick macOS keeps sending
        // scroll events for a second or more as the imaginary surface coasts to a
        // stop, and they arrive here exactly like real ones. Feeding them to the
        // accumulator turned one brush of the trackpad into dozens of steps —
        // the selection visibly sliding away to the far end of the list on its
        // own, with the user's fingers already lifted.
        guard event.momentumPhase == [] else {
            accumulatedScroll = 0
            return
        }

        // Each gesture starts from zero, so leftovers from the previous one
        // cannot combine with a new nudge to produce a step nobody asked for.
        if event.phase == .began {
            accumulatedScroll = 0
        }

        // Horizontal dominant means the user is moving along the row; vertical is
        // handled the same way so a grid works either direction.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY

        accumulatedScroll += delta

        // One step per event at most. A fast swipe can carry fifty points in a
        // single event, and draining that in a loop moves several entries from
        // one gesture — the same runaway in miniature.
        let threshold: CGFloat = 30
        guard abs(accumulatedScroll) >= threshold else { return }

        let step = accumulatedScroll > 0 ? -1 : 1
        accumulatedScroll = 0
        onScroll?(step)
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
