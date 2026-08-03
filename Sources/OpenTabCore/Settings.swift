import Foundation

/// Everything OpenTab persists, in one versioned document.
///
/// Stored as JSON rather than in `UserDefaults`: it gives Export and Import for
/// free, produces readable diffs, and can be fixed by hand when something goes
/// wrong. `UserDefaults` is still used, but only for the small crash-safety
/// record of which system hotkeys have been disabled — that one has to survive
/// a crash mid-write, which a debounced JSON file cannot promise.
public struct Settings: Codable, Equatable, Sendable {

    /// Bumped whenever the shape changes. See `SettingsMigrator`.
    public var schemaVersion: Int

    public var appearance: AppearanceSettings
    public var interaction: InteractionSettings
    public var actionShortcuts: ActionShortcuts
    public var shortcuts: [Shortcut]
    public var general: GeneralSettings
    public var exceptions: [ExceptionRule]
    public var gesture: GestureSettings

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        appearance: AppearanceSettings = .default,
        interaction: InteractionSettings = .default,
        actionShortcuts: ActionShortcuts = .default,
        shortcuts: [Shortcut] = Shortcut.defaults(),
        general: GeneralSettings = .default,
        exceptions: [ExceptionRule] = ExceptionRule.shippedDefaults,
        gesture: GestureSettings = .default
    ) {
        self.schemaVersion = schemaVersion
        self.appearance = appearance
        self.interaction = interaction
        self.actionShortcuts = actionShortcuts
        self.shortcuts = shortcuts
        self.general = general
        self.exceptions = exceptions
        self.gesture = gesture
    }

    public static let currentSchemaVersion = 1

    public static let `default` = Settings()

    // MARK: - Decoding

    /// Every field is decoded leniently.
    ///
    /// A settings file that has lost one key — hand-edited, partially written,
    /// carried over from a build that did not have that field yet — must load with
    /// a default in its place rather than throwing the whole document away. Losing
    /// nine configured shortcuts because one boolean went missing is not an
    /// acceptable failure.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion))
            ?? Settings.currentSchemaVersion
        appearance = (try? container.decode(AppearanceSettings.self, forKey: .appearance)) ?? .default
        interaction = (try? container.decode(InteractionSettings.self, forKey: .interaction)) ?? .default
        actionShortcuts = (try? container.decode(ActionShortcuts.self, forKey: .actionShortcuts)) ?? .default
        shortcuts = (try? container.decode([Shortcut].self, forKey: .shortcuts)) ?? Shortcut.defaults()
        general = (try? container.decode(GeneralSettings.self, forKey: .general)) ?? .default
        exceptions = (try? container.decode([ExceptionRule].self, forKey: .exceptions))
            ?? ExceptionRule.shippedDefaults
        gesture = (try? container.decode(GestureSettings.self, forKey: .gesture)) ?? .default
    }

    // MARK: - Validation

    /// Brings obviously wrong values back into range.
    ///
    /// Applied after loading, because the file is documented as hand-editable and
    /// a typo should not be able to produce an unusable app — a hold threshold of
    /// 60 seconds would make the switcher look broken.
    public func validated() -> Settings {
        var result = self

        result.interaction.holdThresholdMS = min(max(result.interaction.holdThresholdMS, 0), 2000)
        result.appearance.advanced.maxRows = min(max(result.appearance.advanced.maxRows, 1), 20)
        result.appearance.advanced.maxColumns = min(max(result.appearance.advanced.maxColumns, 1), 20)
        result.appearance.advanced.panelOpacity = min(max(result.appearance.advanced.panelOpacity, 0.2), 1.0)
        result.appearance.advanced.cornerRadius = min(max(result.appearance.advanced.cornerRadius, 0), 40)
        result.appearance.advanced.cellPadding = min(max(result.appearance.advanced.cellPadding, 0), 40)
        result.appearance.advanced.titleFontSize = min(max(result.appearance.advanced.titleFontSize, 8), 24)
        result.appearance.animations.fadeInDuration = min(max(result.appearance.animations.fadeInDuration, 0), 2)
        result.appearance.animations.fadeOutDuration = min(max(result.appearance.animations.fadeOutDuration, 0), 2)
        result.gesture.fingerCount = min(max(result.gesture.fingerCount, 3), 4)

        // The shortcut list drives an index-addressed UI, so it must never be
        // empty and never exceed the documented maximum.
        if result.shortcuts.isEmpty {
            result.shortcuts = Shortcut.defaults()
        } else if result.shortcuts.count > Shortcut.maximumCount {
            result.shortcuts = Array(result.shortcuts.prefix(Shortcut.maximumCount))
        }

        // Two rules for one bundle ID would make the second unreachable and the UI
        // confusing; the first wins.
        var seenBundleIDs = Set<String>()
        result.exceptions = result.exceptions.filter { rule in
            guard !rule.bundleID.isEmpty else { return false }
            return seenBundleIDs.insert(rule.bundleID).inserted
        }

        return result
    }
}
