import AppKit
import OpenTabCore
import SwiftUI
import UniformTypeIdentifiers

/// The Exceptions pane: per-application rules, list on the left, editor on the
/// right.
public struct ExceptionsPane: View {

    @Binding var rules: [ExceptionRule]

    @State private var selectedRuleID: UUID?
    @State private var isShowingAppPicker = false

    public init(rules: Binding<[ExceptionRule]>) {
        self._rules = rules
    }

    private var selectedIndex: Int? {
        guard let selectedRuleID else { return nil }
        return rules.firstIndex { $0.id == selectedRuleID }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            explanation

            HStack(alignment: .top, spacing: 14) {
                ruleList
                    .frame(width: 280)

                editor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if selectedRuleID == nil { selectedRuleID = rules.first?.id }
        }
        .fileImporter(
            isPresented: $isShowingAppPicker,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false
        ) { result in
            handleAppPick(result)
        }
    }

    private var explanation: some View {
        Text("""
        Rules that change how OpenTab treats a particular application. Remote \
        desktop and virtual machine clients are configured out of the box to let \
        ⌘Tab reach the guest system.
        """)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - List

    private var ruleList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(rules) { rule in
                        ruleRow(rule)
                    }
                }
                .padding(4)
            }
            .frame(height: 340)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Menu {
                    Button("Choose Application…") { isShowingAppPicker = true }
                    Button("Enter Bundle ID Manually") { addRule(bundleID: "") }
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                .disabled(selectedIndex == nil)

                Spacer()

                Button("Restore Defaults") {
                    restoreShippedDefaults()
                }
                .controlSize(.small)
                .help("Re-adds the remote desktop and virtual machine rules that ship with OpenTab")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 6)
        }
    }

    private func ruleRow(_ rule: ExceptionRule) -> some View {
        let isSelected = selectedRuleID == rule.id

        return Button {
            selectedRuleID = rule.id
        } label: {
            HStack(spacing: 9) {
                AppIconView(bundleID: rule.bundleID)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: rule))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(summary(for: rule))
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func displayName(for rule: ExceptionRule) -> String {
        guard !rule.bundleID.isEmpty else { return "New rule" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return rule.bundleID
    }

    private func summary(for rule: ExceptionRule) -> String {
        var parts: [String] = []
        if rule.hideWindows != .never { parts.append("Hide windows") }
        if rule.ignoreShortcuts != .never { parts.append("Ignore shortcuts") }
        return parts.isEmpty ? "No rules" : parts.joined(separator: " · ")
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let index = selectedIndex, rules.indices.contains(index) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    AppIconView(bundleID: rules[index].bundleID)
                        .frame(width: 44, height: 44)
                    Text(displayName(for: rules[index]))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }

                SettingsSection {
                    SettingsRow("exceptions.bundleID", "Bundle ID") {
                        TextField("com.example.app", text: $rules[index].bundleID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 280)
                    }
                    SettingsRow(
                        "exceptions.hideWindows",
                        "Hide windows",
                        subtitle: "Leave this app's windows out of the switcher."
                    ) {
                        EnumPicker(
                            selection: $rules[index].hideWindows,
                            options: HideWindowsPolicy.allCases.map { ($0, $0.displayName) }
                        )
                    }
                    SettingsRow(
                        "exceptions.ignoreShortcuts",
                        "Ignore shortcuts",
                        subtitle: """
                        Pass OpenTab's shortcuts through untouched while this app is \
                        frontmost. Needed for remote desktop and virtual machine \
                        clients, where ⌘Tab must reach the guest system.
                        """
                    ) {
                        EnumPicker(
                            selection: $rules[index].ignoreShortcuts,
                            options: IgnoreShortcutsPolicy.allCases.map { ($0, $0.displayName) }
                        )
                    }
                }

                if rules[index].bundleID.isEmpty {
                    NoticeBox(
                        icon: "info.circle.fill",
                        tint: .blue,
                        text: "Enter a bundle identifier for this rule to take effect."
                    )
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Select a rule, or add one with +")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    // MARK: - Mutation

    private func addRule(bundleID: String) {
        // One rule per app: a second would be unreachable and the list confusing.
        if !bundleID.isEmpty, let existing = rules.first(where: { $0.bundleID == bundleID }) {
            selectedRuleID = existing.id
            return
        }
        let rule = ExceptionRule(bundleID: bundleID)
        rules.append(rule)
        selectedRuleID = rule.id
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        rules.remove(at: index)
        selectedRuleID = rules.isEmpty ? nil : rules[min(index, rules.count - 1)].id
    }

    /// Re-adds the shipped rules without disturbing anything the user added.
    private func restoreShippedDefaults() {
        let existing = Set(rules.map(\.bundleID))
        for rule in ExceptionRule.shippedDefaults where !existing.contains(rule.bundleID) {
            rules.append(rule)
        }
    }

    private func handleAppPick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        addRule(bundleID: bundleID)
    }
}

/// An application's icon, resolved from its bundle identifier.
struct AppIconView: View {
    let bundleID: String

    private var icon: NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable()
        } else {
            // The app is not installed. That is a normal state — the shipped rules
            // cover clients most users will not have — so it renders as a neutral
            // placeholder rather than an error.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "app.dashed")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                )
        }
    }
}
