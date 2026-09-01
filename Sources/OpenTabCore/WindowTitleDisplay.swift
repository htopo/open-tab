import Foundation

/// How much of a window's own title a row shows.
public enum WindowTitleDisplay: String, Codable, CaseIterable, Sendable {
    /// The application name alone.
    case hidden
    /// The last part of the title — usually the project, folder or profile.
    case lastComponent
    /// The title exactly as the application writes it.
    case full

    public var displayName: String {
        switch self {
        case .hidden:        "Off"
        case .lastComponent: "Last part only"
        case .full:          "Full"
        }
    }
}

/// Trimming a window title down to the part worth reading.
public enum WindowTitleFormatter {

    /// Separators applications use between the parts of a title.
    ///
    /// All three appear in practice, and which one an application picked says
    /// nothing about what it put on either side of it.
    private static let separators = [" — ", " – ", " - "]

    /// The last meaningful component of a title.
    ///
    /// Titles are written most-specific-first: an editor names the file, then the
    /// project; a browser names the page, then itself, then the profile. The tail
    /// is therefore the part that says *which* window this is among an
    /// application's several, while the head repeats what the row already shows in
    /// larger type.
    ///
    /// A heuristic, and honest about it. Applications that put nothing useful last
    /// will show nothing useful; that is what the Full and Off settings are for.
    ///
    /// Trailing components that merely repeat the application's name are dropped
    /// first — plenty of titles end in the app's own name, and "Notes — Notes"
    /// helps nobody.
    public static func lastComponent(of title: String, appName: String) -> String {
        var components = [title]
        for separator in separators where title.contains(separator) {
            components = title.components(separatedBy: separator)
            break
        }

        let cleaned = components
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Walk backwards past anything that just names the application again.
        let meaningful = cleaned.last { $0.caseInsensitiveCompare(appName) != .orderedSame }
        return meaningful ?? cleaned.last ?? title
    }

    /// The title as the setting asks for it, or nil when there is nothing to add.
    public static func title(
        _ title: String,
        appName: String,
        display: WindowTitleDisplay
    ) -> String? {
        guard display != .hidden, !title.isEmpty, title != appName else { return nil }

        let result = display == .full ? title : lastComponent(of: title, appName: appName)
        guard !result.isEmpty, result.caseInsensitiveCompare(appName) != .orderedSame else { return nil }
        return result
    }
}
