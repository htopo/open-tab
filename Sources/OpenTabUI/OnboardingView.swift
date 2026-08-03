import AppKit
import OpenTabCore
import SwiftUI

/// First-launch permission walkthrough.
///
/// Shown when Accessibility is missing, which is the only state that leaves the
/// app unable to do anything. The window watches `PermissionsMonitor` and updates
/// live, so the user can tick the checkbox in System Settings and see this window
/// react without clicking anything here — which is the moment most permission
/// walkthroughs get wrong by demanding a relaunch.
public struct OnboardingView: View {

    private let permissions: PermissionsMonitor
    private let onFinish: () -> Void

    public init(permissions: PermissionsMonitor, onFinish: @escaping () -> Void) {
        self.permissions = permissions
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                PermissionRow(
                    title: "Accessibility",
                    requirement: .required,
                    granted: permissions.accessibility,
                    explanation: """
                    Lets OpenTab see your open windows — including minimized ones and \
                    windows on other Spaces — bring the one you pick to the front, and \
                    notice when you press the shortcut.
                    """,
                    grantedMessage: "OpenTab can see and switch your windows.",
                    primaryAction: ("Open System Settings", {
                        permissions.requestAccessibility()
                        permissions.openSettings(for: .accessibility)
                    })
                )

                PermissionRow(
                    title: "Screen Recording",
                    requirement: .optional,
                    granted: permissions.screenRecording,
                    explanation: """
                    Only used to draw live thumbnails of your windows. Skip it and \
                    OpenTab shows app icons instead — everything else works exactly \
                    the same.
                    """,
                    grantedMessage: "Thumbnails are available.",
                    primaryAction: ("Open System Settings", {
                        permissions.openSettings(for: .screenRecording)
                    })
                )
            }
            .padding(20)

            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 520, height: 500)
        .onAppear { permissions.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 68, height: 68)
                .accessibilityHidden(true)

            Text("Welcome to OpenTab")
                .font(.system(size: 22, weight: .semibold))

            Text("Switch between windows, not just apps.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("OpenTab needs permission from macOS before it can do that.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            if permissions.accessibility {
                Label("Ready to go", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text("Waiting for Accessibility access…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(permissions.accessibility ? "Start Using OpenTab" : "Quit") {
                if permissions.accessibility {
                    onFinish()
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Row

/// One permission, its rationale, and its current state.
private struct PermissionRow: View {

    enum Requirement {
        case required
        case optional

        var label: String {
            switch self {
            case .required: "Required"
            case .optional: "Optional"
            }
        }
    }

    let title: String
    let requirement: Requirement
    let granted: Bool
    let explanation: String
    let grantedMessage: String
    let primaryAction: (title: String, action: () -> Void)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 19))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))

                    Text(requirement.label)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(requirement == .required
                                           ? Color.orange.opacity(0.18)
                                           : Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(requirement == .required ? Color.orange : Color.secondary)
                }

                Text(granted ? grantedMessage : explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !granted {
                    Button(primaryAction.title, action: primaryAction.action)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
