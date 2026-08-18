import Foundation

extension Bundle {

    /// The resource bundle holding this target's `.lproj` directories.
    ///
    /// Deliberately **not** `Bundle.module`. SwiftPM generates that accessor with
    /// exactly two candidate paths: `Bundle.main.bundleURL/<name>.bundle`, and the
    /// absolute path of the resource bundle in the developer's own `.build`
    /// directory. Neither is where an assembled `.app` keeps its resources.
    ///
    /// The result is a trap that cannot be hit on the machine that built the app:
    /// there the hard-coded `.build` path still exists, so `Bundle.module`
    /// resolves and everything looks fine. On any other machine both candidates
    /// miss and the generated accessor calls `fatalError` — the app dies the first
    /// time it needs a localized string, which for OpenTab was opening Settings.
    ///
    /// So the lookup is done here instead, over the locations a real bundle can
    /// occupy, and it ends in a fallback rather than a trap. Strings are not worth
    /// a crash: an untranslated label is a blemish, a dead app is not.
    static let openTabResources: Bundle = {
        let name = "OpenTab_OpenTabUI.bundle"

        let candidates = [
            // Where Scripts/bundle.sh puts it, and where macOS keeps resources.
            Bundle.main.resourceURL,
            // SwiftPM's own layout, next to the executable.
            Bundle.main.bundleURL,
            // A framework or test host embedding this code.
            Bundle(for: BundleToken.self).resourceURL,
            Bundle(for: BundleToken.self).bundleURL,
        ]

        for candidate in candidates {
            guard let url = candidate?.appendingPathComponent(name),
                  let bundle = Bundle(url: url)
            else { continue }
            return bundle
        }

        // Nothing found. `NSLocalizedString` against this returns the key, which
        // is what `L10n` promises for a missing translation anyway.
        return Bundle(for: BundleToken.self)
    }()
}

/// Anchors `Bundle(for:)` to whichever binary this code was linked into.
private final class BundleToken {}

/// String lookup for user-facing text.
///
/// Every localizable string goes through here rather than being written inline,
/// so that adding a language is a matter of copying `en.lproj/Localizable.strings`
/// and translating the values — no code change.
public enum L10n {

    /// The localized value for `key`, falling back to the key itself.
    ///
    /// Returning the key rather than an empty string means a missing translation
    /// shows up as an obviously-wrong identifier in the UI instead of a blank
    /// control, which is much easier to spot and report.
    public static func string(_ key: String, comment: String = "") -> String {
        NSLocalizedString(key, bundle: .openTabResources, comment: comment)
    }

    /// Formatted variant.
    public static func string(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: NSLocalizedString(key, bundle: .openTabResources, comment: ""), arguments: arguments)
    }
}

/// The language override from the General pane.
///
/// macOS resolves an app's language at launch from `AppleLanguages`, so a change
/// here only takes effect on the next start. That is why the picker's label says
/// so and why the app offers to restart after a reset.
public enum LanguageOverride {

    private static let defaultsKey = "AppleLanguages"

    /// Applies a language code, or clears the override to follow the system.
    public static func apply(_ code: String?) {
        if let code, !code.isEmpty {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// The override currently in force, or nil when following the system.
    public static var current: String? {
        (UserDefaults.standard.array(forKey: defaultsKey) as? [String])?.first
    }

    /// Language codes this build actually ships strings for.
    ///
    /// Derived from the bundle rather than hard-coded, so the picker cannot offer
    /// a language whose strings are missing.
    public static var availableLanguages: [String] {
        Bundle.openTabResources.localizations.filter { $0 != "Base" }.sorted()
    }
}
