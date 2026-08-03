import Foundation
import Observation

/// Loads, saves, and migrates the settings document.
///
/// Writes are debounced and atomic. Debounced because dragging a slider in the
/// settings window produces a change per frame and none of them are worth a disk
/// write; atomic because a torn write during a crash or power loss would leave a
/// file that cannot be parsed, and settings are not worth losing.
@MainActor
@Observable
public final class SettingsStore {

    /// The live settings. Assigning schedules a debounced save.
    public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            onChange?(oldValue, settings)
            scheduleSave()
        }
    }

    /// Fires on every change, before the save lands, so subsystems can react
    /// immediately rather than waiting for the debounce.
    @ObservationIgnored public var onChange: ((Settings, Settings) -> Void)?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?

    /// Long enough to coalesce a slider drag, short enough that quitting right
    /// after a change does not lose it — and `flush()` covers that case anyway.
    @ObservationIgnored private static let saveDebounce: TimeInterval = 0.5

    /// Nonisolated so it can be used as a default argument, which Swift evaluates
    /// outside the actor.
    public nonisolated static var defaultURL: URL {
        AppInfo.supportDirectory.appendingPathComponent("settings.json")
    }

    public init(fileURL: URL = SettingsStore.defaultURL) {
        self.fileURL = fileURL
        self.settings = Self.load(from: fileURL)
    }

    // MARK: - Loading

    /// Reads the document, migrating or recovering as needed.
    ///
    /// Never throws. Every failure path ends in usable settings, because an app
    /// that will not launch because its preferences are malformed is a worse
    /// outcome than one that starts fresh.
    static func load(from url: URL) -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.settings.notice("No settings file; starting from defaults")
            return .default
        }

        guard let data = try? Data(contentsOf: url) else {
            Log.settings.error("Settings file could not be read; using defaults")
            return .default
        }

        // Read the version before decoding the body. A document from a future
        // version may contain fields whose *meaning* has changed, not just fields
        // we do not know about, so decoding it as if it were current could produce
        // settings that are wrong rather than merely incomplete.
        let version = probeSchemaVersion(in: data) ?? Settings.currentSchemaVersion

        if version > Settings.currentSchemaVersion {
            Log.settings.error(
                "Settings are from a newer version (\(version) > \(Settings.currentSchemaVersion)); backing up and starting fresh"
            )
            backUp(url, reason: "future-version-\(version)")
            return .default
        }

        guard var decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            Log.settings.error("Settings file is corrupt; backing up and starting fresh")
            backUp(url, reason: "corrupt")
            return .default
        }

        if version < Settings.currentSchemaVersion {
            Log.settings.notice("Migrating settings from schema \(version) to \(Settings.currentSchemaVersion)")
            backUp(url, reason: "pre-migration-v\(version)")
            decoded = SettingsMigrator.migrate(decoded, from: version)
        }

        return decoded.validated()
    }

    /// Reads just `schemaVersion`, tolerating anything else in the document.
    private static func probeSchemaVersion(in data: Data) -> Int? {
        struct VersionProbe: Decodable { let schemaVersion: Int? }
        return (try? JSONDecoder().decode(VersionProbe.self, from: data))?.schemaVersion
    }

    /// Moves a problem file aside instead of deleting it.
    ///
    /// A user who has spent time configuring nine shortcuts should be able to
    /// recover them by hand, even when OpenTab could not.
    @discardableResult
    private static func backUp(_ url: URL, reason: String) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("settings-\(reason)-\(stamp).json")

        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            Log.settings.notice("Backed up settings to \(backupURL.lastPathComponent, privacy: .public)")
            return backupURL
        } catch {
            Log.settings.error("Could not back up settings: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: item)
    }

    /// Writes immediately, cancelling any pending debounced save.
    ///
    /// Called on quit so that a change made a moment before does not vanish.
    public func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic: a torn write here would leave an unparseable document.
            try data.write(to: fileURL, options: .atomic)

            Log.settings.debug("Settings saved")
        } catch {
            Log.settings.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Import / export / reset

    /// Writes the current settings to an arbitrary location.
    public func export(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        Log.settings.notice("Settings exported")
    }

    /// Replaces the current settings from a file.
    ///
    /// Goes through the same validation and migration as a normal load, so an
    /// imported file from an older version is upgraded rather than rejected.
    public func importSettings(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var imported = try JSONDecoder().decode(Settings.self, from: data)

        let version = Self.probeSchemaVersion(in: data) ?? Settings.currentSchemaVersion
        if version < Settings.currentSchemaVersion {
            imported = SettingsMigrator.migrate(imported, from: version)
        }

        settings = imported.validated()
        flush()
        Log.settings.notice("Settings imported")
    }

    public func resetToDefaults() {
        settings = .default
        flush()
        Log.settings.notice("Settings reset to defaults")
    }
}

/// Upgrades documents written by older versions.
///
/// Each step handles exactly one version bump, and they compose, so a document
/// from any past version reaches the present by running the chain. Nothing here
/// may throw: a migration that fails would strand a user on an old version with
/// no way forward.
public enum SettingsMigrator {

    public static func migrate(_ settings: Settings, from version: Int) -> Settings {
        var result = settings
        var current = version

        while current < Settings.currentSchemaVersion {
            result = step(result, from: current)
            current += 1
        }

        result.schemaVersion = Settings.currentSchemaVersion
        return result
    }

    private static func step(_ settings: Settings, from version: Int) -> Settings {
        switch version {
        // Version 1 is the first shipped schema, so there is nothing before it to
        // migrate from yet. Future versions add their case here; the surrounding
        // machinery — probe, back up, chain, validate — is already exercised by
        // the tests, so adding one is a one-case change.
        default:
            return settings
        }
    }
}
