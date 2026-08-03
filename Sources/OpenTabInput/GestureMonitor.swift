import AppKit
import Foundation
import OpenTabCore

/// Opens the switcher from a trackpad swipe.
///
/// The lowest-priority trigger in the app and the one shipped disabled, because
/// gesture recognition on a trackpad is inherently ambiguous: the same physical
/// movement is a Mission Control swipe, a Space change, a browser back gesture,
/// and this. Rather than compete with those, OpenTab only listens once a user has
/// explicitly asked for it, and requires a deliberate movement before firing.
@MainActor
public final class GestureMonitor {

    /// Called when the gesture completes.
    public var onTrigger: (() -> Void)?

    /// Called with a selection delta while the switcher is open, so the same
    /// swipe that opened it can also move through it.
    public var onNavigate: ((Int) -> Void)?

    public private(set) var isRunning = false

    private var settings: GestureSettings
    private var monitor: Any?

    /// How far the fingers must travel before this counts as a gesture rather
    /// than a stray brush. Generous, because a false positive here means the
    /// switcher appearing while the user was doing something else entirely.
    private static let activationDistance: CGFloat = 60

    /// Distance per selection step once the switcher is open.
    private static let stepDistance: CGFloat = 45

    private var accumulated: CGFloat = 0
    private var hasTriggered = false
    private var isSwitcherOpen = false

    public init(settings: GestureSettings = .default) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    public func update(settings: GestureSettings) {
        self.settings = settings
        settings.isEnabled ? start() : stop()
    }

    public func start() {
        guard settings.isEnabled, monitor == nil else { return }

        // A global monitor sees scroll events destined for other applications,
        // which is where a trackpad swipe lands when OpenTab is not frontmost.
        // It is observe-only — the gesture is never consumed, so a swipe that
        // does not meet the threshold still reaches whatever it was aimed at.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        isRunning = true
        Log.input.notice("Trackpad gesture monitor started (\(self.settings.fingerCount) fingers)")
    }

    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRunning = false
        reset()
    }

    /// Told when the overlay opens and closes, so a continuing swipe moves the
    /// selection instead of re-triggering.
    public func setSwitcherOpen(_ isOpen: Bool) {
        isSwitcherOpen = isOpen
        if !isOpen { reset() }
    }

    // MARK: - Recognition

    private func handle(_ event: NSEvent) {
        // Only trackpad scrolling has phases; a mouse wheel does not, and must not
        // be able to trigger this.
        guard event.hasPreciseScrollingDeltas else { return }

        switch event.phase {
        case .began:
            reset()
            return
        case .ended, .cancelled:
            reset()
            return
        default:
            break
        }

        // Momentum is the trackpad coasting after the fingers have lifted. Acting
        // on it would make one flick scroll through the whole list.
        guard event.momentumPhase == [] else { return }

        // Horizontal movement, which is what "swipe between windows" means and
        // what does not collide with ordinary vertical scrolling.
        let delta = event.scrollingDeltaX
        guard abs(delta) > abs(event.scrollingDeltaY) else { return }

        accumulated += delta

        if !hasTriggered {
            guard abs(accumulated) >= Self.activationDistance else { return }
            hasTriggered = true
            accumulated = 0
            onTrigger?()
            return
        }

        guard isSwitcherOpen else { return }

        while abs(accumulated) >= Self.stepDistance {
            let step = accumulated > 0 ? -1 : 1
            accumulated += step > 0 ? Self.stepDistance : -Self.stepDistance
            onNavigate?(step)
        }
    }

    private func reset() {
        accumulated = 0
        hasTriggered = false
    }
}
