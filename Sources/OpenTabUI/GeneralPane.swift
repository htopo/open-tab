import AppKit
import OpenTabCore
import SwiftUI

/// Actions the General pane needs the app to perform.
public struct GeneralPaneActions {
    public var checkForUpdates: () -> Void
    public var exportSettings: () -> Void
    public var importSettings: () -> Void
    public var resetSettings: () -> Void

    public init(checkForUpdates: @escaping () -> Void,
                exportSettings: @escaping () -> Void,
                importSettings: @escaping () -> Void,
                resetSettings: @escaping () -> Void) {
        self.checkForUpdates = checkForUpdates
        self.exportSettings = exportSettings
        self.importSettings = importSettings
        self.resetSettings = resetSettings
    }
}

/// The General pane.
public struct GeneralPane: View {

    @Binding var settings: GeneralSettings
    let actions: GeneralPaneActions
    /// Localizations this build ships, shown after "System Default".
    let availableLanguages: [(code: String, name: String)]

    @State private var showingResetConfirmation = false
    @State private var showingMenuBarWarning = false

    public init(settings: Binding<GeneralSettings>,
                availableLanguages: [(code: String, name: String)],
                actions: GeneralPaneActions) {
        self._settings = settings
        self.availableLanguages = availableLanguages
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            mainSection
            languageSection
            updatesSection
            settingsFileSection
        }
        .alert("Reset all settings?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset and Restart", role: .destructive, action: actions.resetSettings)
        } message: {
            Text("""
            Every shortcut, filter, and appearance option returns to its default, \
            and OpenTab restarts. This cannot be undone.
            """)
        }
        .alert("Hiding the menu bar icon", isPresented: $showingMenuBarWarning) {
            Button("OK") {}
        } message: {
            Text("""
            OpenTab has no Dock icon, so with the menu bar icon hidden there is no \
            visible way to reach these settings.

            To get back here, open OpenTab again from Applications — launching it \
            while it is already running opens Settings.
            """)
        }
    }

    // MARK: - Sections

    private var mainSection: some View {
        SettingsSection {
            SettingsRow("general.startAtLogin", "Start at login") {
                Toggle("", isOn: $settings.startAtLogin).labelsHidden()
            }

            SettingsRow("general.menuBarIcon", "Menubar icon") {
                HStack(spacing: 8) {
                    EnumPicker(
                        selection: $settings.menuBarIconVariant,
                        options: MenuBarIconVariant.allCases.map { ($0, $0.displayName) }
                    )
                    .disabled(!settings.showMenuBarIcon)

                    Toggle("", isOn: Binding(
                        get: { settings.showMenuBarIcon },
                        set: { newValue in
                            settings.showMenuBarIcon = newValue
                            // Turning this off removes the only visible way back
                            // into the app, so say so once rather than letting the
                            // user discover it.
                            if !newValue { showingMenuBarWarning = true }
                        }
                    ))
                    .labelsHidden()
                }
            }

            SettingsRow(
                "general.backgroundCapture",
                "Capture windows in the background",
                subtitle: GeneralSettings.backgroundCaptureExplanation
            ) {
                Toggle("", isOn: $settings.captureWindowsInBackground).labelsHidden()
            }
        }
    }

    private var languageSection: some View {
        SettingsSection {
            SettingsRow("general.language", "Language") {
                Picker("", selection: Binding(
                    get: { settings.languageCode ?? "" },
                    set: { settings.languageCode = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System Default").tag("")
                    if !availableLanguages.isEmpty {
                        Divider()
                        ForEach(availableLanguages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var updatesSection: some View {
        SettingsSection {
            SettingsRow("general.updates", "Updates policy") {
                EnumPicker(
                    selection: $settings.updatePolicy,
                    options: UpdatePolicy.allCases.map { ($0, $0.displayName) }
                )
            }

            HStack {
                Spacer()
                Button("Check for Updates Now…", action: actions.checkForUpdates)
                    .controlSize(.small)
                    .disabled(settings.updatePolicy == .never)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var settingsFileSection: some View {
        HStack(spacing: 10) {
            Button("Export Settings…", action: actions.exportSettings)
            Button("Import Settings…", action: actions.importSettings)
            Spacer()
            Button("Reset Settings and Restart…") { showingResetConfirmation = true }
        }
    }
}
