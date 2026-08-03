import AppKit
import OpenTabCore
import SwiftUI

/// A titled group of settings rows, matching the grouped-list look of System
/// Settings.
public struct SettingsSection<Content: View>: View {
    private let title: String?
    private let content: Content

    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.leading, 2)
            }

            VStack(spacing: 0) {
                content
            }
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
}

/// One labelled row with a trailing control.
///
/// `settingID` ties the row back to `SettingsRegistry`, which is what lets a
/// search result scroll to and briefly highlight the right control.
public struct SettingsRow<Control: View>: View {
    private let settingID: String
    private let title: String
    private let subtitle: String?
    private let control: Control

    @Environment(\.highlightedSettingID) private var highlightedID

    public init(_ settingID: String,
                _ title: String,
                subtitle: String? = nil,
                @ViewBuilder control: () -> Control) {
        self.settingID = settingID
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    private var isHighlighted: Bool { highlightedID == settingID }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isHighlighted
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear
            )
            .id(settingID)

            Divider().padding(.leading, 12)
        }
    }
}

/// Removes the trailing divider from the last row of a section.
public struct SettingsSectionEnd: View {
    public init() {}
    public var body: some View {
        Color.clear.frame(height: 0)
    }
}

/// The setting a search result asked to jump to, so the row can flash.
public struct HighlightedSettingKey: EnvironmentKey {
    public static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    var highlightedSettingID: String? {
        get { self[HighlightedSettingKey.self] }
        set { self[HighlightedSettingKey.self] = newValue }
    }
}

/// A compact popup for an enum-backed setting.
public struct EnumPicker<Value: Hashable>: View {
    private let selection: Binding<Value>
    private let options: [(value: Value, label: String)]
    private let width: CGFloat?

    public init(selection: Binding<Value>,
                options: [(value: Value, label: String)],
                width: CGFloat? = nil) {
        self.selection = selection
        self.options = options
        self.width = width
    }

    public var body: some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .frame(width: width, alignment: .trailing)
    }
}

/// Slider plus a numeric readout, for the advanced appearance controls.
public struct LabelledSlider: View {
    private let value: Binding<Double>
    private let range: ClosedRange<Double>
    private let step: Double
    private let format: (Double) -> String

    public init(value: Binding<Double>,
                range: ClosedRange<Double>,
                step: Double = 1,
                format: @escaping (Double) -> String = { String(format: "%.0f", $0) }) {
        self.value = value
        self.range = range
        self.step = step
        self.format = format
    }

    public var body: some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: step)
                .frame(width: 160)
            Text(format(value.wrappedValue))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// The three style choices, shown as preview tiles rather than a popup.
///
/// A switcher's look is the thing users change most and the hardest to picture
/// from a word, so the choice shows what it does.
public struct StylePicker: View {
    @Binding public var style: SwitcherStyle
    public var disabledStyles: Set<SwitcherStyle>
    public var disabledExplanation: String?

    public init(style: Binding<SwitcherStyle>,
                disabledStyles: Set<SwitcherStyle> = [],
                disabledExplanation: String? = nil) {
        self._style = style
        self.disabledStyles = disabledStyles
        self.disabledExplanation = disabledExplanation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(SwitcherStyle.allCases, id: \.self) { candidate in
                    tile(for: candidate)
                }
            }

            if let disabledExplanation, !disabledStyles.isEmpty {
                Text(disabledExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(for candidate: SwitcherStyle) -> some View {
        let isDisabled = disabledStyles.contains(candidate)
        let isSelected = style == candidate

        return VStack(spacing: 6) {
            StylePreview(style: candidate)
                .frame(width: 108, height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                )

            Text(candidate.displayName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
        }
        .opacity(isDisabled ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !isDisabled { style = candidate } }
        .help(isDisabled ? (disabledExplanation ?? "") : candidate.displayName)
    }
}

/// Miniature of what each style looks like.
private struct StylePreview: View {
    let style: SwitcherStyle

    var body: some View {
        switch style {
        case .thumbnails:
            grid(columns: 3, rows: 2, cornerRadius: 2.5, aspect: 1.6)
        case .appIcons:
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == 1 ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 15, height: 15)
                }
            }
        case .titles:
            VStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(index == 1 ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index == 1 ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25))
                            .frame(height: 4)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func grid(columns: Int, rows: Int, cornerRadius: CGFloat, aspect: CGFloat) -> some View {
        VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { column in
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(row == 0 && column == 1
                                  ? Color.accentColor
                                  : Color.secondary.opacity(0.3))
                            .frame(width: 24, height: 24 / aspect)
                    }
                }
            }
        }
    }
}
