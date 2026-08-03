import Foundation

/// Static facts about this build, read from the bundle where available.
public enum AppInfo {
    public static let name = "OpenTab"

    /// The bundle identifier TCC grants are keyed to. Hard-coded as a fallback so
    /// the value is still correct when running the raw SwiftPM binary outside an
    /// .app bundle (as the unit tests and `swift run` do).
    public static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.htopo.opentab"

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    public static var versionDescription: String { "\(version) (\(build))" }

    /// True when running from an assembled .app rather than `swift run`.
    public static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// `~/Library/Application Support/OpenTab`, created on first access.
    public static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
