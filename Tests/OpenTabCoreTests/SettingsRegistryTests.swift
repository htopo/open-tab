import Testing
@testable import OpenTabCore

/// The settings search index.
///
/// The search field spans four panes and roughly sixty controls, and it is a
/// lookup over this registry rather than a hand-maintained list of special cases —
/// which is the only way it stays correct as controls are added.
@Suite("Settings registry")
struct SettingsRegistryTests {

    // MARK: - Integrity

    /// Ids are used to scroll to and highlight a control, so a duplicate would
    /// silently send a search result to the wrong place.
    @Test("Setting ids are unique")
    func idsAreUnique() {
        let ids = SettingsRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count, "Duplicate setting id in the registry")
    }

    @Test("Every setting has a title and a section")
    func descriptorsAreComplete() {
        for descriptor in SettingsRegistry.all {
            #expect(!descriptor.id.isEmpty)
            #expect(!descriptor.title.isEmpty, "\(descriptor.id) has no title")
            #expect(!descriptor.section.isEmpty, "\(descriptor.id) has no section")
        }
    }

    @Test("Every pane has registered settings")
    func everyPaneIsRepresented() {
        for pane in SettingsPane.allCases {
            let count = SettingsRegistry.all.filter { $0.pane == pane }.count
            #expect(count > 0, "\(pane.displayName) has no registered settings")
        }
    }

    @Test("A descriptor can be looked up by id")
    func lookupByID() {
        #expect(SettingsRegistry.descriptor(id: "appearance.style")?.title == "Style")
        #expect(SettingsRegistry.descriptor(id: "nope.not.real") == nil)
    }

    // MARK: - Search

    @Test("An empty query returns nothing")
    func emptyQueryReturnsNothing() {
        #expect(SettingsRegistry.search("").isEmpty)
        #expect(SettingsRegistry.search("   ").isEmpty)
    }

    @Test("A title match is found")
    func titleMatch() {
        let results = SettingsRegistry.search("theme")
        #expect(results.contains { $0.id == "appearance.theme" })
    }

    /// Someone typing "theme" wants the Theme control, not every setting that
    /// happens to mention colour.
    @Test("A title match outranks a keyword match")
    func titleOutranksKeyword() {
        let results = SettingsRegistry.search("theme")
        #expect(results.first?.id == "appearance.theme")
    }

    @Test("Search is case insensitive")
    func caseInsensitive() {
        #expect(SettingsRegistry.search("THEME").contains { $0.id == "appearance.theme" })
        #expect(SettingsRegistry.search("Theme").contains { $0.id == "appearance.theme" })
    }

    /// Keywords deliberately include the words users reach for rather than the
    /// words the UI uses.
    @Test("Keywords find settings whose titles do not contain the term")
    func keywordMatch() {
        #expect(SettingsRegistry.search("delay").contains { $0.id == "controls.additional.holdThreshold" })
        #expect(SettingsRegistry.search("purple").contains { $0.id == "general.backgroundCapture" })
        #expect(SettingsRegistry.search("vm").contains { $0.id == "exceptions.ignoreShortcuts" })
        #expect(SettingsRegistry.search("transparency").contains { $0.id == "appearance.advanced.opacity" })
    }

    /// The recovery path someone reaches for when their ⌘Tab is broken has to be
    /// findable by the words they would actually type.
    @Test("Recovery terms find the restore control")
    func recoveryIsFindable() {
        for term in ["restore", "broken", "repair", "system switcher"] {
            #expect(
                SettingsRegistry.search(term).contains { $0.id == "controls.active.restoreSystem" },
                "\"\(term)\" should find the restore control"
            )
        }
    }

    /// A second word must narrow the result set rather than widening it.
    @Test("Every term must match")
    func allTermsRequired() {
        let broad = SettingsRegistry.search("show")
        let narrow = SettingsRegistry.search("show minimized")

        #expect(narrow.count < broad.count)
        #expect(narrow.contains { $0.id == "controls.filter.minimized" })
    }

    @Test("A nonsense query returns nothing")
    func noMatch() {
        #expect(SettingsRegistry.search("zzzzqqq").isEmpty)
    }

    @Test("Search spans every pane")
    func searchCrossesPanes() {
        // "size" appears in Appearance; "bundle" in Exceptions.
        #expect(SettingsRegistry.search("size").contains { $0.pane == .appearance })
        #expect(SettingsRegistry.search("bundle").contains { $0.pane == .exceptions })
        #expect(SettingsRegistry.search("login").contains { $0.pane == .general })
        #expect(SettingsRegistry.search("trigger").contains { $0.pane == .controls })
    }

    @Test("Results are ordered deterministically")
    func resultsAreStable() {
        #expect(SettingsRegistry.search("show").map(\.id) == SettingsRegistry.search("show").map(\.id))
    }
}
