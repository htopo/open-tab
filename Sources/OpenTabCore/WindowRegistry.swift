import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenTabAX

/// The live set of switchable windows.
///
/// The performance requirement drives the whole design: the overlay must be on
/// screen in well under 100 ms, and a full accessibility enumeration takes far
/// longer than that with a normal number of applications open. So the registry is
/// built once at launch and then kept current from notifications, and opening the
/// switcher is a plain read of already-correct state.
///
/// A cheap reconciliation pass runs in the background when the switcher opens, to
/// catch anything the notifications missed. It never blocks the overlay; if it
/// finds drift, the list updates underneath the user a moment later.
@MainActor
public final class WindowRegistry {

    // MARK: - State

    public private(set) var windows: [WindowModel] = []
    public private(set) var apps: [pid_t: AppModel] = [:]

    /// Fires after any change to `windows` or `apps`.
    public var onChange: (() -> Void)?

    /// True once the initial enumeration has completed.
    public private(set) var isPopulated = false

    /// Most-recently-used timestamps, kept separately from the models so that a
    /// full re-enumeration does not reset the ordering the user relies on.
    private var focusTimes: [WindowID: Date] = [:]

    /// Which window is focused, and when that was established.
    ///
    /// Held here rather than read back from `windows` because enumeration runs in
    /// the background and answers the question as it was when the pass *started*.
    /// A pass kicked off by opening the switcher lands a few hundred milliseconds
    /// later — reliably after the user has already committed a switch — and used
    /// to overwrite the new focus with the old one. See `applyFullResult`.
    private var focusedWindowID: WindowID?
    private var focusObservedAt: Date = .distantPast

    private var observers: [pid_t: AXAppObserver] = [:]
    private var workspaceObservers: [any NSObjectProtocol] = []

    /// Enumeration runs here. Serial, so two passes cannot interleave and produce
    /// a merged list containing windows from two different moments.
    private let discoveryQueue = DispatchQueue(
        label: "io.github.htopo.opentab.discovery",
        qos: .userInitiated
    )

    /// Per-application refresh debouncing. Applications emit bursts of
    /// notifications — opening a document fires created, title-changed, moved, and
    /// resized in a few milliseconds — and refreshing once per burst instead of
    /// once per notification is the difference between idle and busy.
    private var pendingRefreshes: Set<pid_t> = []
    private var refreshWorkItem: DispatchWorkItem?
    private static let refreshDebounce: TimeInterval = 0.05

    private var isReconciling = false
    private var messagingTimeout: Float

    public init(messagingTimeout: Float = 1.0) {
        self.messagingTimeout = messagingTimeout
    }

    // No deinit teardown. Swift runs `deinit` outside the actor, so reaching
    // main-actor state from there means `assumeIsolated`, which traps outright if
    // the last release happens on a background thread — and a `Task` holding the
    // registry can do exactly that. `stop()` is the teardown; the app delegate
    // calls it during shutdown, and leaving an observer attached is a far milder
    // failure than a crash on exit.

    // MARK: - Lifecycle

    /// Builds the registry and starts tracking changes.
    ///
    /// Requires Accessibility. Calling it without the grant produces an empty
    /// registry rather than an error, because the caller already gates on it.
    public func start() {
        guard !isPopulated else { return }

        subscribeToWorkspace()
        for app in WindowDiscovery.candidateApplications() {
            attachObserver(to: app.processIdentifier)
        }

        rebuildAll()
    }

    public func stop() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        pendingRefreshes.removeAll()

        for observer in observers.values { observer.invalidate() }
        observers.removeAll()

        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()

