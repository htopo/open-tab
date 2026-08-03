import AppKit
import CoreGraphics
import Testing
@testable import OpenTabCore
@testable import OpenTabShot

/// Thumbnail caching and invalidation.
///
/// The cache is what lets the overlay appear instantly — the first frame is always
/// drawn from here because capture takes longer than the entire latency budget.
/// It is also the only source of any image at all for minimized and other-Space
/// windows, which macOS composites nothing for.
@Suite("Thumbnail cache")
@MainActor
struct ThumbnailCacheTests {

    private func image(_ side: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: side, height: side))
    }

    private func window(
        _ id: CGWindowID,
        title: String = "Document",
        size: CGSize = CGSize(width: 800, height: 600),
        minimized: Bool = false,
        hidden: Bool = false,
        kind: WindowKind = .window
    ) -> WindowModel {
        WindowModel(
            id: WindowID(cgWindowID: id, pid: 100),
            kind: kind,
            title: title,
            isMinimized: minimized,
            isHidden: hidden,
            frame: CGRect(origin: .zero, size: size)
        )
    }

    // MARK: - Storage

    @Test("A stored image is retrievable")
    func storeAndRetrieve() {
        let cache = ThumbnailCache()
        let w = window(1)

        #expect(cache.image(for: w.id) == nil)
        cache.store(image(), for: w)
        #expect(cache.image(for: w.id) != nil)
    }

    @Test("Removing drops the entry")
    func remove() {
        let cache = ThumbnailCache()
        let w = window(1)
        cache.store(image(), for: w)

        cache.remove(w.id)
        #expect(cache.image(for: w.id) == nil)
    }

    /// Without this the cache grows for the life of the process.
    @Test("Entries for dead windows are dropped")
    func retainOnlyLiveWindows() {
        let cache = ThumbnailCache()
        let alive = window(1)
        let dead = window(2)
        cache.store(image(), for: alive)
        cache.store(image(), for: dead)

        cache.retain(only: [alive.id])

        #expect(cache.image(for: alive.id) != nil)
        #expect(cache.image(for: dead.id) == nil)
        #expect(cache.count == 1)
    }

    // MARK: - Capturability

    /// macOS composites nothing for these, so a capture attempt returns a blank
    /// image at best. Recognising it up front avoids wasting capture slots.
    @Test("Minimized, hidden, and app-only entries are not capturable")
    func uncapturableWindows() {
        let cache = ThumbnailCache()
        #expect(!cache.isCapturable(window(1, minimized: true)))
        #expect(!cache.isCapturable(window(2, hidden: true)))
        #expect(!cache.isCapturable(window(3, kind: .applicationWithNoWindows)))
        #expect(cache.isCapturable(window(4)))
    }

    // MARK: - Invalidation

    @Test("A window with no cached image needs a refresh")
    func missingEntryNeedsRefresh() {
        let cache = ThumbnailCache()
        #expect(cache.needsRefresh(window(1)))
    }

    @Test("A resize invalidates the cached image")
    func resizeInvalidates() {
        let cache = ThumbnailCache()
        let original = window(1, size: CGSize(width: 800, height: 600))
        cache.store(image(), for: original)

        #expect(!cache.needsRefresh(original))

        let resized = window(1, size: CGSize(width: 1200, height: 900))
        #expect(cache.needsRefresh(resized))
    }

    /// A new title usually means new content — a different document, another tab.
    @Test("A title change invalidates the cached image")
    func titleChangeInvalidates() {
        let cache = ThumbnailCache()
        cache.store(image(), for: window(1, title: "Invoice"))

        #expect(cache.needsRefresh(window(1, title: "Report")))
    }

    @Test("An image older than the maximum age is stale")
    func agingInvalidates() {
        let cache = ThumbnailCache(maximumAge: 30)
        let w = window(1)
        let longAgo = Date(timeIntervalSince1970: 1_000_000)
        cache.store(image(), for: w, at: longAgo)

        #expect(cache.needsRefresh(w, now: longAgo.addingTimeInterval(31)))
        #expect(!cache.needsRefresh(w, now: longAgo.addingTimeInterval(5)))
    }

    /// A stale image is infinitely better than no image for a window that cannot
    /// be captured, so age must not evict it.
    @Test("An uncapturable window is never considered stale")
    func uncapturableWindowsNeverGoStale() {
        let cache = ThumbnailCache(maximumAge: 1)
        let minimized = window(1, minimized: true)
        let longAgo = Date(timeIntervalSince1970: 1_000_000)
        cache.store(image(), for: minimized, at: longAgo)

        #expect(!cache.needsRefresh(minimized, now: longAgo.addingTimeInterval(10_000)))
        #expect(cache.image(for: minimized.id) != nil)
    }

    /// The eager-capture path: a window photographed while visible must still have
    /// that image once it is minimized.
    @Test("An image captured before minimizing survives minimizing")
    func imageSurvivesMinimizing() {
        let cache = ThumbnailCache()
        let visible = window(1)
        cache.store(image(), for: visible)

        let minimized = window(1, minimized: true)
        #expect(cache.image(for: minimized.id) != nil)
        #expect(!cache.needsRefresh(minimized))
    }

    // MARK: - Eviction

    @Test("The cache is bounded by its capacity")
    func evictionRespectsCapacity() {
        let cache = ThumbnailCache(capacity: 3)
        for id in 1...6 { cache.store(image(), for: window(CGWindowID(id))) }

        #expect(cache.count == 3)
    }

    @Test("Eviction removes the least recently used entry")
    func evictionIsLeastRecentlyUsed() {
        let cache = ThumbnailCache(capacity: 2)
        let a = window(1), b = window(2), c = window(3)

        cache.store(image(), for: a)
        cache.store(image(), for: b)

        // Touch a, making b the least recently used.
        _ = cache.image(for: a.id)
        cache.store(image(), for: c)

        #expect(cache.image(for: a.id) != nil)
        #expect(cache.image(for: b.id) == nil)
        #expect(cache.image(for: c.id) != nil)
    }

    @Test("Re-storing an existing window does not grow the cache")
    func restoringDoesNotDuplicate() {
        let cache = ThumbnailCache(capacity: 10)
        let w = window(1)

        cache.store(image(), for: w)
        cache.store(image(), for: w)
        cache.store(image(), for: w)

        #expect(cache.count == 1)
    }

    @Test("Clearing empties the cache")
    func removeAllEmpties() {
        let cache = ThumbnailCache()
        for id in 1...5 { cache.store(image(), for: window(CGWindowID(id))) }

        cache.removeAll()
        #expect(cache.count == 0)
    }

    // MARK: - Identity

    /// Window IDs are recycled by the window server, so pairing with the pid is
    /// what stops one app's thumbnail appearing on another's window.
    @Test("Cache keys distinguish the same window ID under different processes")
    func windowIDIncludesProcess() {
        let cache = ThumbnailCache()
        let first = WindowID(cgWindowID: 42, pid: 100)
        let second = WindowID(cgWindowID: 42, pid: 200)

        cache.store(image(), for: WindowModel(id: first))

        #expect(cache.image(for: first) != nil)
        #expect(cache.image(for: second) == nil)
    }
}
