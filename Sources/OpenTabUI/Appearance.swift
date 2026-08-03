import AppKit
import SwiftUI

/// Light/dark handling for the overlay and settings windows.
///
/// The overlay is an `NSPanel` that never becomes key, so it does not inherit
/// appearance the way an ordinary window does — the appearance has to be applied
/// to the panel explicitly. These helpers keep that mapping in one place.
public enum ThemePreference: String, CaseIterable, Codable, Sendable {
    case light
    case dark
    case system

    public var displayName: String {
        switch self {
        case .light:  "Light"
        case .dark:   "Dark"
        case .system: "System"
        }
    }

    /// The appearance to force, or nil to follow the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .light:  .light
        case .dark:   .dark
        case .system: nil
        }
    }
}

/// Whether motion should be suppressed.
///
/// Honours the system accessibility setting in addition to OpenTab's own
/// "reduce animations" toggle — a user who asked the OS to reduce motion should
/// not have to ask again here.
public enum MotionPreference {
    public static var systemPrefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static func shouldAnimate(userReduceAnimations: Bool) -> Bool {
        !(userReduceAnimations || systemPrefersReducedMotion)
    }
}
