import AppKit
import Foundation
import OpenTabCore

/// Decides what to capture and when.
///
/// The contract with the overlay is that this never blocks it. The switcher draws
/// immediately from cache — or app icons — and thumbnails arrive afterwards
/// through `onThumbnail`. Capture is asynchronous and takes tens of milliseconds
/// per window, which is more than the entire budget for showing the panel, so
/// there is no version of "wait for the images" that is acceptable.
@MainActor
public final class CaptureCoordinator {

    /// Called on the main actor as each image arrives.
    public var onThumbnail: ((WindowID, NSImage) -> Void)?

    public let cache: ThumbnailCache
    private let capturer = WindowCapturer()

    /// Honours General → "Capture windows in the background".
    ///
    /// When off, capture happens only at switcher-open time. That avoids the
    /// purple screen-recording indicator and the flicker it causes in DRM video,
    /// at the cost of staler thumbnails.
    public var isBackgroundCaptureEnabled: Bool {
        didSet {
            guard isBackgroundCaptureEnabled != oldValue else { return }
            isBackgroundCaptureEnabled ? startBackgroundRefresh() : stopBackgroundRefresh()
        }
    }

    /// Whether Screen Recording is granted. When false nothing is attempted and
    /// the switcher shows app icons, which is a supported way to use the app.
    public var isPermitted: Bool = ScreenRecordingPermission.isGranted

    /// Concurrency cap. Each capture is a round trip through the window server;
    /// running them all at once starves the very windows being captured and makes
    /// the first thumbnail arrive later, not sooner.
    private static let maximumConcurrentCaptures = 4

    /// How often background refresh sweeps the cache.
    private static let backgroundRefreshInterval: TimeInterval = 8

    private var refreshTimer: Timer?
    private var inFlight: Set<WindowID> = []
    private var currentBatch: Task<Void, Never>?

    /// Windows currently worth keeping warm, set whenever the registry changes.
    private var trackedWindows: [WindowModel] = []
    private var thumbnailSize: CGSize = CGSize(width: 220, height: 138)

    /// - Parameter cache: pass nil for a fresh cache. It cannot be a default
    ///   argument because default arguments are evaluated outside the actor.
    public init(cache: ThumbnailCache? = nil,
                isBackgroundCaptureEnabled: Bool = true) {
        self.cache = cache ?? ThumbnailCache()
        self.isBackgroundCaptureEnabled = isBackgroundCaptureEnabled
    }

    // MARK: - Lifecycle

    public func start() {
        refreshPermission()
        if isBackgroundCaptureEnabled { startBackgroundRefresh() }
    }

    public func stop() {
        stopBackgroundRefresh()
        currentBatch?.cancel()
        currentBatch = nil
        inFlight.removeAll()
    }

    public func refreshPermission() {
        isPermitted = ScreenRecordingPermission.isGranted
    }

    // MARK: - Registry integration

    /// Tells the coordinator which windows exist, so it can keep them warm and
    /// drop cache entries for windows that have gone.
    public func updateTrackedWindows(_ windows: [WindowModel]) {
        trackedWindows = windows
        cache.retain(only: Set(windows.map(\.id)))
    }

    /// Sets the size images should be captured at.
    ///
    /// Driven by the current appearance settings, because capturing larger than
    /// what is drawn is pure waste.
    public func setThumbnailSize(_ size: CGSize) {
        guard size != thumbnailSize else { return }
        thumbnailSize = size
        // Existing entries were captured at the old size; they will still draw,
        // just slightly soft, and are replaced on the next refresh.
    }

    // MARK: - On-demand capture

    /// The image to draw right now, if any.
    ///
    /// Never triggers a capture. Deliberately synchronous and cheap: it is called
    /// during overlay layout.
    public func cachedThumbnail(for id: WindowID) -> NSImage? {
        cache.image(for: id)
    }

