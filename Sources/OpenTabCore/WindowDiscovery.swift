import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenTabAX

/// Full enumeration of every switchable window on the system.
///
/// The Accessibility API is the primary source because it is the only route that
/// sees minimized windows, windows on other Spaces, and windows of hidden apps —
/// which are exactly the ones the built-in switcher cannot reach and the main
/// reason this app exists. `CGWindowListCopyWindowInfo` is used as a
/// cross-reference for geometry, window layer, and display assignment.
///
/// This is expensive: it makes a synchronous IPC round trip per application.
/// It runs once at launch and thereafter only as a background reconciliation
/// pass. Never call it on the hotkey path.
public enum WindowDiscovery {

    /// A window layer other than 0 means the window is chrome — a menu, the Dock,
    /// a system overlay, a notification. Those are never switch targets.
    static let normalWindowLayer = 0

    /// Windows smaller than this in either dimension are almost always utility
    /// shims rather than something a user would switch to.
    static let minimumWindowSize: CGFloat = 40

    // MARK: - Entry point

    public struct Result {
        public var windows: [WindowModel]
        public var apps: [pid_t: AppModel]

        public init(windows: [WindowModel] = [], apps: [pid_t: AppModel] = [:]) {
            self.windows = windows
            self.apps = apps
        }
    }

    /// Enumerates everything. Safe to call from a background queue, and should be.
    ///
    /// - Parameter previousFocusTimes: MRU timestamps carried over from the
    ///   existing registry, so a reconciliation pass does not reset the ordering.
    public static func enumerateAll(
        previousFocusTimes: [WindowID: Date] = [:],
        messagingTimeout: Float = 1.0
    ) -> Result {
        let cgInfo = captureWindowInfo()
        let screens = ScreenGeometry.current()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var windows: [WindowModel] = []
        var apps: [pid_t: AppModel] = [:]

        for runningApp in candidateApplications() {
            let pid = runningApp.processIdentifier

            let appModel = AppModel(
                id: pid,
                bundleID: runningApp.bundleIdentifier ?? "",
                name: runningApp.localizedName ?? "",
                icon: runningApp.icon,
                isHidden: runningApp.isHidden,
                isActive: pid == frontmostPID,
                launchedAt: runningApp.launchDate ?? .distantPast
            )
            apps[pid] = appModel

            let appElement = AXUIElementCreateApplication(pid)
            AX.setMessagingTimeout(appElement, seconds: messagingTimeout)

            let windowElements = AX.elements(appElement, AXAttribute.windows)

            let isRegular = runningApp.activationPolicy == .regular

            let focusedElement = AX.element(appElement, AXAttribute.focusedWindow)
            let focusedWindowID = focusedElement.flatMap { AX.windowID(of: $0) }

            var modelled = 0
            for element in windowElements {
                guard let model = makeWindowModel(
                    element: element,
                    app: appModel,
                    cgInfo: cgInfo,
                    screens: screens,
                    focusedWindowID: focusedWindowID,
                    previousFocusTimes: previousFocusTimes
                ) else { continue }
                windows.append(model)
                modelled += 1
            }

            guard modelled == 0, isRegular else { continue }

            // Accessibility produced nothing usable for this app — it either
            // published no windows at all, or published only things that are not
            // switch targets. Ask the window server before concluding the app has
            // no windows: it sees every Space and does not need the app's
            // cooperation.
            let recovered = synthesizeMissingWindows(
                for: appModel,
                alreadyModelled: [],
                cgInfo: cgInfo,
                screens: screens,
                previousFocusTimes: previousFocusTimes
            )

            guard !recovered.isEmpty else {
                // Genuinely window-less. This is the entry the "apps with no open
                // window" filter is about.
                windows.append(makeApplicationEntry(app: appModel, element: appElement))
                continue
            }

            Log.registry.notice(
                """
                \(appModel.name, privacy: .public): \(windowElements.count) window(s) offered by \
                Accessibility, none usable; recovered \(recovered.count) from the window server
                """
            )
            windows.append(contentsOf: recovered)
        }

        return Result(windows: windows, apps: apps)
    }

    // MARK: - Applications

