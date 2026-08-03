import AppKit
import OpenTabCore

/// Draws a highlight around the selected window on screen, behind the overlay.
///
/// This is the "Preview selected window" setting. It matters most in the cases
/// thumbnails are worst at — several similar windows of one app, or a window
/// mostly hidden behind others — where seeing the real thing light up is the only
/// unambiguous confirmation of what will be focused.
///
/// A borderless click-through window rather than any kind of drawing into the
/// target: OpenTab has no business modifying another application's window.
@MainActor
final class WindowPreviewHighlighter {

    private var highlightWindow: NSWindow?

    /// Cocoa's screen coordinates are bottom-left origin; accessibility frames are
    /// top-left. Conversion needs the primary screen's height.
    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    // MARK: - Showing

    func show(for window: WindowModel) {
        // Nothing is composited for these, so there is no rectangle on screen worth
        // pointing at.
        guard !window.isMinimized, !window.isHidden, !window.isApplicationEntry,
              window.frame != .zero
        else {
            hide()
            return
        }

        let panel = highlightWindow ?? makeWindow()
        highlightWindow = panel

        panel.setFrame(cocoaFrame(from: window.frame), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        highlightWindow?.orderOut(nil)
    }

    func tearDown() {
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Below the switcher overlay but above ordinary windows, so it reads as
        // sitting on top of the target without ever covering the switcher itself.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true

        // Click-through: this is decoration, and swallowing a click meant for the
        // window underneath would be worse than not drawing at all.
        panel.ignoresMouseEvents = true

        panel.contentView = HighlightView()
        return panel
    }

    private func cocoaFrame(from axFrame: CGRect) -> NSRect {
        NSRect(
            x: axFrame.origin.x,
            y: primaryScreenHeight - axFrame.origin.y - axFrame.height,
            width: axFrame.width,
            height: axFrame.height
        )
    }
}

/// The highlight itself: an accent border with a faint wash inside.
private final class HighlightView: NSView {

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)

        // Faint enough to identify the window without obscuring its contents —
        // the point is to confirm which window, not to look at the wash.
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        path.fill()

        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = inset * 2
        path.stroke()
    }
}
