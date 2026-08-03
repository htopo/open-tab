import CoreGraphics
import Testing
@testable import OpenTabCore

/// Per-application exception rules.
///
/// The load-bearing case is a remote-desktop or virtual-machine client: ⌘Tab has
/// to reach the *guest* system, and OpenTab intercepting it there is both
/// surprising and very hard for a user to diagnose. That is why those rules ship
/// configured rather than waiting to be discovered.
@Suite("Exception engine")
struct ExceptionEngineTests {

    private func window(bundleID: String,
                        pid: pid_t = 100,
                        fullscreen: Bool = false) -> WindowModel {
        WindowModel(
            id: WindowID(cgWindowID: 1, pid: pid),
            appBundleID: bundleID,
            appName: bundleID,
            isFullscreen: fullscreen
        )
    }

    // MARK: - Shipped defaults

    @Test("Every specified remote-desktop client ships with a rule")
    func shippedDefaults() {
        let byID = Dictionary(
            uniqueKeysWithValues: ExceptionRule.shippedDefaults.map { ($0.bundleID, $0) }
        )

        for expected in [
            "com.microsoft.rdc.macos", "com.teamviewer.TeamViewer",
            "org.virtualbox.app.VirtualBoxVM", "com.parallels.desktop.console",
            "com.citrix.XenAppViewer", "com.vmware.fusion",
            "com.nicesoftware.dcvviewer", "com.realvnc.vncviewer",
        ] {
            let rule = byID[expected]
            #expect(rule != nil, "Missing shipped rule for \(expected)")
            #expect(rule?.ignoreShortcuts == .always, "\(expected) must pass shortcuts through")
        }
    }

    /// The shipped rules pass shortcuts through; they do not also hide windows,
    /// which would be a surprising extra behaviour nobody asked for.
    @Test("Shipped rules do not hide windows")
    func shippedRulesOnlyIgnoreShortcuts() {
        for rule in ExceptionRule.shippedDefaults {
            #expect(rule.hideWindows == .never)
        }
    }

    // MARK: - Ignore shortcuts