    /// Applications worth asking for windows.
    ///
    /// `.regular` apps are the obvious case. `.accessory` apps are included
    /// because some genuinely useful windows live there — menu-bar utilities with
    /// a real settings or main window — and they are cheap to skip when they
    /// report nothing. `.prohibited` processes never have user-facing windows.
    static func candidateApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated else { return false }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            switch app.activationPolicy {
            case .regular, .accessory: return true
            case .prohibited:          return false
            @unknown default:          return false
            }
        }
    }

    // MARK: - Window construction

    static func makeWindowModel(
        element: AXUIElement,
        app: AppModel,
        cgInfo: [CGWindowID: CGWindowRecord],
        screens: ScreenGeometry,
        focusedWindowID: CGWindowID?,
        previousFocusTimes: [WindowID: Date]
    ) -> WindowModel? {
        // Role and subrole filtering. Sheets, popovers, tooltips, and the
        // AXUnknown grab-bag are not switch targets.
        guard AX.string(element, AXAttribute.role) == AXRole.window else { return nil }

        let subrole = AX.string(element, AXAttribute.subrole)
        switch subrole {
        case AXSubrole.standardWindow, AXSubrole.dialog:
            break
        case .none:
            // Some apps do not report a subrole at all. Accept those; the size and
            // layer checks below still filter out the junk.
            break
        default:
            return nil
        }

        guard let cgWindowID = AX.windowID(of: element) else {
            // Without a CGWindowID the window cannot be joined to capture or Space
            // data. Falling back to heuristic matching is possible but lossy; for
            // now such windows are skipped rather than shown with wrong metadata.
            return nil
        }

        let record = cgInfo[cgWindowID]

        // Drop window-server chrome. A minimized window has no CG record at all,
        // which is expected and must not exclude it.
        if let record, record.layer != normalWindowLayer { return nil }

        let isMinimized = AX.bool(element, AXAttribute.minimized) ?? false

        // Geometry: prefer the accessibility frame, fall back to the CG record.
        // A minimized window's AX frame is stale but is the best available.
        let frame = AX.frame(element) ?? record?.bounds ?? .zero

        if !isMinimized,
           frame != .zero,
           frame.width < minimumWindowSize || frame.height < minimumWindowSize {
            return nil
        }

        let id = WindowID(cgWindowID: cgWindowID, pid: app.id)
        let isFocused = focusedWindowID == cgWindowID && app.isActive

        return WindowModel(
            id: id,
            kind: .window,
            axElement: element,
            title: AX.string(element, AXAttribute.title) ?? "",
            appBundleID: app.bundleID,
            appName: app.name,
            appIcon: app.icon,
            isMinimized: isMinimized,
            isHidden: app.isHidden,
            isFullscreen: AX.bool(element, AXAttribute.fullScreen) ?? false,
            spaceID: PrivateSymbols.workspace(for: cgWindowID),
            displayID: screens.displayContaining(frame),
            frame: frame,
            lastFocusedAt: previousFocusTimes[id] ?? (isFocused ? Date() : .distantPast),
            isFocused: isFocused
        )
    }

    /// Windows the window server knows about that Accessibility never offered.
    ///
    /// Some applications simply do not publish their windows over the
    /// accessibility API — Catalyst apps are the usual culprits, and a chat app
    /// parked on another Desktop was the report that led here. It appeared in the
    /// switcher as "an application with no open window", which was wrong twice
    /// over: it had a window, and that window was on a Desktop the entry gave no
    /// hint about.
    ///
    /// The window server is not so reticent. `.optionAll` covers every Space and
    /// needs no cooperation from the application, so its records can stand in.
    ///
    /// Used **only** when Accessibility published nothing at all for the app, and
    /// only for `.regular` applications. Both limits are load-bearing. The window
    /// server's list is not a list of switchable windows: it also holds offscreen
    /// scratch windows, tab previews, panels and system furniture. Filling in the
    /// gaps for an app that published *some* windows took a browser from three
    /// entries to ten, most of them things the user has never seen. An app that
    /// published none is the unambiguous case — there is nothing to contradict,
    /// and the alternative is the app being absent or, worse, listed as having no
    /// windows when it plainly has one.
    ///
    /// These models carry no `AXUIElement`, so they cannot be raised window by
    /// window; `WindowActions.focus` brings the application forward instead,
    /// which is the same thing the old placeholder entry did, only now under the
    /// right name and on the right Desktop.
    static func synthesizeMissingWindows(
        for app: AppModel,
        alreadyModelled: Set<CGWindowID>,
        cgInfo: [CGWindowID: CGWindowRecord],
        screens: ScreenGeometry,
        previousFocusTimes: [WindowID: Date]
    ) -> [WindowModel] {
        cgInfo.values
            .filter { record in
                record.pid == app.id
                    && !alreadyModelled.contains(record.windowID)
                    && record.layer == normalWindowLayer
                    && record.bounds.width >= minimumWindowSize
                    && record.bounds.height >= minimumWindowSize
            }
            .sorted { $0.windowID < $1.windowID }
            .map { record in
                let id = WindowID(cgWindowID: record.windowID, pid: app.id)
                return WindowModel(
                    id: id,
                    kind: .window,
                    axElement: nil,
                    title: record.title ?? "",
                    appBundleID: app.bundleID,
                    appName: app.name,
                    appIcon: app.icon,
                    isMinimized: false,
                    isHidden: app.isHidden,
                    isFullscreen: false,
                    spaceID: PrivateSymbols.workspace(for: record.windowID),
                    displayID: screens.displayContaining(record.bounds),
                    frame: record.bounds,
                    lastFocusedAt: previousFocusTimes[id] ?? .distantPast,
                    isFocused: false
                )
            }
    }

    /// Whether the window server believes this process owns an ordinary window.
    ///
    /// A second opinion, asked before declaring an application window-less.
    /// Accessibility answers an empty window list for more reasons than "there
    /// are no windows": a messaging timeout, an app busy enough not to reply, or
    /// an app that simply does not enumerate windows sitting on another Desktop.
    /// All three are indistinguishable from the real thing, and the result was an
    /// app with a perfectly good window on Desktop 2 appearing in the list as
    /// having none.
    ///
    /// CoreGraphics is asked with `.optionAll`, so it sees every Space, and it
    /// does not depend on the application cooperating. Minimized windows have no
    /// record at all — that is fine here, because Accessibility does report those,
    /// so this path is never reached for them.
    static func ownsWindows(pid: pid_t, in cgInfo: [CGWindowID: CGWindowRecord]) -> Bool {
        cgInfo.values.contains { record in
            record.pid == pid
                && record.layer == normalWindowLayer
                && record.bounds.width >= minimumWindowSize
                && record.bounds.height >= minimumWindowSize
        }
    }

    static func makeApplicationEntry(app: AppModel, element: AXUIElement) -> WindowModel {
        WindowModel(
            id: .application(pid: app.id),
            kind: .applicationWithNoWindows,
            axElement: element,
            title: "",
            appBundleID: app.bundleID,
            appName: app.name,
            appIcon: app.icon,
            isHidden: app.isHidden,
            lastFocusedAt: .distantPast
        )
    }

    // MARK: - CoreGraphics cross-reference

    /// The subset of a `CGWindowListCopyWindowInfo` entry that matters here.
    public struct CGWindowRecord {
        public let windowID: CGWindowID
        public let pid: pid_t
        public let layer: Int
        public let bounds: CGRect
        public let isOnScreen: Bool
        public let title: String?
    }

    /// Snapshots the window server's view, keyed by window ID.
    ///
    /// `.optionAll` includes off-screen windows. This does not see other Spaces —
    /// that is what the AX pass and `CGSCopyWindowsWithOptionsAndTags` are for.
    static func captureWindowInfo() -> [CGWindowID: CGWindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        var result: [CGWindowID: CGWindowRecord] = [:]
        result.reserveCapacity(raw.count)

        for entry in raw {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber
            else { continue }

            let windowID = CGWindowID(number.uint32Value)
            let boundsDict = entry[kCGWindowBounds as String] as? [String: Any]
            let bounds = boundsDict
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero

            result[windowID] = CGWindowRecord(
                windowID: windowID,
                pid: pid_t(ownerPID.int32Value),
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                title: entry[kCGWindowName as String] as? String
            )
        }
        return result
    }
}

