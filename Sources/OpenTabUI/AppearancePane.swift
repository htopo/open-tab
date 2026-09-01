import AppKit
import OpenTabCore
import SwiftUI

/// The Appearance pane.
public struct AppearancePane: View {

    @Binding var settings: AppearanceSettings

    /// Screen Recording state, which decides whether the Thumbnails style is
    /// selectable. Never hides the option — it explains why it is unavailable and
    /// offers to fix it, because silently removing a feature reads as a bug.
    let screenRecordingGranted: Bool
    let onGrantScreenRecording: () -> Void

    /// Connected display names, appended to the "Show on" options.
    let displayNames: [String]

    @State private var showingAnimations = false
    @State private var showingAdvanced = false

    public init(settings: Binding<AppearanceSettings>,
                screenRecordingGranted: Bool,
                displayNames: [String],
                onGrantScreenRecording: @escaping () -> Void) {
        self._settings = settings
        self.screenRecordingGranted = screenRecordingGranted
        self.displayNames = displayNames
        self.onGrantScreenRecording = onGrantScreenRecording
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            styleSection
            appearanceSection
            multipleScreensSection

            HStack {
                Spacer()
                Button("Animations…") { showingAnimations = true }
            }
        }
        .sheet(isPresented: $showingAnimations) {
            AnimationsSheet(settings: $settings.animations) { showingAnimations = false }
        }
        .sheet(isPresented: $showingAdvanced) {
            AdvancedAppearanceSheet(settings: $settings.advanced) { showingAdvanced = false }
        }
    }

    // MARK: - Sections

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Style")
                .font(.system(size: 15, weight: .semibold))
                .padding(.leading, 2)

            StylePicker(
                style: $settings.style,
                disabledStyles: screenRecordingGranted ? [] : [.thumbnails],
                disabledExplanation: screenRecordingGranted
                    ? nil
                    : "Thumbnails need Screen Recording access. Everything else works without it."
            )
            .id("appearance.style")

            if !screenRecordingGranted {
                Button("Grant Screen Recording Access…", action: onGrantScreenRecording)
                    .controlSize(.small)
            }
        }
    }

    private var appearanceSection: some View {
        SettingsSection {
            SettingsRow("appearance.size", "Size") {
                EnumPicker(
                    selection: $settings.size,
                    options: SwitcherSize.allCases.map { ($0, $0.displayName) }
                )
            }
            SettingsRow("appearance.theme", "Theme") {
                EnumPicker(
                    selection: $settings.theme,
                    options: SwitcherTheme.allCases.map { ($0, $0.displayName) }
                )
            }
            SettingsRow("appearance.afterRelease", "After keys are released") {
                EnumPicker(
                    selection: $settings.afterRelease,
                    options: AfterReleaseBehavior.allCases.map { ($0, $0.displayName) }
                )
            }
            SettingsRow(
                "appearance.previewSelected",
                "Preview selected window",
                subtitle: "Highlights the selected window on screen behind the switcher."
            ) {
                Toggle("", isOn: $settings.previewSelectedWindow).labelsHidden()
            }

            HStack {
                Spacer()
                Button("Customize more…") { showingAdvanced = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var multipleScreensSection: some View {
        SettingsSection("Multiple screens") {
            SettingsRow("appearance.showOn", "Show on") {
                Picker("", selection: $settings.screenPlacement) {
                    ForEach(ScreenPlacement.standardCases, id: \.self) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                    if !displayNames.isEmpty {
                        Divider()
                        ForEach(displayNames, id: \.self) { name in
                            Text(name).tag(ScreenPlacement.specificDisplay(name: name))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Animations sheet

struct AnimationsSheet: View {
    @Binding var settings: AnimationSettings
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Animations")
                .font(.system(size: 16, weight: .semibold))

            SettingsSection {
                SettingsRow("appearance.animations.fadeIn", "Fade in") {
                    LabelledSlider(value: $settings.fadeInDuration, range: 0...0.6, step: 0.01) {
                        String(format: "%.0f ms", $0 * 1000)
                    }
                }
                SettingsRow("appearance.animations.fadeOut", "Fade out") {
                    LabelledSlider(value: $settings.fadeOutDuration, range: 0...0.6, step: 0.01) {
                        String(format: "%.0f ms", $0 * 1000)
                    }
                }
                SettingsRow("appearance.animations.selectionMove", "Animate selection movement") {
                    Toggle("", isOn: $settings.animateSelectionMove).labelsHidden()
                }
                SettingsRow(
                    "appearance.animations.reduce",
                    "Reduce animations",
                    subtitle: MotionPreference.systemPrefersReducedMotion
                        ? "Already on because macOS is set to reduce motion."
                        : "Shows the switcher instantly, with no fade."
                ) {
                    Toggle("", isOn: $settings.reduceAnimations)
                        .labelsHidden()
                        .disabled(MotionPreference.systemPrefersReducedMotion)
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Customize more sheet

struct AdvancedAppearanceSheet: View {
    @Binding var settings: AdvancedAppearanceSettings
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Customize Appearance")
                .font(.system(size: 16, weight: .semibold))

            ScrollView {
                VStack(spacing: 18) {
                    SettingsSection("Layout") {
                        SettingsRow("appearance.advanced.maxRows", "Maximum rows") {
                            LabelledSlider(value: rows, range: 1...12)
                        }
                        SettingsRow("appearance.advanced.maxColumns", "Maximum columns") {
                            LabelledSlider(value: columns, range: 1...16)
                        }
                        SettingsRow("appearance.advanced.cellPadding", "Spacing between items") {
                            LabelledSlider(value: $settings.cellPadding, range: 0...24) {
                                String(format: "%.0f pt", $0)
                            }
                        }
                    }

                    SettingsSection("Panel") {
                        SettingsRow("appearance.advanced.opacity", "Opacity") {
                            LabelledSlider(value: $settings.panelOpacity, range: 0.2...1, step: 0.05) {
                                String(format: "%.0f%%", $0 * 100)
                            }
                        }
                        SettingsRow("appearance.advanced.cornerRadius", "Corner radius") {
                            LabelledSlider(value: $settings.cornerRadius, range: 0...32) {
                                String(format: "%.0f pt", $0)
                            }
                        }
                        SettingsRow("appearance.advanced.highlightStyle", "Highlight style") {
                            EnumPicker(
                                selection: $settings.highlightStyle,
                                options: HighlightStyle.allCases.map { ($0, $0.displayName) }
                            )
                        }
                    }

                    SettingsSection("Contents") {
                        SettingsRow("appearance.advanced.titleFontSize", "Title font size") {
                            LabelledSlider(value: $settings.titleFontSize, range: 8...20) {
                                String(format: "%.0f pt", $0)
                            }
                        }
                        SettingsRow(
                            "appearance.advanced.windowTitle",
                            "Show window titles",
                            subtitle: AdvancedAppearanceSettings.windowTitleExplanation
                        ) {
                            Toggle("", isOn: $settings.showWindowTitle).labelsHidden()
                        }
                        SettingsRow(
                            "appearance.advanced.shortenAppNames",
                            "Shorten application names",
                            subtitle: AdvancedAppearanceSettings.shortenNamesExplanation
                        ) {
                            Toggle("", isOn: $settings.shortenApplicationNames).labelsHidden()
                        }
                        SettingsRow("appearance.advanced.appIconBadge", "Show app icon on thumbnails") {
                            Toggle("", isOn: $settings.showAppIconBadge).labelsHidden()
                        }
                        SettingsRow("appearance.advanced.windowCountBadge", "Show window count badge") {
                            Toggle("", isOn: $settings.showWindowCountBadge).labelsHidden()
                        }
                        SettingsRow(
                            "appearance.advanced.statusBadges",
                            "Show minimized and hidden badges"
                        ) {
                            Toggle("", isOn: $settings.showStatusBadges).labelsHidden()
                        }
                    }
                }
            }
            .frame(maxHeight: 420)

            HStack {
                Button("Reset to Defaults") { settings = .default }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // Int-backed settings bridged to the Double the slider needs.
    private var rows: Binding<Double> {
        Binding(get: { Double(settings.maxRows) },
                set: { settings.maxRows = Int($0.rounded()) })
    }

    private var columns: Binding<Double> {
        Binding(get: { Double(settings.maxColumns) },
                set: { settings.maxColumns = Int($0.rounded()) })
    }
}