    /// Every cached image for a set of windows, for seeding the overlay's first
    /// frame in one pass.
    public func cachedThumbnails(for windows: [WindowModel]) -> [WindowID: NSImage] {
        var result: [WindowID: NSImage] = [:]
        for window in windows {
            if let image = cache.image(for: window.id) { result[window.id] = image }
        }
        return result
    }

    /// Kicks off captures for the windows the switcher is about to show.
    ///
    /// Returns immediately. Images are delivered through `onThumbnail` as they
    /// arrive, in the order the windows were passed — so the selected window and
    /// its neighbours, which the caller puts first, are filled in soonest.
    public func requestCaptures(for windows: [WindowModel], scale: CGFloat) {
        guard isPermitted else { return }

        let needed = windows.filter { window in
            cache.isCapturable(window)
                && !inFlight.contains(window.id)
                && cache.needsRefresh(window)
        }
        guard !needed.isEmpty else { return }

        currentBatch?.cancel()
        currentBatch = Task { [weak self] in
            await self?.runCaptures(needed, scale: scale)
        }
    }

    private func runCaptures(_ windows: [WindowModel], scale: CGFloat) async {
        let size = thumbnailSize
        for window in windows { inFlight.insert(window.id) }
        defer { for window in windows { inFlight.remove(window.id) } }

        await withTaskGroup(of: (WindowModel, CapturedImage?).self) { group in
            var index = 0

            // Bounded concurrency: start a fixed number, then add one more each
            // time one finishes.
            func addNext() {
                guard index < windows.count else { return }
                let window = windows[index]
                index += 1
                group.addTask { [capturer] in
                    let image = await capturer.capture(
                        windowID: window.id.cgWindowID,
                        targetSize: size,
                        scale: scale
                    )
                    return (window, image)
                }
            }

            for _ in 0..<min(Self.maximumConcurrentCaptures, windows.count) { addNext() }

            while let (window, captured) = await group.next() {
                if Task.isCancelled { break }
                if let captured {
                    cache.store(captured.image, for: window)
                    onThumbnail?(window.id, captured.image)
                }
                addNext()
            }
        }
    }

    // MARK: - Eager capture

    /// Captures a window that is about to become uncapturable.
    ///
    /// Called when a window loses focus rather than when it is minimized: by the
    /// time `kAXWindowMiniaturizedNotification` arrives, macOS has already stopped
    /// compositing the window and there is nothing left to photograph. Capturing
    /// on focus-loss is the last reliable moment.
    public func captureBeforeItBecomesUnavailable(_ window: WindowModel, scale: CGFloat) {
        guard isPermitted, cache.isCapturable(window), !inFlight.contains(window.id) else { return }

        inFlight.insert(window.id)
        let size = thumbnailSize

        Task { [weak self, capturer] in
            let captured = await capturer.capture(
                windowID: window.id.cgWindowID,
                targetSize: size,
                scale: scale
            )
            guard let self else { return }
            self.inFlight.remove(window.id)
            guard let captured else { return }
            self.cache.store(captured.image, for: window)
            self.onThumbnail?(window.id, captured.image)
        }
    }

    // MARK: - Background refresh

    private func startBackgroundRefresh() {
        guard refreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.backgroundRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.performBackgroundRefresh() }
        }
        // Default mode only: a background refresh has no business running while
        // the user is dragging something or holding a menu open.
        RunLoop.main.add(timer, forMode: .default)
        refreshTimer = timer
        Log.capture.debug("Background thumbnail refresh started")
    }

    private func stopBackgroundRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        Log.capture.debug("Background thumbnail refresh stopped")
    }

    private func performBackgroundRefresh() {
        guard isPermitted, isBackgroundCaptureEnabled else { return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let stale = trackedWindows.filter { cache.needsRefresh($0) }
        guard !stale.isEmpty else { return }

        // Only a handful per sweep. This runs while the user is doing something
        // else; it must stay invisible.
        requestCaptures(for: Array(stale.prefix(Self.maximumConcurrentCaptures)), scale: scale)
    }
}
