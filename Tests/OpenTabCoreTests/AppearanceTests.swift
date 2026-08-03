import Testing
@testable import OpenTabCore

/// Sizing and grid-shape arithmetic.
///
/// Pure functions extracted from the view layer specifically so "Auto" — which
/// depends on the window count — can be reasoned about here instead of being a
/// layout side effect only observable by looking at the screen.
@Suite("Switcher metrics and layout")
struct AppearanceTests {

    // MARK: - Fixed sizes

    @Test("Fixed sizes increase monotonically")
    func fixedSizesGrow() {
        #expect(SwitcherMetrics.small.thumbnailWidth < SwitcherMetrics.medium.thumbnailWidth)
        #expect(SwitcherMetrics.medium.thumbnailWidth < SwitcherMetrics.large.thumbnailWidth)
        #expect(SwitcherMetrics.small.iconSize < SwitcherMetrics.medium.iconSize)
        #expect(SwitcherMetrics.medium.iconSize < SwitcherMetrics.large.iconSize)
    }

    @Test("Thumbnail height follows the aspect ratio")
    func thumbnailAspectRatio() {
        for metrics in [SwitcherMetrics.small, .medium, .large, .compact] {
            let ratio = metrics.thumbnailWidth / metrics.thumbnailHeight
            #expect(abs(ratio - 16.0 / 10.0) < 0.05,
                    "Expected 16:10, got \(ratio) for width \(metrics.thumbnailWidth)")
        }
    }

    @Test("A fixed size ignores the window count", arguments: [0, 1, 5, 30, 200])
    func fixedSizeIgnoresCount(count: Int) {
        #expect(SwitcherMetrics.resolve(.small, windowCount: count) == .small)
        #expect(SwitcherMetrics.resolve(.medium, windowCount: count) == .medium)
        #expect(SwitcherMetrics.resolve(.large, windowCount: count) == .large)
    }

    // MARK: - Auto sizing

    /// Auto targets a roughly constant panel area: generous previews when few
    /// windows are open, tighter ones as the list grows.
    @Test("Auto shrinks as the window count grows")
    func autoShrinksWithCount() {
        let widths = [2, 7, 15, 40].map {
            SwitcherMetrics.resolve(.auto, windowCount: $0).thumbnailWidth
        }
        #expect(widths == widths.sorted(by: >), "Expected monotonically decreasing, got \(widths)")
    }

    @Test("Auto is bounded at both ends")
    func autoIsClamped() {
        // A single window must not fill the screen.
        #expect(SwitcherMetrics.resolve(.auto, windowCount: 1) == .large)
        // Two hundred windows must not become invisible.
        #expect(SwitcherMetrics.resolve(.auto, windowCount: 200) == .compact)
        #expect(SwitcherMetrics.resolve(.auto, windowCount: 200).thumbnailWidth >= 100)
    }

    @Test("Auto handles an empty list without collapsing")
    func autoHandlesEmptyList() {
        #expect(SwitcherMetrics.resolve(.auto, windowCount: 0).thumbnailWidth > 0)
    }

    // MARK: - Grid shape

    @Test("A small list forms a roughly square grid")
    func squarishGrid() {
        #expect(SwitcherLayout.columnCount(forItemCount: 9, maxColumns: 6, maxRows: 4) == 3)
        #expect(SwitcherLayout.columnCount(forItemCount: 4, maxColumns: 6, maxRows: 4) == 2)
    }

    @Test("Column count is capped by the maximum")
    func columnsRespectMaximum() {
        #expect(SwitcherLayout.columnCount(forItemCount: 100, maxColumns: 5, maxRows: 100) == 5)
    }

    /// A switcher that silently omits a window is worse than one that is
    /// inconveniently wide, so columns win when the two maximums conflict.
    @Test("Columns widen rather than dropping entries when rows run out")
    func columnsWidenToFitRowLimit() {
        let columns = SwitcherLayout.columnCount(forItemCount: 40, maxColumns: 6, maxRows: 4)
        let rows = SwitcherLayout.rowCount(forItemCount: 40, columns: columns)

        #expect(columns >= 10, "Expected the grid to widen past maxColumns, got \(columns)")
        #expect(rows <= 4)
        #expect(columns * rows >= 40, "Every window must have a cell")
    }

    @Test("Column count never exceeds the item count")
    func columnsNeverExceedItems() {
        #expect(SwitcherLayout.columnCount(forItemCount: 2, maxColumns: 6, maxRows: 4) == 2)
        #expect(SwitcherLayout.columnCount(forItemCount: 1, maxColumns: 6, maxRows: 4) == 1)
    }

    @Test("An empty list still reports a usable column count")
    func emptyListIsSafe() {
        #expect(SwitcherLayout.columnCount(forItemCount: 0, maxColumns: 6, maxRows: 4) == 1)
        #expect(SwitcherLayout.rowCount(forItemCount: 0, columns: 3) == 0)
    }

    /// Nonsense settings must not produce a divide-by-zero or a zero-column grid.
    @Test("Degenerate maximums are handled", arguments: [(0, 0), (0, 4), (6, 0), (-3, -3)])
    func degenerateMaximums(maxColumns: Int, maxRows: Int) {
        let columns = SwitcherLayout.columnCount(
            forItemCount: 12, maxColumns: maxColumns, maxRows: maxRows
        )
        #expect(columns >= 1)
        #expect(SwitcherLayout.rowCount(forItemCount: 12, columns: columns) >= 1)
    }

    @Test("Every window gets a cell", arguments: [1, 3, 7, 12, 25, 60])
    func everyWindowFits(count: Int) {
        let columns = SwitcherLayout.columnCount(forItemCount: count, maxColumns: 6, maxRows: 4)
        let rows = SwitcherLayout.rowCount(forItemCount: count, columns: columns)
        #expect(columns * rows >= count)
    }

    // MARK: - Per-shortcut overrides

    @Test("An absent override changes nothing")
    func nilOverrideIsIdentity() {
        let base = AppearanceSettings.default
        #expect(base.merging(nil) == base)
        #expect(base.merging(AppearanceOverride()) == base)
    }

    @Test("An override replaces only the fields it sets")
    func overrideIsPartial() {
        let base = AppearanceSettings(style: .thumbnails, size: .small, theme: .system)
        let merged = base.merging(AppearanceOverride(style: .titles))

        #expect(merged.style == .titles)
        #expect(merged.size == .small)
        #expect(merged.theme == .system)
    }

    @Test("An override can replace every field")
    func overrideCanReplaceEverything() {
        let base = AppearanceSettings(style: .thumbnails, size: .small, theme: .system)
        let merged = base.merging(
            AppearanceOverride(style: .appIcons, size: .large, theme: .dark)
        )

        #expect(merged.style == .appIcons)
        #expect(merged.size == .large)
        #expect(merged.theme == .dark)
    }

    @Test("An empty override is reported as empty")
    func emptyOverrideIsDetectable() {
        #expect(AppearanceOverride().isEmpty)
        #expect(!AppearanceOverride(size: .medium).isEmpty)
    }

    // MARK: - Defaults

    @Test("Appearance defaults match the specification")
    func appearanceDefaults() {
        let appearance = AppearanceSettings.default
        #expect(appearance.style == .thumbnails)
        #expect(appearance.size == .small)
        #expect(appearance.theme == .system)
        #expect(appearance.afterRelease == .focus)
        #expect(appearance.previewSelectedWindow == false)
        #expect(appearance.screenPlacement == .activeScreen)
    }

    @Test("Interaction defaults match the specification")
    func interactionDefaults() {
        let interaction = InteractionSettings.default
        #expect(interaction.holdThresholdMS == 150)
        #expect(interaction.holdThreshold == 0.150)
        #expect(interaction.mouseHoverSelects)
        #expect(interaction.clickOutsideDismisses)
        #expect(interaction.scrollNavigates)
        #expect(interaction.escapeCancels)
        #expect(interaction.wrapAround)
    }

    @Test("Shortcut defaults are Command-Tab and Option-backtick")
    func shortcutDefaults() {
        let shortcuts = Shortcut.defaults()
        #expect(shortcuts.count == 2)
        #expect(shortcuts[0].combo == .commandTab)
        #expect(shortcuts[1].combo == .optionBacktick)
        #expect(shortcuts.allSatisfy { $0.isEnabled })
        #expect(Shortcut.maximumCount == 9)
    }

    /// Both shipped defaults must be able to drive hold-and-cycle, which needs at
    /// least one modifier to hold.
    @Test("Default shortcuts can drive hold-and-cycle")
    func defaultsAreHoldCapable() {
        #expect(Shortcut.defaults().allSatisfy { $0.combo.isUsableAsHoldShortcut })
    }
}
