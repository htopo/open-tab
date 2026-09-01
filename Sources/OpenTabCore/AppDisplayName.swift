import Foundation

/// How an application's name is written in the switcher.
public enum AppDisplayName {

    /// Vendor prefixes dropped from a name when shortening is on.
    ///
    /// Deliberately a short, closed list of company names rather than a rule.
    /// Anything cleverer — dropping the first word, dropping any word that
    /// matches the bundle identifier's second component — starts renaming
    /// applications whose first word is the part that identifies them.
    static let vendorPrefixes = [
        "Google ",
        "Microsoft ",
        "Adobe ",
        "Apple ",
    ]

    /// The name as it should appear in the list.
    ///
    /// The vendor is the least useful word on the row: it is the same for every
    /// window of that application, it is usually the widest thing on the line, and
    /// nobody is choosing between two browsers by their publisher. Dropping it
    /// leaves the word people actually use.
    ///
    /// Never shortens to nothing, and never to something too short to recognise —
    /// an application actually named "Google" keeps its name.
    public static func shortened(_ name: String) -> String {
        for prefix in vendorPrefixes where name.hasPrefix(prefix) {
            let remainder = String(name.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard remainder.count >= 3 else { return name }
            return remainder
        }
        return name
    }

    /// Applies the setting.
    public static func display(_ name: String, shorten: Bool) -> String {
        shorten ? shortened(name) : name
    }
}
