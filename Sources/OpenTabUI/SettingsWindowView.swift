import AppKit
import OpenTabCore
import SwiftUI

/// Everything the settings window needs from the app.
public struct SettingsEnvironment {
    public var screenRecordingGranted: Bool
    public var displayNames: [String]
    public var availableLanguages: [(code: String, name: String)]
    public var symbolicHotkeysSupported: Bool

    public var onGrantScreenRecording: () -> Void
    public var onRestoreSystemShortcuts: () -> Void
    public var onCheckForUpdates: () -> Void
    public var onExportSettings: () -> Void
    public var onImportSettings: () -> Void
    public var onResetSettings: () -> Void
    public var onQuit: () -> Void

    public init(
        screenRecordingGranted: Bool,
        displayNames: [String],
        availableLanguages: [(code: String, name: String)],
        symbolicHotkeysSupported: Bool,
        onGrantScreenRecording: @escaping () -> Void,
        onRestoreSystemShortcuts: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onExportSettings: @escaping () -> Void,
        onImportSettings: @escaping () -> Void,
        onResetSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.screenRecordingGranted = screenRecordingGranted
        self.displayNames = displayNames
        self.availableLanguages = availableLanguages
        self.symbolicHotkeysSupported = symbolicHotkeysSupported
        self.onGrantScreenRecording = onGrantScreenRecording
        self.onRestoreSystemShortcuts = onRestoreSystemShortcuts
        self.onCheckForUpdates = onCheckForUpdates
        self.onExportSettings = onExportSettings
        self.onImportSettings = onImportSettings
        self.onResetSettings = onResetSettings
        self.onQuit = onQuit
    }
}

/// The settings window: search field and pane list on the left, content on the
/// right.
public struct SettingsWindowView: View {

    @Bindable var store: SettingsStore
    let environment: SettingsEnvironment

    @State private var selectedPane: SettingsPane = .appearance
    @State private var searchText = ""
    @State private var highlightedSettingID: String?

    public init(store: SettingsStore, environment: SettingsEnvironment) {
        self.store = store
        self.environment = environment
    }

    private var searchResults: [SettingDescriptor] {
        SettingsRegistry.search(searchText)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(.ultraThinMaterial)

            Divider()

            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if searchText.isEmpty {
                paneList
            } else {
                resultsList
            }

            Spacer(minLength: 0)

            Divider()
            Button("Quit OpenTab", action: environment.onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    private var paneList: some View {
        VStack(spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                    highlightedSettingID = nil
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: pane.symbolName)
                            .font(.system(size: 13))
                            .frame(width: 20)
                        Text(pane.displayName)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selectedPane == pane ? Color.accentColor : Color.clear)
                    )
                    .foregroundStyle(selectedPane == pane ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
    }

    /// Search results across every pane.
    ///
    /// Selecting one switches to the owning pane and highlights the control, which
    /// is why every setting carries a stable id in `SettingsRegistry`.
    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if searchResults.isEmpty {
                    Text("No settings match “\(searchText)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                } else {
                    ForEach(searchResults) { result in
                        Button {
                            selectedPane = result.pane
                            highlightedSettingID = result.id
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title)
                                    .font(.system(size: 12))
                                    .multilineTextAlignment(.leading)
                                Text("\(result.pane.displayName) › \(result.section)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(highlightedSettingID == result.id
                                          ? Color.accentColor.opacity(0.18)
                                          : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(selectedPane.displayName)
                        .font(.system(size: 22, weight: .bold))

                    paneContent
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.highlightedSettingID, highlightedSettingID)
            .onChange(of: highlightedSettingID) { _, newValue in
                guard let newValue else { return }
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .appearance:
            AppearancePane(
                settings: $store.settings.appearance,
                screenRecordingGranted: environment.screenRecordingGranted,
                displayNames: environment.displayNames,
                onGrantScreenRecording: environment.onGrantScreenRecording
            )

        case .controls:
            ControlsPane(
                shortcuts: $store.settings.shortcuts,
                interaction: $store.settings.interaction,
                actionShortcuts: $store.settings.actionShortcuts,
                gesture: $store.settings.gesture,
                symbolicHotkeysSupported: environment.symbolicHotkeysSupported,
                onRestoreSystemShortcuts: environment.onRestoreSystemShortcuts
            )

        case .general:
            GeneralPane(
                settings: $store.settings.general,
                availableLanguages: environment.availableLanguages,
                actions: GeneralPaneActions(
                    checkForUpdates: environment.onCheckForUpdates,
                    exportSettings: environment.onExportSettings,
                    importSettings: environment.onImportSettings,
                    resetSettings: environment.onResetSettings
                )
            )

        case .exceptions:
            ExceptionsPane(rules: $store.settings.exceptions)
        }
    }
}