    @Test("Always passes shortcuts through when the app is frontmost")
    func alwaysIgnoresWhenFrontmost() {
        let rules = [ExceptionRule(bundleID: "com.vm.client", ignoreShortcuts: .always)]

        #expect(ExceptionEngine.shouldIgnoreShortcuts(
            rules: rules,
            context: .init(frontmostBundleID: "com.vm.client")
        ))
    }

    @Test("A rule has no effect when its app is not frontmost")
    func ruleOnlyAppliesWhenFrontmost() {
        let rules = [ExceptionRule(bundleID: "com.vm.client", ignoreShortcuts: .always)]

        #expect(!ExceptionEngine.shouldIgnoreShortcuts(
            rules: rules,
            context: .init(frontmostBundleID: "com.apple.Safari")
        ))
    }

    @Test("Never keeps shortcuts working")
    func neverKeepsShortcuts() {
        let rules = [ExceptionRule(bundleID: "com.example.app", ignoreShortcuts: .never)]

        #expect(!ExceptionEngine.shouldIgnoreShortcuts(
            rules: rules,
            context: .init(frontmostBundleID: "com.example.app")
        ))
    }

    @Test("When-fullscreen depends on the app actually being fullscreen")
    func fullscreenConditional() {
        let rules = [ExceptionRule(bundleID: "com.game.app", ignoreShortcuts: .whenAppIsFullscreen)]

        #expect(ExceptionEngine.shouldIgnoreShortcuts(
            rules: rules,
            context: .init(frontmostBundleID: "com.game.app",
                           fullscreenBundleIDs: ["com.game.app"])
        ))

        #expect(!ExceptionEngine.shouldIgnoreShortcuts(
            rules: rules,
            context: .init(frontmostBundleID: "com.game.app", fullscreenBundleIDs: [])
        ))
    }

    @Test("No rules means shortcuts always work")
    func noRulesMeansNoPassThrough() {
        #expect(!ExceptionEngine.shouldIgnoreShortcuts(
            rules: [],
            context: .init(frontmostBundleID: "com.example.app")
        ))
    }

    @Test("An unknown frontmost app is unaffected")
    func unknownFrontmostAppIsUnaffected() {
        #expect(!ExceptionEngine.shouldIgnoreShortcuts(
            rules: ExceptionRule.shippedDefaults,
            context: .init(frontmostBundleID: nil)
        ))
    }

    // MARK: - Hide windows

    @Test("Always hides that app's windows")
    func alwaysHidesWindows() {
        let rules = [ExceptionRule(bundleID: "com.noisy.app", hideWindows: .always)]

        #expect(ExceptionEngine.shouldHideWindow(
            window(bundleID: "com.noisy.app"), rules: rules, context: .empty
        ))
        #expect(!ExceptionEngine.shouldHideWindow(
            window(bundleID: "com.other.app"), rules: rules, context: .empty
        ))
    }

    @Test("When-not-active hides only while another app is frontmost")
    func hideWhenNotActive() {
        let rules = [ExceptionRule(bundleID: "com.helper.app", hideWindows: .whenAppIsNotActive)]
        let target = window(bundleID: "com.helper.app")

        #expect(ExceptionEngine.shouldHideWindow(
            target, rules: rules, context: .init(frontmostBundleID: "com.apple.Safari")
        ))
        #expect(!ExceptionEngine.shouldHideWindow(
            target, rules: rules, context: .init(frontmostBundleID: "com.helper.app")
        ))
    }

    @Test("Filtering removes hidden windows and keeps the rest")
    func filterRemovesHiddenWindows() {
        let rules = [ExceptionRule(bundleID: "com.noisy.app", hideWindows: .always)]
        let windows = [
            window(bundleID: "com.noisy.app", pid: 100),
            window(bundleID: "com.apple.Safari", pid: 200),
            window(bundleID: "com.noisy.app", pid: 300),
        ]

        let filtered = ExceptionEngine.filter(windows, rules: rules, context: .empty)

        #expect(filtered.count == 1)
        #expect(filtered.first?.appBundleID == "com.apple.Safari")
    }

    @Test("Filtering with no rules is a pass-through")
    func filterWithNoRulesIsIdentity() {
        let windows = [window(bundleID: "com.a"), window(bundleID: "com.b")]
        #expect(ExceptionEngine.filter(windows, rules: [], context: .empty).count == 2)
    }

    // MARK: - Matching

    /// A prefix rule for "com.microsoft" would silently cover Word, Excel, and
    /// Teams as well as Remote Desktop, which is not what anyone adding one rule
    /// intends.
    @Test("Matching is exact, not by prefix")
    func matchingIsExact() {
        let rules = [ExceptionRule(bundleID: "com.microsoft.rdc.macos", ignoreShortcuts: .always)]

        #expect(ExceptionEngine.rule(for: "com.microsoft.rdc.macos", in: rules) != nil)
        #expect(ExceptionEngine.rule(for: "com.microsoft.Word", in: rules) == nil)
        #expect(ExceptionEngine.rule(for: "com.microsoft", in: rules) == nil)
        #expect(ExceptionEngine.rule(for: "com.microsoft.rdc.macos.helper", in: rules) == nil)
    }

    @Test("An empty bundle ID matches nothing")
    func emptyBundleIDMatchesNothing() {
        let rules = [ExceptionRule(bundleID: "com.example.app")]
        #expect(ExceptionEngine.rule(for: "", in: rules) == nil)
    }

    @Test("Matching is case sensitive, as bundle identifiers are")
    func matchingIsCaseSensitive() {
        let rules = [ExceptionRule(bundleID: "com.example.App")]
        #expect(ExceptionEngine.rule(for: "com.example.App", in: rules) != nil)
        #expect(ExceptionEngine.rule(for: "com.example.app", in: rules) == nil)
    }

    // MARK: - End to end

    /// The scenario the whole feature exists for.
    @Test("A VM client frontmost passes Command-Tab through to the guest")
    func vmClientScenario() {
        let rules = ExceptionRule.shippedDefaults
        let context = ExceptionEngine.Context(frontmostBundleID: "com.parallels.desktop.console")

        #expect(ExceptionEngine.shouldIgnoreShortcuts(rules: rules, context: context))

        // And switching away restores normal behaviour immediately.
        let after = ExceptionEngine.Context(frontmostBundleID: "com.apple.Safari")
        #expect(!ExceptionEngine.shouldIgnoreShortcuts(rules: rules, context: after))
    }
}
