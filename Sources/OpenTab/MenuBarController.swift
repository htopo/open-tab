import AppKit
import OpenTabCore

/// The optional menu-bar status item and its menu.
///
/// The item is the only always-available entry point to the app: OpenTab has no
/// Dock icon, so with it hidden the app is reachable only by launching it again,
/// which opens Settings. The General pane says so when the user turns it off.
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private let onOpenSettings: () -> Void
    private let onLogWindowList: () -> Void
    private let onQuit: () -> Void
    private var variant: MenuBarIconVariant
    private var actions: Actions?

    init(variant: MenuBarIconVariant = .windows,
         onOpenSettings: @escaping () -> Void,
         onLogWindowList: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.variant = variant
        self.onOpenSettings = onOpenSettings
        self.onLogWindowList = onLogWindowList
        self.onQuit = onQuit
    }

    // MARK: - Visibility

    func show() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = icon(for: variant)
        item.button?.toolTip = "OpenTab \(AppInfo.version)"
        item.menu = buildMenu()
        statusItem = item

        Log.app.debug("Menu bar item installed")
    }

    func hide() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        Log.app.debug("Menu bar item removed")
    }

    func setVariant(_ variant: MenuBarIconVariant) {
        guard variant != self.variant else { return }
        self.variant = variant
        statusItem?.button?.image = icon(for: variant)
    }

    private func icon(for variant: MenuBarIconVariant) -> NSImage? {
        let image = NSImage(systemSymbolName: variant.symbolName,
                            accessibilityDescription: "OpenTab")
        // Template rendering is what makes the icon adapt to a light or dark menu
        // bar, and to the user's menu bar tint.
        image?.isTemplate = true
        return image
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "OpenTab \(AppInfo.version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item(title: "Settings…", key: ",", action: #selector(Actions.openSettings)))

        // Diagnostics. Exposed in the normal menu because "what does OpenTab
        // actually think is open?" is the first question worth answering in any
        // bug report, and asking a user to run a debug build to find out is a
        // non-starter.
        menu.addItem(item(title: "Log Window List", key: "", action: #selector(Actions.logWindowList)))

        menu.addItem(.separator())
        menu.addItem(item(title: "Quit OpenTab", key: "q", action: #selector(Actions.quit)))

        // Menu items need a target that responds to the selectors. A dedicated
        // responder object keeps AppKit selector plumbing out of this class's API.
        let actions = Actions(onOpenSettings: onOpenSettings,
                              onLogWindowList: onLogWindowList,
                              onQuit: onQuit)
        self.actions = actions
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = actions
        }
        return menu
    }

    private func item(title: String, key: String, action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    /// Selector target for the status menu.
    private final class Actions: NSObject {
        private let onOpenSettings: () -> Void
        private let onLogWindowList: () -> Void
        private let onQuit: () -> Void

        init(onOpenSettings: @escaping () -> Void,
             onLogWindowList: @escaping () -> Void,
             onQuit: @escaping () -> Void) {
            self.onOpenSettings = onOpenSettings
            self.onLogWindowList = onLogWindowList
            self.onQuit = onQuit
        }

        @objc func openSettings() { onOpenSettings() }
        @objc func logWindowList() { onLogWindowList() }
        @objc func quit() { onQuit() }
    }
}