        windows.removeAll()
        apps.removeAll()
        isPopulated = false
    }

    // MARK: - Snapshot

    /// The current list plus the context needed to filter it.
    ///
    /// Cheap by construction — everything is already resident. This is what runs
    /// on the hotkey path.
    public func snapshot() -> Snapshot {
        Snapshot(windows: windows, apps: apps, context: currentContext())
    }

    public struct Snapshot {
        public let windows: [WindowModel]
        public let apps: [pid_t: AppModel]
        public let context: FilterContext
    }

    /// Resolves "where am I right now" for the scope filters.
    ///
    /// The active Space is derived from the focused window rather than queried
    /// directly, so it works from the same symbol set as everything else.
    func currentContext() -> FilterContext {
        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = windows.first { $0.isFocused }

        // Which Spaces are on screen right now.
        //
        // `.optionOnScreenOnly` is the public API for exactly this question: it
        // lists the windows the user can currently see, which across displays is
        // one Space each. Deriving it instead from "windows that are not
        // minimized" — the obvious reading — is wrong, because a window sitting
        // on another Desktop is not minimized either. That made every Space look
        // visible and reduced the Visible Spaces scope to All Spaces.
        let onScreenIDs = Set(
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        )

        let visible = Set(windows.compactMap { window -> Int? in
            guard onScreenIDs.contains(window.id.cgWindowID) else { return nil }
            return window.spaceID
        })

        // The focused window is the best answer, but there is not always one —
        // clicking the desktop, or a focused app OpenTab filtered out. Falling
        // back to any visible Space keeps "Active Space" filtering meaningful
        // instead of quietly matching everything.
        let activeSpace = focused?.spaceID ?? visible.first

        return FilterContext(
            activePID: activePID,
            activeSpaceID: activeSpace,
            visibleSpaceIDs: visible,
            activeDisplayID: focused?.displayID
        )
    }

    // MARK: - Full enumeration

    /// Rebuilds everything from scratch on the background queue.
    private func rebuildAll() {
        let carriedFocusTimes = focusTimes
        let timeout = messagingTimeout

        let observedAt = Date()

        discoveryQueue.async { [weak self] in
            let started = DispatchTime.now()
            let result = WindowDiscovery.enumerateAll(
                previousFocusTimes: carriedFocusTimes,
                messagingTimeout: timeout
            )
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

            Task { @MainActor [weak self] in
                guard let self else { return }
                // The Space tally is here because "how many windows have a
                // known Space" is the one number that distinguishes working
                // Space filtering from silently-matching-everything, and the
                // symbol that answers it has stopped working once already.
                let spaces = Set(result.windows.compactMap(\.spaceID))
                Log.registry.notice(
                    """
                    Full enumeration: \(result.windows.count) windows, \(result.apps.count) apps, \
                    \(elapsedMS, format: .fixed(precision: 1))ms, \
                    \(result.windows.filter { $0.spaceID != nil }.count) with a known Space \
                    across \(spaces.count)
                    """
                )
                self.applyFullResult(result, observedAt: observedAt)
            }
        }
    }

    /// Publishes an enumeration result.
    ///
    /// - Parameters:
    ///   - observedAt: when the pass started. Everything in `result` describes the
    ///     world as of that moment, which may be several hundred milliseconds ago.
    ///   - onlyIfChanged: skip publishing when the outcome is identical to what is
    ///     already live, so an open overlay is not redrawn for nothing.
    private func applyFullResult(_ result: WindowDiscovery.Result,
                                 observedAt: Date,
                                 onlyIfChanged: Bool = false) {
        let previousApps = apps
        apps = result.apps

        // Preserve MRU for windows we already knew about; seed the rest.
        var merged = result.windows
        for index in merged.indices {
            let id = merged[index].id
            if let known = focusTimes[id] {
                merged[index].lastFocusedAt = known
            } else if merged[index].isFocused {
                let now = Date()
                focusTimes[id] = now
                merged[index].lastFocusedAt = now
            }
        }

        // Drop MRU entries for windows that no longer exist, so the dictionary
        // does not grow for the life of the process.
        let liveIDs = Set(merged.map(\.id))
        focusTimes = focusTimes.filter { liveIDs.contains($0.key) }

        applyRecordedFocus(to: &merged, observedAt: observedAt)

        guard !onlyIfChanged || windows != merged || apps != previousApps else { return }

        windows = merged
        isPopulated = true
        onChange?()
    }

    /// Kicks off a reconciliation pass without blocking the caller.
    ///
    /// Called when the switcher opens. Notifications are reliable enough that the
    /// list is almost always already right; this exists to repair the cases where
    /// an application does not emit one.
    public func reconcileInBackground() {
        guard isPopulated, !isReconciling else { return }
        isReconciling = true

        let carriedFocusTimes = focusTimes
        let timeout = messagingTimeout
        let observedAt = Date()

        discoveryQueue.async { [weak self] in
            let result = WindowDiscovery.enumerateAll(
                previousFocusTimes: carriedFocusTimes,
                messagingTimeout: timeout
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReconciling = false

                // Only publish if something actually moved. Redrawing an open
                // overlay for an identical list would flicker for no reason.
                self.applyFullResult(result, observedAt: observedAt, onlyIfChanged: true)
            }
        }
    }

    // MARK: - Incremental updates

    /// Refreshes one application's windows on the background queue.
    ///
    /// Most notifications route here rather than surgically patching a field.
    /// A single-app enumeration is a handful of IPC calls, and rebuilding from the
    /// source of truth avoids a long tail of "the flag says minimized but the
    /// window is on screen" bugs.
    private func refreshApplication(_ pid: pid_t) {
        guard let app = apps[pid] ?? makeAppModel(pid: pid) else {
            removeApplication(pid)
            return
        }

        let carriedFocusTimes = focusTimes
        let timeout = messagingTimeout
        let observedAt = Date()

        discoveryQueue.async { [weak self] in
            let element = AXUIElementCreateApplication(pid)
            AX.setMessagingTimeout(element, seconds: timeout)

            let cgInfo = WindowDiscovery.captureWindowInfo()
            let screens = ScreenGeometry.current()
            let focusedElement = AX.element(element, AXAttribute.focusedWindow)
            let focusedWindowID = focusedElement.flatMap { AX.windowID(of: $0) }

            let elements = AX.elements(element, AXAttribute.windows)
            var refreshed: [WindowModel] = elements.compactMap { windowElement in
                WindowDiscovery.makeWindowModel(
                    element: windowElement,
                    app: app,
                    cgInfo: cgInfo,
                    screens: screens,
                    focusedWindowID: focusedWindowID,
                    previousFocusTimes: carriedFocusTimes
                )
            }

            // Same substitution the full enumeration makes, under the same rule:
            // only when the application published nothing at all. Without it a
            // refresh would quietly drop the windows it cannot see and undo the
            // recovery a moment after enumeration made it.
            if refreshed.isEmpty,
               NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular {
                refreshed += WindowDiscovery.synthesizeMissingWindows(
                    for: app,
                    alreadyModelled: Set(refreshed.map(\.id.cgWindowID)),
                    cgInfo: cgInfo,
                    screens: screens,
                    previousFocusTimes: carriedFocusTimes
                )
            }

            // Still nothing, and the window server disagrees: this refresh failed
            // to see windows that exist rather than finding none. Publishing an
            // "app with no open window" entry would replace correct models with a
            // lie, so leave the list alone and wait for the next pass.
            if refreshed.isEmpty, WindowDiscovery.ownsWindows(pid: pid, in: cgInfo) {
                Log.registry.notice(
                    """
                    Refresh of \(app.name, privacy: .public) found no windows but the window \
                    server lists some; keeping the previous list
                    """
                )
                return
            }

            if refreshed.isEmpty, app.isActive || !app.bundleID.isEmpty {
                refreshed = [WindowDiscovery.makeApplicationEntry(app: app, element: element)]
            }

            Task { @MainActor [weak self] in
                self?.replaceWindows(ofPID: pid, with: refreshed, observedAt: observedAt)
            }
        }
    }

    /// Reconciles enumerated focus against what is actually known.
    ///
    /// Enumeration runs in the background and describes the world as of
    /// `observedAt`. Anything recorded since then — a switch the user just
    /// committed, an accessibility notification — is newer, and overwriting it
    /// with the older answer is how a fresh ⌘Tab ended up selecting the window
    /// the user was already on: "active window first" promoted the window they
    /// had just left, so the selection started one entry below where it should
    /// have, and releasing the key changed nothing. It only appeared when
    /// switching twice quickly, because that is when a pass is still in flight.
    ///
    /// Also enforces that exactly one window is flagged, which a per-application
    /// refresh cannot guarantee on its own: it only ever sees one app's windows,
    /// so it can raise a second flag without lowering the first.
    private func applyRecordedFocus(to list: inout [WindowModel], observedAt: Date) {
        guard focusObservedAt > observedAt else {
            // The pass is the newest information; adopt what it found.
            if let focused = list.first(where: \.isFocused) {
                focusedWindowID = focused.id
                focusObservedAt = observedAt
            }
            return
        }

        list = Self.reconcilingFocus(in: list, toRecorded: focusedWindowID)
    }

    /// Rewrites `isFocused` so that exactly the recorded window carries it.
    ///
    /// Pure, and internal rather than private, so the rule can be tested without
    /// an Accessibility grant — the registry itself cannot run in CI.
    nonisolated static func reconcilingFocus(in list: [WindowModel], toRecorded id: WindowID?) -> [WindowModel] {
        var result = list
        for index in result.indices {
            result[index].isFocused = result[index].id == id
        }
        return result
    }

    private func replaceWindows(ofPID pid: pid_t, with refreshed: [WindowModel], observedAt: Date) {
        var updated = windows.filter { $0.id.pid != pid }
        updated.append(contentsOf: refreshed)

        // Application entries only make sense when the app really has no windows.
        let hasRealWindow = refreshed.contains { !$0.isApplicationEntry }
        if hasRealWindow {
            updated.removeAll { $0.id.pid == pid && $0.isApplicationEntry }
        }

        applyRecordedFocus(to: &updated, observedAt: observedAt)

        guard updated != windows else { return }
        windows = updated
        onChange?()
    }

    private func removeApplication(_ pid: pid_t) {
        observers[pid]?.invalidate()
        observers[pid] = nil
        apps[pid] = nil

        let remaining = windows.filter { $0.id.pid != pid }
        focusTimes = focusTimes.filter { $0.key.pid != pid }

        guard remaining.count != windows.count else { return }
        windows = remaining
        onChange?()
    }

    /// Coalesces a burst of notifications into one refresh per application.
    private func scheduleRefresh(for pid: pid_t) {
        pendingRefreshes.insert(pid)

        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pids = self.pendingRefreshes
                self.pendingRefreshes.removeAll()
                for pid in pids { self.refreshApplication(pid) }
            }
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDebounce, execute: item)
    }

    // MARK: - Focus tracking

    /// Records that a window took focus. Drives most-recently-used ordering.
    public func noteFocus(_ id: WindowID) {
        let now = Date()
        focusTimes[id] = now
        focusedWindowID = id
        focusObservedAt = now

        var changed = false
        for index in windows.indices {
            let isTarget = windows[index].id == id
            if isTarget {
                windows[index].lastFocusedAt = now
            }
            if windows[index].isFocused != isTarget {
                windows[index].isFocused = isTarget
                changed = true
            }
        }
        if changed { onChange?() }
    }

    /// Focus moved to a window we may not have a model for yet.
    private func noteFocusChanged(pid: pid_t, element: AXUIElement) {
        if let windowID = AX.windowID(of: element) {
            noteFocus(WindowID(cgWindowID: windowID, pid: pid))
        } else {
            scheduleRefresh(for: pid)
        }
    }

    // MARK: - Observers

    private func attachObserver(to pid: pid_t) {
        guard observers[pid] == nil else { return }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        let observer = AXAppObserver(pid: pid, messagingTimeout: messagingTimeout) { [weak self] notification, element in
            // AXObserver callbacks arrive on the main run loop.
            MainActor.assumeIsolated {
                self?.handleAXNotification(notification, element: element, pid: pid)
            }
        }
        guard let observer else { return }

        observer.observe()
        observers[pid] = observer
    }

    private func handleAXNotification(_ notification: String, element: AXUIElement, pid: pid_t) {
        switch notification {
        case kAXFocusedWindowChangedNotification:
            noteFocusChanged(pid: pid, element: element)

        case kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            setHidden(notification == kAXApplicationHiddenNotification, forPID: pid)

        default:
            // Everything else — created, destroyed, minimized, deminiaturized,
            // title changed, moved, resized — is handled by re-reading the app.
            // A destroyed element cannot be queried at all, so a surgical update
            // is not even possible for that case.
            scheduleRefresh(for: pid)
        }
    }

    private func setHidden(_ isHidden: Bool, forPID pid: pid_t) {
        apps[pid]?.isHidden = isHidden

        var changed = false
        for index in windows.indices where windows[index].id.pid == pid {
            if windows[index].isHidden != isHidden {
                windows[index].isHidden = isHidden
                changed = true
            }
        }
        if changed { onChange?() }
    }

    private func subscribeToWorkspace() {
        let center = NSWorkspace.shared.notificationCenter

        func observe(_ name: NSNotification.Name,
                     _ handler: @escaping @MainActor (NSRunningApplication?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { handler(app) }
            }
            workspaceObservers.append(token)
        }

        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.apps[app.processIdentifier] = self.makeAppModel(from: app)
            self.attachObserver(to: app.processIdentifier)
            // Applications do not have their windows ready the instant they launch,
            // so give the first refresh a moment to find something.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self.scheduleRefresh(for: app.processIdentifier) }
            }
        }

        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.removeApplication(app.processIdentifier)
        }

        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.setActiveApplication(app.processIdentifier)
        }

        observe(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.setHidden(true, forPID: app.processIdentifier)
        }

        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.setHidden(false, forPID: app.processIdentifier)
        }

        // Space changes alter which windows are visible and can change every
        // window's Space assignment, so re-derive rather than patch.
        let spaceToken = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.reconcileInBackground() }
        }
        workspaceObservers.append(spaceToken)
    }

    private func setActiveApplication(_ pid: pid_t) {
        var changed = false
        for key in apps.keys {
            let isActive = key == pid
            if apps[key]?.isActive != isActive {
                apps[key]?.isActive = isActive
                changed = true
            }
        }
        // The newly active app's focused window becomes the focused window.
        scheduleRefresh(for: pid)
        if changed { onChange?() }
    }

    // MARK: - Helpers

    private func makeAppModel(pid: pid_t) -> AppModel? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return makeAppModel(from: app)
    }

    private func makeAppModel(from app: NSRunningApplication) -> AppModel {
        AppModel(
            id: app.processIdentifier,
            bundleID: app.bundleIdentifier ?? "",
            name: app.localizedName ?? "",
            icon: app.icon,
            isHidden: app.isHidden,
            isActive: app.isActive,
            launchedAt: app.launchDate ?? .distantPast
        )
    }
}
