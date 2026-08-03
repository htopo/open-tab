import Foundation

/// String lookup for user-facing text.
///
/// Every localizable string goes through here rather than being written inline,
/// so that adding a language is a matter of copying `en.lproj/Localizable.strings`
/// and translating the values — no code change.
///
/// `Bundle.module` is the resource bundle SwiftPM generates for this target. When
/// running outside an app bundle it still resolves, so the strings work under
/// `swift run` and in tests.
public enum L10n {

    /// The localized value for `key`, falling back to the key itself.
    ///
    /// Returning the key rather than an empty string means a missing translation
    /// shows up as an obviously-wrong identifier in the UI instead of a blank
    /// control, which is much easier to spot and report.
    public static func string(_ key: String, comment: String = "") -> String {
        NSLocalizedString(key, bundle: .module, comment: comment)
    }

    /// Formatted variant.
    public static func string(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: NSLocalizedString(key, bundle: .module, comment: ""), arguments: arguments)
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
        Bundle.module.localizations.filter { $0 != "Base" }.sorted()
    }
}
