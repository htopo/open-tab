import AppKit
import OpenTabCore
import SwiftUI

/// The Controls pane: the shortcut list and everything configured per shortcut.
public struct ControlsPane: View {

    @Binding var shortcuts: [Shortcut]
    @Binding var interaction: InteractionSettings
    @Binding var actionShortcuts: ActionShortcuts
    @Binding var gesture: GestureSettings

    let symbolicHotkeysSupported: Bool
    let onRestoreSystemShortcuts: () -> Void

    @State private var selectedShortcutID: UUID?
    @State private var selectedTab: Tab = .filtering
    @State private var isGestureSelected = false
    @State private var showingAdditional = false
    @State private var showingActiveShortcuts = false
    @State private var showingRestoreConfirmation = false

    private enum Tab: String, CaseIterable {
        case filtering = "Filtering"
        case appearance = "Appearance"
        case ordering = "Ordering & Grouping"
    }

    public init(shortcuts: Binding<[Shortcut]>,
                interaction: Binding<InteractionSettings>,
                actionShortcuts: Binding<ActionShortcuts>,
                gesture: Binding<GestureSettings>,
                symbolicHotkeysSupported: Bool,
                onRestoreSystemShortcuts: @escaping () -> Void) {
        self._shortcuts = shortcuts
        self._interaction = interaction
        self._actionShortcuts = actionShortcuts
        self._gesture = gesture
        self.symbolicHotkeysSupported = symbolicHotkeysSupported
        self.onRestoreSystemShortcuts = onRestoreSystemShortcuts
    }

    private var selectedIndex: Int? {
        guard let selectedShortcutID else { return shortcuts.isEmpty ? nil : 0 }
        return shortcuts.firstIndex { $0.id == selectedShortcutID }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                shortcutList
                    .frame(width: 200)

                detailColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Additional controls…") { showingAdditional = true }
                Button("Shortcuts when active…") { showingActiveShortcuts = true }
                Spacer()
            }

