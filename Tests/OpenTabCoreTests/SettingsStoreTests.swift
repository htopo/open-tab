import Foundation
import Testing
@testable import OpenTabCore

/// Persistence, migration, and recovery.
///
/// Every failure path here has to end in usable settings. An app that will not
/// launch because its preferences file is malformed is a worse outcome than one
/// that starts fresh, so nothing in this area is allowed to throw its way out.
@Suite("Settings store")
@MainActor
struct SettingsStoreTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opentab-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try json.data(using: .utf8)!.write(to: url)
    }

    // MARK: - Round trip

    @Test("Settings survive an encode/decode round trip")
    func roundTrip() throws {
        var original = Settings.default
        original.appearance.style = .titles
        original.appearance.size = .large
        original.interaction.holdThresholdMS = 275
        original.general.startAtLogin = false
        original.shortcuts[0].filter.minimized = .hide

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded == original)
    }

    @Test("Saving and reloading preserves everything")
    func saveAndReload() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SettingsStore(fileURL: url)
        store.settings.appearance.theme = .dark
        store.settings.shortcuts[1].ordering.ordering = .alphabeticalByApp
        store.flush()

        let reloaded = SettingsStore(fileURL: url)
        #expect(reloaded.settings.appearance.theme == .dark)
        #expect(reloaded.settings.shortcuts[1].ordering.ordering == .alphabeticalByApp)
    }

    @Test("A missing file yields defaults")
    func missingFileYieldsDefaults() {
        let store = SettingsStore(fileURL: temporaryURL())
        #expect(store.settings == Settings.default)
    }

    // MARK: - Corruption

    /// The file is documented as hand-editable, so a truncated or mistyped one is
    /// a realistic state, not a hypothetical.
    @Test("A corrupt file falls back to defaults and is backed up")
    func corruptFileRecovers() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try write("{ this is not json", to: url)

        let store = SettingsStore(fileURL: url)
        #expect(store.settings == Settings.default)

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        #expect(siblings.contains { $0.contains("corrupt") },
                "The unreadable file should be preserved for manual recovery")
    }

    @Test("An empty file falls back to defaults")
    func emptyFileRecovers() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try write("", to: url)
        #expect(SettingsStore(fileURL: url).settings == Settings.default)
    }

    /// Losing nine configured shortcuts because one boolean went missing is not
    /// acceptable, so every field decodes leniently.
    @Test("A partial file keeps what it has and defaults the rest")
    func partialFileIsTolerated() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try write("""
        {
          "schemaVersion": 1,
          "appearance": { "style": "titles" }
        }
        """, to: url)

        let store = SettingsStore(fileURL: url)
        #expect(store.settings.appearance.style == .titles)
        // Unspecified fields fall back rather than taking the whole document down.
        #expect(store.settings.interaction == .default)
        #expect(store.settings.shortcuts.count == 2)
        #expect(store.settings.general == .default)
    }

    // MARK: - Versioning

    /// A future document may have changed the *meaning* of a field, not just
    /// added ones, so decoding it as if it were current could produce settings
    /// that are wrong rather than merely incomplete.
    @Test("A future schema version is backed up and replaced with defaults")
    func futureVersionIsRejected() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try write("""
        {
          "schemaVersion": 9999,
          "appearance": { "style": "titles" }
        }
        """, to: url)

        let store = SettingsStore(fileURL: url)
        #expect(store.settings == Settings.default)
        #expect(store.settings.appearance.style != .titles)

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        #expect(siblings.contains { $0.contains("future-version") })
    }

    @Test("A current-version document loads normally")
    func currentVersionLoads() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SettingsStore(fileURL: url)
        store.settings.appearance.size = .large
        store.flush()

        #expect(SettingsStore(fileURL: url).settings.schemaVersion == Settings.currentSchemaVersion)
        #expect(SettingsStore(fileURL: url).settings.appearance.size == .large)
    }

    @Test("Migration stamps the current version")
    func migrationSetsCurrentVersion() {
        var old = Settings.default
        old.schemaVersion = 0

        let migrated = SettingsMigrator.migrate(old, from: 0)
        #expect(migrated.schemaVersion == Settings.currentSchemaVersion)
    }

    @Test("Migrating a current document changes nothing")
    func migratingCurrentIsIdentity() {
        let current = Settings.default
        #expect(SettingsMigrator.migrate(current, from: Settings.currentSchemaVersion) == current)
    }

    // MARK: - Validation

    /// The file is hand-editable, so a typo must not be able to produce an
    /// unusable app — a 60-second hold threshold would look like a hang.
    @Test("Out-of-range values are clamped")
    func validationClampsValues() {
        var settings = Settings.default
        settings.interaction.holdThresholdMS = 999_999
        settings.appearance.advanced.maxRows = 0
        settings.appearance.advanced.maxColumns = -5
        settings.appearance.advanced.panelOpacity = 4.2
        settings.appearance.advanced.titleFontSize = 400
        settings.gesture.fingerCount = 11

        let validated = settings.validated()

        #expect(validated.interaction.holdThresholdMS <= 2000)
        #expect(validated.appearance.advanced.maxRows >= 1)
        #expect(validated.appearance.advanced.maxColumns >= 1)
        #expect(validated.appearance.advanced.panelOpacity <= 1.0)
        #expect(validated.appearance.advanced.titleFontSize <= 24)
        #expect((3...4).contains(validated.gesture.fingerCount))
    }

    /// The event tap is driven by this list, so an empty one would mean no way to
    /// open the switcher at all.
    @Test("An empty shortcut list is repopulated")
    func emptyShortcutListIsRepaired() {
        var settings = Settings.default
        settings.shortcuts = []

        #expect(!settings.validated().shortcuts.isEmpty)
    }

    @Test("Too many shortcuts are truncated to the maximum")
    func excessShortcutsAreTruncated() {
        var settings = Settings.default
        settings.shortcuts = (0..<40).map {
            Shortcut(name: "Shortcut \($0)", combo: .commandTab)
        }

        #expect(settings.validated().shortcuts.count == Shortcut.maximumCount)
    }

    /// A second rule for one bundle ID would be unreachable and the UI confusing.
    @Test("Duplicate exception rules are collapsed")
    func duplicateExceptionsAreRemoved() {
        var settings = Settings.default
        settings.exceptions = [
            ExceptionRule(bundleID: "com.example.app", ignoreShortcuts: .always),
            ExceptionRule(bundleID: "com.example.app", ignoreShortcuts: .never),
            ExceptionRule(bundleID: "com.other.app"),
        ]

        let validated = settings.validated()
        #expect(validated.exceptions.count == 2)
        #expect(validated.exceptions.first?.ignoreShortcuts == .always, "The first rule should win")
    }

    @Test("Exception rules with no bundle ID are dropped")
    func emptyBundleIDsAreDropped() {
        var settings = Settings.default
        settings.exceptions = [ExceptionRule(bundleID: ""), ExceptionRule(bundleID: "com.example.app")]

        #expect(settings.validated().exceptions.count == 1)
    }

    // MARK: - Import / export

    @Test("Exported settings can be imported back")
    func exportImportRoundTrip() throws {
        let url = temporaryURL()
        let exportURL = url.deletingLastPathComponent().appendingPathComponent("exported.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let source = SettingsStore(fileURL: url)
        source.settings.appearance.style = .appIcons
        source.settings.interaction.wrapAround = false
        source.flush()
        try source.export(to: exportURL)

        let destination = SettingsStore(fileURL: temporaryURL())
        try destination.importSettings(from: exportURL)

        #expect(destination.settings.appearance.style == .appIcons)
        #expect(destination.settings.interaction.wrapAround == false)
    }

    @Test("Importing validates the incoming document")
    func importIsValidated() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opentab-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let importURL = dir.appendingPathComponent("bad.json")
        try write("""
        {
          "schemaVersion": 1,
          "interaction": { "holdThresholdMS": 500000, "mouseHoverSelects": true,
                           "clickOutsideDismisses": true, "scrollNavigates": true,
                           "escapeCancels": true, "wrapAround": true }
        }
        """, to: importURL)

        let store = SettingsStore(fileURL: temporaryURL())
        try store.importSettings(from: importURL)

        #expect(store.settings.interaction.holdThresholdMS <= 2000)
    }

    @Test("Reset returns every value to its default")
    func resetRestoresDefaults() {
        let store = SettingsStore(fileURL: temporaryURL())
        store.settings.appearance.style = .titles
        store.settings.general.startAtLogin = false

        store.resetToDefaults()

        #expect(store.settings == Settings.default)
        // Including the shipped exception rules, which are part of "defaults".
        #expect(store.settings.exceptions.count == ExceptionRule.shippedDefaults.count)
    }

    // MARK: - Change notification

    @Test("Changes are published before the debounced save")
    func changesArePublished() {
        let store = SettingsStore(fileURL: temporaryURL())

        var observed: [(Settings, Settings)] = []
        store.onChange = { old, new in observed.append((old, new)) }

        store.settings.appearance.style = .titles

        #expect(observed.count == 1)
        #expect(observed.first?.0.appearance.style == .thumbnails)
        #expect(observed.first?.1.appearance.style == .titles)
    }

    @Test("Assigning an identical value publishes nothing")
    func identicalAssignmentIsSilent() {
        let store = SettingsStore(fileURL: temporaryURL())

        var count = 0
        store.onChange = { _, _ in count += 1 }

        store.settings = store.settings

        #expect(count == 0)
    }

    // MARK: - Defaults

    @Test("Defaults ship the remote desktop exception rules")
    func defaultsIncludeShippedExceptions() {
        let bundleIDs = Set(Settings.default.exceptions.map(\.bundleID))

        for expected in [
            "com.microsoft.rdc.macos", "com.teamviewer.TeamViewer",
            "org.virtualbox.app.VirtualBoxVM", "com.parallels.desktop.console",
            "com.citrix.XenAppViewer", "com.vmware.fusion",
            "com.nicesoftware.dcvviewer", "com.realvnc.vncviewer",
        ] {
            #expect(bundleIDs.contains(expected), "Missing shipped rule for \(expected)")
        }
    }

    @Test("General defaults match the specification")
    func generalDefaults() {
        let general = GeneralSettings.default
        #expect(general.startAtLogin)
        // On, unlike the rest of the "stay out of the way" defaults: it is the
        // only visible way into Settings for an app with no Dock icon.
        #expect(general.showMenuBarIcon)
        #expect(general.captureWindowsInBackground)
        #expect(general.languageCode == nil)
        #expect(general.updatePolicy == .checkAndNotify)
    }

    @Test("The gesture ships disabled")
    func gestureShipsDisabled() {
        #expect(!GestureSettings.default.isEnabled)
    }
}
