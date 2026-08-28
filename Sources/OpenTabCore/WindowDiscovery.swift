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
        knownTitles: [WindowID: String] = [:],
        messagingTimeout: Float = 1.0
    ) -> Result {
        let cgInfo = captureWindowInfo()
        let screens = ScreenGeometry.current()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var windows: [WindowModel] = []
        var apps: [pid_t: AppModel] = [:]

        // Per-application tally of what Accessibility offered against what
        // survived. "Offered" and "kept" answer different questions and the
        // switcher shows neither: an app missing windows because it never
        // published them looks exactly like one whose windows were filtered out.
        var tally: [String] = []

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

            var modelledIDs: Set<CGWindowID> = []
            var publishedArea: CGFloat = 0
            var rejections: [String] = []
            for element in windowElements {
                let candidate = examineWindow(
                    element: element,
                    app: appModel,
                    cgInfo: cgInfo,
                    screens: screens,
                    focusedWindowID: focusedWindowID,
                    previousFocusTimes: previousFocusTimes
                )
                guard let model = candidate.model else {
                    if let reason = candidate.rejection { rejections.append(reason) }
                    continue
                }
                windows.append(model)
                modelledIDs.insert(model.id.cgWindowID)
                publishedArea = max(publishedArea, model.frame.width * model.frame.height)
            }

            if !windowElements.isEmpty {
                let refused = rejections.isEmpty ? "" : " [\(rejections.joined(separator: " "))]"
                tally.append("\(appModel.name) \(modelledIDs.count)/\(windowElements.count)\(refused)")
            }

            guard isRegular else { continue }

            // Ask the window server what Accessibility left out. It is not only
            // apps that publish *nothing* that need this: a browser publishes the
            // window on the Desktop you are standing on and stays silent about the
            // ones parked elsewhere, so asking only when the list came back empty
            // left two windows out of three invisible.
            let recovered = synthesizeMissingWindows(
                for: appModel,
                appElement: appElement,
                alreadyModelled: modelledIDs,
                publishedArea: publishedArea,
                cgInfo: cgInfo,
                screens: screens,
                previousFocusTimes: previousFocusTimes,
                knownTitles: knownTitles
            )

            guard !recovered.isEmpty else {
                // Genuinely window-less. This is the entry the "apps with no open
                // window" filter is about.
                if modelledIDs.isEmpty {
                    windows.append(makeApplicationEntry(app: appModel, element: appElement))
                }
                continue
            }

            Log.registry.notice(
                """
                \(appModel.name, privacy: .public): Accessibility offered \
                \(windowElements.count), kept \(modelledIDs.count); \
                recovered \(recovered.count) more from the window server
                """
            )
            windows.append(contentsOf: recovered)
        }

        Log.registry.notice(
            "Accessibility kept/offered: \(tally.joined(separator: ", "), privacy: .public)"
        )

        let untitled = windows
            .filter { $0.title.isEmpty && !$0.isApplicationEntry }
            .map { "\($0.appName)/space=\($0.spaceID.map(String.init) ?? "?")/ax=\($0.axElement != nil)" }
        if !untitled.isEmpty {
            Log.registry.notice("Untitled windows: \(untitled.joined(separator: ", "), privacy: .public)")
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
        examineWindow(
            element: element, app: app, cgInfo: cgInfo, screens: screens,
            focusedWindowID: focusedWindowID, previousFocusTimes: previousFocusTimes
        ).model
    }

    /// The same construction, plus why it was refused when it was.
    ///
    /// A window Accessibility offered and this code turned down is the hardest
    /// kind of absence to investigate: the application published it, so the
    /// application is not at fault, and the switcher simply does not show it.
    /// Naming the rule that rejected it turns that into a one-line answer.
    static func examineWindow(
        element: AXUIElement,
        app: AppModel,
        cgInfo: [CGWindowID: CGWindowRecord],
        screens: ScreenGeometry,
        focusedWindowID: CGWindowID?,
        previousFocusTimes: [WindowID: Date]
    ) -> (model: WindowModel?, rejection: String?) {
        // Role and subrole filtering. Sheets, popovers, tooltips, and the
        // AXUnknown grab-bag are not switch targets.
        guard AX.string(element, AXAttribute.role) == AXRole.window else {
            return (nil, "role")
        }

        let subrole = AX.string(element, AXAttribute.subrole)
        switch subrole {
        case AXSubrole.standardWindow, AXSubrole.dialog:
            break
        case .none:
            // Some apps do not report a subrole at all. Accept those; the size and
            // layer checks below still filter out the junk.
            break
        default:
            return (nil, "subrole=\(subrole ?? "?")")
        }

        guard let cgWindowID = AX.windowID(of: element) else {
            // Without a CGWindowID the window cannot be joined to capture or Space
            // data. Falling back to heuristic matching is possible but lossy; for
            // now such windows are skipped rather than shown with wrong metadata.
            return (nil, "no-window-id")
        }

        let record = cgInfo[cgWindowID]
        let isMinimized = AX.bool(element, AXAttribute.minimized) ?? false

        // Drop window-server chrome: menu-bar panels, the Dock, launcher overlays.
        if let record, record.layer != normalWindowLayer {
            return (nil, "layer=\(record.layer)")
        }

        // No record at all is a stronger signal than it looks. The window list is
        // taken with `.optionAll`, which spans every Space and includes offscreen
        // windows, so a window the server has never heard of is not a window the
        // user can switch to — it is something an application has built out of
        // accessibility objects without ever putting it on screen.
        //
        // Two exceptions, both real: a minimized window has no record while it
        // sits in the Dock, and a hidden application's windows drop out of the
        // list too. Both are things the switcher exists to reach.
        //
        // Without this check, background agents that publish accessibility
        // windows they never show — the Dock, Control Center, launcher bars —
        // appeared as ordinary entries.
        if record == nil, !isMinimized, !app.isHidden {
            return (nil, "no-window-server-record")
        }

        // Geometry: prefer the accessibility frame, fall back to the CG record.
        // A minimized window's AX frame is stale but is the best available.
        let frame = AX.frame(element) ?? record?.bounds ?? .zero

        if !isMinimized,
           frame != .zero,
           frame.width < minimumWindowSize || frame.height < minimumWindowSize {
            return (nil, "size=\(Int(frame.width))x\(Int(frame.height))")
        }

        let id = WindowID(cgWindowID: cgWindowID, pid: app.id)
        let isFocused = focusedWindowID == cgWindowID && app.isActive

        return (WindowModel(
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
            lastFocusedAt: previousFocusTimes[id]
                ?? (isFocused ? Date() : seededFocusTime(zOrder: record?.zOrder)),
            isFocused: isFocused
        ), nil)
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
        appElement: AXUIElement?,
        alreadyModelled: Set<CGWindowID>,
        publishedArea: CGFloat,
        cgInfo: [CGWindowID: CGWindowRecord],
        screens: ScreenGeometry,
        previousFocusTimes: [WindowID: Date],
        knownTitles: [WindowID: String] = [:]
    ) -> [WindowModel] {
        // An app that publishes no window *list* may still answer for its focused
        // window. Worth asking: it costs one call and, when it works, produces
        // both a real title and an element that can be raised individually rather
        // than only brought forward with the whole application.
        let focusedElement = appElement.flatMap { AX.element($0, AXAttribute.focusedWindow) }
        let focusedID = focusedElement.flatMap { AX.windowID(of: $0) }
        let focusedTitle = focusedElement.flatMap { AX.string($0, AXAttribute.title) }

        let candidates = cgInfo.values.filter { record in
            record.pid == app.id
                && !alreadyModelled.contains(record.windowID)
                && record.layer == normalWindowLayer
                && record.bounds.width >= minimumWindowSize
                && record.bounds.height >= minimumWindowSize
        }

        // Scale the bar to the application's own idea of a window.
        //
        // The window server's list is not a list of switchable windows. A browser
        // keeps more than a dozen ordinary-layer windows per profile — tab-strip
        // shims, drag proxies, extension popups — and they sit on real Desktops
        // and are wider than the size floor, so nothing cheap separates them from
        // a browser window parked on another Desktop. What does separate them is
        // scale: a window someone switches to is roughly the size of the other
        // windows that application already has, and these are a fraction of it.
        //
        // Half the largest is a wide margin rather than a tuned threshold. On the
        // machine this was measured against it admits three browser windows of
        // 1920×1050 and 1512×949 and rejects the next largest impostor at
        // 1421×218 — a factor of four clear — and changes nothing for any other
        // application, each of which had one or two windows that all passed.
        let minimumArea = recoveryAreaFloor(
            publishedArea: publishedArea,
            candidateAreas: candidates.map { $0.bounds.width * $0.bounds.height }
        )

        return candidates
            .filter { $0.bounds.width * $0.bounds.height >= minimumArea }
            .sorted { $0.windowID < $1.windowID }
            // A window the user can reach is on a Desktop. Applications keep
            // full-size window objects around that they never show, and those look
            // identical to a window parked on another Desktop except that the
            // window server places the real one somewhere and the phantom nowhere.
            //
            // Last of the filters because it is the only one that costs a round
            // trip to the window server, and by here most candidates are gone.
            //
            // Safe only for reconstructions: minimized windows belong to no
            // Desktop either, but they come from Accessibility with no
            // window-server record at all, so they never reach this.
            .filter { PrivateSymbols.workspace(for: $0.windowID) != nil }
            .map { record in
                let id = WindowID(cgWindowID: record.windowID, pid: app.id)
                let isFocusedOne = focusedID != nil && record.windowID == focusedID

                // Three sources, best first. Accessibility's title is not gated on
                // Screen Recording; the window server's `kCGWindowName` is, so it
                // is usually empty; and failing both, whatever this window was
                // called the last time anyone could see it.
                //
                // That last one carries the common case. An application publishes
                // the window on the Desktop in front and hides the rest, so which
                // windows have titles changes as the user moves between Desktops —
                // and a window that showed its name a moment ago would lose it on
                // the way out. Remembering costs a dictionary entry and the title
                // only goes stale if it changes while out of sight.
                let title = (isFocusedOne ? focusedTitle : nil)
                    ?? record.title
                    ?? knownTitles[id]
                    ?? ""

                return WindowModel(
                    id: id,
                    kind: .window,
                    axElement: isFocusedOne ? focusedElement : nil,
                    title: title,
                    appBundleID: app.bundleID,
                    appName: app.name,
                    appIcon: app.icon,
                    isMinimized: false,
                    isHidden: app.isHidden,
                    isFullscreen: false,
                    // Non-nil by construction: the filter above required it.
                    spaceID: PrivateSymbols.workspace(for: record.windowID),
                    displayID: screens.displayContaining(record.bounds),
                    frame: record.bounds,
                    lastFocusedAt: previousFocusTimes[id] ?? seededFocusTime(zOrder: record.zOrder),
                    isFocused: false
                )
            }
    }

    /// The smallest a reconstructed window may be, for one application.
    ///
    /// Scaled to that application's own idea of a window: half the area of the
    /// largest one it has, whether that came from Accessibility or from the
    /// window server. Deliberately a wide margin rather than a tuned threshold —
    /// it has to separate windows from shims, not rank them.
    ///
    /// Measured against a browser with three real windows and eleven impostors on
    /// real Desktops: largest 1920×1050, floor 1,008,000, the two other real
    /// windows at 1,434,888 each admitted, the largest impostor at 1421×218 —
    /// 309,778 — rejected by a factor of three. Every other application on that
    /// machine had one or two windows, all of which passed.
    static func recoveryAreaFloor(publishedArea: CGFloat, candidateAreas: [CGFloat]) -> CGFloat {
        max(publishedArea, candidateAreas.max() ?? 0) / 2
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
        /// Depth in the window server's list, which is ordered front to back.
        public let zOrder: Int
    }

    /// A stand-in "last focused" time for a window never seen focused.
    ///
    /// Most-recently-used ordering can only know about focus changes observed
    /// since launch. Everything else used to share one timestamp — `distantPast` —
    /// which left their relative order to however the enumeration happened to
    /// visit applications, and meant the first time any of them was touched it
    /// leapt from wherever it was to the front. Watching a second browser window
    /// fall to the bottom of the list and later jump most of the way up, without
    /// ever having been used, is what that looks like.
    ///
    /// The window server lists windows front to back, which is the closest thing
    /// to a used-recently order that exists before we started watching: the window
    /// in front is the one you were last looking at. Seeding from it puts unseen
    /// windows in the order the user already perceives, and keeps them there.
    ///
    /// Dated to 1970 so that any genuine focus, recorded with the current time,
    /// outranks every seed no matter how deep the stack.
    static func seededFocusTime(zOrder: Int?) -> Date {
        Date(timeIntervalSince1970: -Double(zOrder ?? 1_000_000))
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

        for (depth, entry) in raw.enumerated() {
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
                title: entry[kCGWindowName as String] as? String,
                zOrder: depth
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