// MARK: - Screens

/// Maps window frames to displays.
///
/// Snapshotted rather than queried per window: `NSScreen.screens` is not cheap,
/// and a display reconfiguration mid-enumeration would otherwise produce a list
/// where different windows were resolved against different layouts.
public struct ScreenGeometry {
    public struct Entry {
        public let displayID: CGDirectDisplayID
        /// In Cocoa coordinates, origin bottom-left.
        public let frame: CGRect
    }

    public let entries: [Entry]
    /// Total height of the primary screen, used to flip between Cocoa's
    /// bottom-left origin and Core Graphics' top-left origin.
    public let primaryHeight: CGFloat

    public static func current() -> ScreenGeometry {
        let screens = NSScreen.screens
        let entries: [Entry] = screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return Entry(displayID: CGDirectDisplayID(number.uint32Value), frame: screen.frame)
        }
        return ScreenGeometry(
            entries: entries,
            primaryHeight: screens.first?.frame.height ?? 0
        )
    }

    public init(entries: [Entry], primaryHeight: CGFloat) {
        self.entries = entries
        self.primaryHeight = primaryHeight
    }

    /// The display holding most of `frame`.
    ///
    /// Uses greatest overlap rather than the origin, so a window straddling two
    /// displays is attributed to the one showing more of it — which is the one the
    /// user would say it is "on".
    public func displayContaining(_ frame: CGRect) -> CGDirectDisplayID? {
        guard !entries.isEmpty else { return nil }
        guard frame != .zero else { return entries.first?.displayID }

        // Accessibility reports top-left origin; NSScreen uses bottom-left.
        let flipped = CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )

        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for entry in entries {
            let intersection = entry.frame.intersection(flipped)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (entry.displayID, area)
            }
        }
        return best?.id ?? entries.first?.displayID
    }
}
