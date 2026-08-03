import AppKit
import CoreGraphics
import Foundation
import OpenTabCore

/// Cached window images.
///
/// The cache is what makes the overlay appear instantly: capture is asynchronous
/// and takes tens of milliseconds per window, far more than the whole latency
/// budget, so the first frame is always drawn from here. It is also the only way
/// to show anything at all for minimized and other-Space windows, which macOS
/// composites nothing for and which therefore cannot be captured on demand.
@MainActor
public final class ThumbnailCache {

    public struct Entry {
        public let image: NSImage
        public let capturedAt: Date
        /// The window frame at capture time. A resize invalidates the image.
        public let sourceFrame: CGRect
        /// The title at capture time. A title change usually means the content
        /// changed too — a new document, a different browser tab.
        public let sourceTitle: String
    }

    private var entries: [WindowID: Entry] = [:]
    /// Access order, oldest first, for eviction.
    private var accessOrder: [WindowID] = []

    /// Upper bound on retained images. A few hundred thumbnails at ~200 pt is a
    /// few megabytes; unbounded growth over a working day is not acceptable for a
    /// background utility.
    private let capacity: Int

    /// How long a cached image stays usable for a window that can still be
    /// captured. Minimized and other-Space windows deliberately ignore this —
    /// a stale image is infinitely better than no image for those.
    private let maximumAge: TimeInterval

    public init(capacity: Int = 256, maximumAge: TimeInterval = 60) {
        self.capacity = capacity
        self.maximumAge = maximumAge
    }

    // MARK: - Reading

    /// The best available image for a window, ignoring staleness.
    ///
    /// Used to draw the first frame. Showing a slightly out-of-date thumbnail
    /// immediately beats showing a placeholder while a fresh one is captured.
    public func image(for id: WindowID) -> NSImage? {
        guard let entry = entries[id] else { return nil }
        touch(id)
        return entry.image
    }

    public func entry(for id: WindowID) -> Entry? {
        entries[id]
    }

    /// Whether a window's cached image should be replaced.
    ///
    /// A window that cannot be captured is never considered stale: there is
    /// nothing better to replace it with.
    public func needsRefresh(_ window: WindowModel, now: Date = Date()) -> Bool {
        guard isCapturable(window) else { return false }
        guard let entry = entries[window.id] else { return true }

        if entry.sourceFrame.size != window.frame.size { return true }
        if entry.sourceTitle != window.title { return true }
        return now.timeIntervalSince(entry.capturedAt) > maximumAge
    }

    /// Whether macOS has anything to capture for this window.
    ///
    /// Minimized windows and windows on another Space are not composited, so a
    /// capture attempt returns either nothing or a blank image. Recognising that
    /// up front avoids wasting capture slots on requests that cannot succeed.
    public func isCapturable(_ window: WindowModel) -> Bool {
        !window.isMinimized && !window.isHidden && !window.isApplicationEntry
    }

    // MARK: - Writing

    public func store(_ image: NSImage, for window: WindowModel, at date: Date = Date()) {
        entries[window.id] = Entry(
            image: image,
            capturedAt: date,
            sourceFrame: window.frame,
            sourceTitle: window.title
        )
        touch(window.id)
        evictIfNeeded()
    }

    public func remove(_ id: WindowID) {
        entries[id] = nil
        accessOrder.removeAll { $0 == id }
    }

    /// Drops entries for windows that no longer exist.
    public func retain(only live: Set<WindowID>) {
        let stale = entries.keys.filter { !live.contains($0) }
        for id in stale { remove(id) }
    }

    public func removeAll() {
        entries.removeAll()
        accessOrder.removeAll()
    }

    public var count: Int { entries.count }

    // MARK: - Eviction

    private func touch(_ id: WindowID) {
        accessOrder.removeAll { $0 == id }
        accessOrder.append(id)
    }

    private func evictIfNeeded() {
        while entries.count > capacity, let oldest = accessOrder.first {
            entries[oldest] = nil
            accessOrder.removeFirst()
        }
    }
}
