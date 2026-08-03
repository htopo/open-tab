import AppKit
import CoreGraphics
import Foundation
import OpenTabCore
import ScreenCaptureKit

/// Carries a captured image across an isolation boundary.
///
/// `NSImage` is not `Sendable`, and correctly so — it is mutable. These instances
/// are created inside the capture task, handed over once, and never drawn into
/// afterwards, which makes the transfer safe in a way the compiler cannot verify.
public struct CapturedImage: @unchecked Sendable {
    public let image: NSImage
    public init(_ image: NSImage) { self.image = image }
}

/// Captures single-window images with ScreenCaptureKit.
///
/// `SCScreenshotManager.captureImage` is the only non-deprecated way to grab one
/// window's pixels on macOS 14+; `CGWindowListCreateImage` was deprecated in the
/// same release. It is asynchronous and must never be called from the event tap
/// callback or the main thread.
public actor WindowCapturer {

    /// Cached `SCWindow` handles, keyed by window ID.
    ///
    /// `SCShareableContent.current` enumerates every window on the system and is
    /// far too expensive to call per capture, so the list is refreshed on a
    /// schedule and reused. A window missing from it simply is not captured this
    /// round; the next refresh picks it up.
    private var shareableWindows: [CGWindowID: SCWindow] = [:]
    private var lastContentRefresh: Date = .distantPast

    /// How long the shareable-content list stays usable. Short enough that a newly
    /// opened window gets a thumbnail promptly, long enough not to dominate cost.
    private let contentTTL: TimeInterval = 2.0

    public init() {}

    // MARK: - Content list

    /// Refreshes the `SCWindow` list if it has aged out.
    private func refreshContentIfNeeded(force: Bool = false) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastContentRefresh) > contentTTL else { return }

        do {
            // onScreenWindowsOnly: false so that windows which are merely occluded
            // are still captured. It does not reach minimized or other-Space
            // windows — nothing does; macOS composites no pixels for those.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            shareableWindows = Dictionary(
                content.windows.map { ($0.windowID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            lastContentRefresh = now
        } catch {
            // Almost always "Screen Recording not granted". Not an error condition
            // for this app — thumbnails are optional — so it is logged and dropped.
            Log.capture.debug("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            shareableWindows = [:]
        }
    }

    public func invalidateContentCache() {
        lastContentRefresh = .distantPast
    }

    // MARK: - Capture

    /// Captures one window at the requested point size.
    ///
    /// - Parameters:
    ///   - windowID: the window server ID to capture.
    ///   - targetSize: desired size in *points*.
    ///   - scale: backing scale factor of the display it will be drawn on.
    /// - Returns: the image, or nil if the window is not capturable right now.
    public func capture(windowID: CGWindowID,
                        targetSize: CGSize,
                        scale: CGFloat) async -> CapturedImage? {
        await refreshContentIfNeeded()

        guard let window = shareableWindows[windowID] else {
            // Possibly just created. One forced refresh is worth it; repeated
            // misses simply wait for the next scheduled refresh.
            await refreshContentIfNeeded(force: true)
            guard shareableWindows[windowID] != nil else { return nil }
            return await performCapture(shareableWindows[windowID]!, targetSize: targetSize, scale: scale)
        }

        return await performCapture(window, targetSize: targetSize, scale: scale)
    }

    private func performCapture(_ window: SCWindow,
                                targetSize: CGSize,
                                scale: CGFloat) async -> CapturedImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let configuration = SCStreamConfiguration()

        // Size the capture to what will actually be *drawn*, not to the window's
        // native size. Capturing a 6K window to render a 200 pt thumbnail costs
        // tens of milliseconds and a large allocation for pixels that are then
        // thrown away.
        let pixelWidth = max(1, Int((targetSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((targetSize.height * scale).rounded()))
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.ignoreGlobalClipDisplay = true
        configuration.ignoreShadowsSingleWindow = true

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return CapturedImage(NSImage(cgImage: cgImage, size: targetSize))
        } catch {
            Log.capture.debug(
                "Capture of window \(window.windowID) failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