            systemShortcutsSection
        }
        .onAppear {
            if selectedShortcutID == nil { selectedShortcutID = shortcuts.first?.id }
        }
        .sheet(isPresented: $showingAdditional) {
            AdditionalControlsSheet(interaction: $interaction) { showingAdditional = false }
        }
        .sheet(isPresented: $showingActiveShortcuts) {
            ActiveShortcutsSheet(shortcuts: $actionShortcuts) { showingActiveShortcuts = false }
        }
        .alert("Restore system shortcuts?", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restore") { onRestoreSystemShortcuts() }
        } message: {
            Text("""
            Re-enables ⌘Tab, ⌘⇧Tab, and ⌘` in macOS, whether or not OpenTab \
            believes it disabled them.

            Use this if the system switcher has stopped working. Any OpenTab \
            shortcut bound to one of those combinations will then compete with it \
            until you rebind it.
            """)
        }
    }

    // MARK: - Shortcut list

    private var shortcutList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    shortcutRow(index: index, shortcut: shortcut)
                }

                gestureRow
            }
            .padding(4)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Button {
                    addShortcut()
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .disabled(shortcuts.count >= Shortcut.maximumCount)
                .help(shortcuts.count >= Shortcut.maximumCount
                      ? "Up to \(Shortcut.maximumCount) shortcuts"
                      : "Add a shortcut")

                Button {
                    removeSelectedShortcut()
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                // The event tap is driven by this list, so an empty one would mean
                // no way to open the switcher at all.
                .disabled(shortcuts.count <= 1 || isGestureSelected)
                .help(shortcuts.count <= 1 ? "At least one shortcut is required" : "Remove")

                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 6)
        }
    }

    private func shortcutRow(index: Int, shortcut: Shortcut) -> some View {
        let isSelected = !isGestureSelected && selectedShortcutID == shortcut.id

        return Button {
            selectedShortcutID = shortcut.id
            isGestureSelected = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text(shortcut.combo.displayString)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.tertiaryLabel)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var gestureRow: some View {
        Button {
            isGestureSelected = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gesture")
                        .font(.system(size: 12, weight: .semibold))
                    Text(gesture.isEnabled ? "\(gesture.fingerCount)-finger swipe" : "Disabled")
                        .font(.system(size: 11))
                        .foregroundStyle(isGestureSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isGestureSelected ? Color.white.opacity(0.7) : Color.tertiaryLabel)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isGestureSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isGestureSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailColumn: some View {
        if isGestureSelected {
            GestureDetail(gesture: $gesture)
        } else if let index = selectedIndex, shortcuts.indices.contains(index) {
            shortcutDetail(index: index)
        } else {
            Text("Select a shortcut")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        }
    }

    private func shortcutDetail(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            triggerRow(index: index)
            reservedShortcutNotice(index: index)

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch selectedTab {
            case .filtering:
                FilteringTab(filter: $shortcuts[index].filter)
            case .appearance:
                ShortcutAppearanceTab(override: $shortcuts[index].appearance)
            case .ordering:
                OrderingTab(ordering: $shortcuts[index].ordering)
            }
        }
    }

    private func triggerRow(index: Int) -> some View {
        SettingsSection {
            SettingsRow("controls.trigger", "Trigger") {
                HStack(spacing: 8) {
                    Text("Hold")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ShortcutRecorderField(combo: $shortcuts[index].combo, mode: .modifiers)
                    Text("and press")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ShortcutRecorderField(combo: $shortcuts[index].combo, mode: .key)
                }
            }
        }
    }

    /// Warns when a binding needs a capability this system does not have.
    @ViewBuilder
    private func reservedShortcutNotice(index: Int) -> some View {
        let combo = shortcuts[index].combo

        if !combo.isUsableAsHoldShortcut {
            NoticeBox(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                text: """
                This shortcut has no modifier to hold, so the switcher cannot stay \
                open while you cycle. Add ⌘, ⌥, ⌃, or ⇧.
                """
            )
        } else if isReserved(combo) && !symbolicHotkeysSupported {
            NoticeBox(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                text: """
                macOS reserves this combination and OpenTab cannot free it on this \
                version, so the built-in switcher will appear too. ⌥Tab is a good \
                alternative.
                """
            )
        }
    }

    private func isReserved(_ combo: KeyCombo) -> Bool {
        // Mirrors the reserved table in OpenTabInput without depending on it —
        // OpenTabUI has no business importing the input layer.
        let tab = UInt16(0x30), backtick = UInt16(0x32)
        return (combo.keyCode == tab || combo.keyCode == backtick)
            && combo.modifiers.subtracting(.shift) == .command
    }

    private var systemShortcutsSection: some View {
        SettingsSection("System shortcuts") {
            SettingsRow(
                "controls.active.restoreSystem",
                "Restore system shortcuts",
                subtitle: """
                Re-enables macOS's own ⌘Tab, ⌘⇧Tab, and ⌘`. Use this if the system \
                switcher has stopped working.
                """
            ) {
                Button("Restore…") { showingRestoreConfirmation = true }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Mutation

    private func addShortcut() {
        guard shortcuts.count < Shortcut.maximumCount else { return }
        let new = Shortcut(
            name: "Shortcut \(shortcuts.count + 1)",
            combo: KeyCombo(keyCode: UInt16(0x30), modifiers: [.control])
        )
        shortcuts.append(new)
        selectedShortcutID = new.id
        isGestureSelected = false
    }

    private func removeSelectedShortcut() {
        guard shortcuts.count > 1, let index = selectedIndex else { return }
        shortcuts.remove(at: index)
        selectedShortcutID = shortcuts[min(index, shortcuts.count - 1)].id
    }
}

// MARK: - Tabs

struct FilteringTab: View {
    @Binding var filter: FilterSettings

    var body: some View {
        SettingsSection {
            SettingsRow("controls.filter.apps", "Show windows from applications") {
                EnumPicker(selection: $filter.apps,
                           options: AppScope.allCases.map { ($0, $0.displayName) })
            }
            SettingsRow("controls.filter.spaces", "Show windows from Spaces") {
                EnumPicker(selection: $filter.spaces,
                           options: SpaceScope.allCases.map { ($0, $0.displayName) })
            }
            SettingsRow("controls.filter.screens", "Show windows from screens") {
                EnumPicker(selection: $filter.screens,
                           options: ScreenScope.allCases.map { ($0, $0.displayName) })
            }
            SettingsRow("controls.filter.minimized", "Show minimized windows") {
                EnumPicker(selection: $filter.minimized,
                           options: VisibilityPolicy.allCases.map { ($0, $0.displayName) })
            }
            SettingsRow("controls.filter.hidden", "Show hidden windows") {
                EnumPicker(selection: $filter.hidden,
                           options: VisibilityPolicy.allCases.map { ($0, $0.displayName) })
            }
            SettingsRow("controls.filter.fullscreen", "Show fullscreen windows") {
                EnumPicker(selection: $filter.fullscreen,
                           options: VisibilityPolicy.allCases.map { ($0, $0.displayName) })
            }
            SettingsRow("controls.filter.noWindows", "Show apps with no open window") {
                EnumPicker(selection: $filter.appsWithNoWindows,
                           options: VisibilityPolicy.allCases.map { ($0, $0.displayName) })
            }
        }
    }
}

/// Per-shortcut appearance overrides. "Use global" is nil rather than a duplicate
/// of the current global value, so a later change to the global setting still
/// flows through.
struct ShortcutAppearanceTab: View {
    @Binding var override: AppearanceOverride?

    private var current: AppearanceOverride { override ?? AppearanceOverride() }

    var body: some View {
        SettingsSection {
            SettingsRow("controls.appearanceOverride", "Style") {
                Picker("", selection: styleBinding) {
                    Text("Use global").tag(SwitcherStyle?.none)
                    Divider()
                    ForEach(SwitcherStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(SwitcherStyle?.some(style))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("controls.appearanceOverride.size", "Size") {
                Picker("", selection: sizeBinding) {
                    Text("Use global").tag(SwitcherSize?.none)
                    Divider()
                    ForEach(SwitcherSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(SwitcherSize?.some(size))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("controls.appearanceOverride.theme", "Theme") {
                Picker("", selection: themeBinding) {
                    Text("Use global").tag(SwitcherTheme?.none)
                    Divider()
                    ForEach(SwitcherTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(SwitcherTheme?.some(theme))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// Writes one field of the override, collapsing it back to nil once every
    /// field is "use global" — so a shortcut with no overrides stays that way and
    /// keeps tracking later changes to the global settings.
    private func binding<Value>(
        _ keyPath: WritableKeyPath<AppearanceOverride, Value?>
    ) -> Binding<Value?> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                var next = current
                next[keyPath: keyPath] = newValue
                override = next.isEmpty ? nil : next
            }
        )
    }

    private var styleBinding: Binding<SwitcherStyle?> { binding(\.style) }
    private var sizeBinding: Binding<SwitcherSize?> { binding(\.size) }
    private var themeBinding: Binding<SwitcherTheme?> { binding(\.theme) }
}

struct OrderingTab: View {
    @Binding var ordering: OrderingSettings

    var body: some View {
        SettingsSection {
            SettingsRow("controls.ordering.order", "Order") {
                EnumPicker(selection: $ordering.ordering,
                           options: WindowOrdering.allCases.map { ($0, $0.displayName) })
            }
            SettingsRow("controls.ordering.group", "Group windows by application") {
                Toggle("", isOn: $ordering.groupByApplication).labelsHidden()
            }
            SettingsRow("controls.ordering.activeFirst", "Put the active window first") {
                Toggle("", isOn: $ordering.activeWindowFirst).labelsHidden()
            }
        }
    }
}

// MARK: - Gesture

struct GestureDetail: View {
    @Binding var gesture: GestureSettings

    var body: some View {
        SettingsSection {
            SettingsRow(
                "controls.gesture",
                "Trackpad gesture",
                subtitle: "Swipe with three or four fingers to open the switcher."
            ) {
                Toggle("", isOn: $gesture.isEnabled).labelsHidden()
            }
            SettingsRow("controls.gesture.fingers", "Fingers") {
                Picker("", selection: $gesture.fingerCount) {
                    Text("Three").tag(3)
                    Text("Four").tag(4)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!gesture.isEnabled)
            }
        }
    }
}

// MARK: - Sheets

struct AdditionalControlsSheet: View {
    @Binding var interaction: InteractionSettings
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Additional Controls")
                .font(.system(size: 16, weight: .semibold))

            SettingsSection {
                SettingsRow(
                    "controls.additional.holdThreshold",
                    "Hold threshold",
                    subtitle: """
                    How long to hold before the switcher appears. A quicker tap \
                    swaps straight to your previous window with no panel.
                    """
                ) {
                    LabelledSlider(
                        value: Binding(
                            get: { Double(interaction.holdThresholdMS) },
                            set: { interaction.holdThresholdMS = Int($0.rounded()) }
                        ),
                        range: 0...600,
                        step: 10
                    ) { String(format: "%.0f ms", $0) }
                }
                SettingsRow("controls.additional.hover", "Mouse hover selects") {
                    Toggle("", isOn: $interaction.mouseHoverSelects).labelsHidden()
                }
                SettingsRow("controls.additional.clickOutside", "Click outside to dismiss") {
                    Toggle("", isOn: $interaction.clickOutsideDismisses).labelsHidden()
                }
                SettingsRow("controls.additional.scroll", "Scroll to navigate") {
                    Toggle("", isOn: $interaction.scrollNavigates).labelsHidden()
                }
                SettingsRow("controls.additional.escape", "Escape cancels") {
                    Toggle("", isOn: $interaction.escapeCancels).labelsHidden()
                }
                SettingsRow("controls.additional.wrap", "Wrap around at the ends") {
                    Toggle("", isOn: $interaction.wrapAround).labelsHidden()
                }
            }

            HStack {
                Button("Reset to Defaults") { interaction = .default }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// The "Shortcuts when active…" sheet.
struct ActiveShortcutsSheet: View {
    @Binding var shortcuts: ActionShortcuts
    let onDone: () -> Void

    private static let order: [SwitcherAction] = [
        .closeWindow, .minimizeWindow, .quitApp, .hideApp,
        .toggleFullscreen, .selectNext, .selectPrevious,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts When Active")
                    .font(.system(size: 16, weight: .semibold))
                Text("""
                These work only while the switcher is on screen. At any other time \
                they belong to whichever app is frontmost.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection {
                ForEach(Self.order, id: \.self) { action in
                    if let binding = shortcuts.bindings[action] {
                        SettingsRow("controls.active.\(action.rawValue)", action.displayName) {
                            HStack(spacing: 8) {
                                ShortcutRecorderField(
                                    combo: comboBinding(for: action, fallback: binding.combo),
                                    mode: .modifiers
                                )
                                ShortcutRecorderField(
                                    combo: comboBinding(for: action, fallback: binding.combo),
                                    mode: .key
                                )
                                Toggle("", isOn: enabledBinding(for: action))
                                    .labelsHidden()
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Reset to Defaults") { shortcuts = .default }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func comboBinding(for action: SwitcherAction, fallback: KeyCombo) -> Binding<KeyCombo> {
        Binding(
            get: { shortcuts.bindings[action]?.combo ?? fallback },
            set: { shortcuts.bindings[action]?.combo = $0 }
        )
    }

    private func enabledBinding(for action: SwitcherAction) -> Binding<Bool> {
        Binding(
            get: { shortcuts.bindings[action]?.isEnabled ?? false },
            set: { shortcuts.bindings[action]?.isEnabled = $0 }
        )
    }
}

// MARK: - Shared

/// Inline warning box.
struct NoticeBox: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

extension Color {
    static var tertiaryLabel: Color { Color(nsColor: .tertiaryLabelColor) }
}
