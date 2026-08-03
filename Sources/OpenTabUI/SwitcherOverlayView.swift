import AppKit
import OpenTabCore
import SwiftUI

/// Everything the overlay needs to draw itself.
///
/// A single value passed down from the controller. The SwiftUI layer is a pure
/// render of this — selection is driven by the event tap, never by SwiftUI focus,
/// because the panel deliberately never becomes key.
public struct SwitcherViewModel: Equatable {
    public var windows: [WindowModel]
    public var selection: Int
    public var appearance: AppearanceSettings
    public var searchQuery: String
    public var isSearching: Bool
    /// Window IDs whose thumbnails have arrived. Everything else falls back to the
    /// app icon, which is why the overlay can appear before any capture completes.
    public var thumbnails: [WindowID: NSImage]

    public init(
        windows: [WindowModel] = [],
        selection: Int = 0,
        appearance: AppearanceSettings = .default,
        searchQuery: String = "",
        isSearching: Bool = false,
        thumbnails: [WindowID: NSImage] = [:]
    ) {
        self.windows = windows
        self.selection = selection
        self.appearance = appearance
        self.searchQuery = searchQuery
        self.isSearching = isSearching
        self.thumbnails = thumbnails
    }

    public static func == (lhs: SwitcherViewModel, rhs: SwitcherViewModel) -> Bool {
        lhs.selection == rhs.selection
            && lhs.searchQuery == rhs.searchQuery
            && lhs.isSearching == rhs.isSearching
            && lhs.appearance == rhs.appearance
            && lhs.windows == rhs.windows
            && lhs.thumbnails.count == rhs.thumbnails.count
    }
}

/// Root of the overlay. Picks a style and draws it.
public struct SwitcherOverlayView: View {

    private let model: SwitcherViewModel
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void
    private let onSearchChange: (String) -> Void

    public init(
        model: SwitcherViewModel,
        onHover: @escaping (Int) -> Void = { _ in },
        onClick: @escaping (Int) -> Void = { _ in },
        onSearchChange: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.onHover = onHover
        self.onClick = onClick
        self.onSearchChange = onSearchChange
    }

    private var metrics: SwitcherMetrics {
        SwitcherMetrics.resolve(model.appearance.size, windowCount: model.windows.count)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isSearching {
                SearchField(query: model.searchQuery, onChange: onSearchChange)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }

            content
                .padding(14)

            if model.windows.isEmpty {
                EmptyStateView(isSearching: model.isSearching)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 20)
            }
        }
        .background(
            VisualEffectBackground()
                .opacity(model.appearance.advanced.panelOpacity)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: model.appearance.advanced.cornerRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: model.appearance.advanced.cornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.appearance.style {
        case .thumbnails:
            ThumbnailsStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick)
        case .appIcons:
            AppIconsStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick)
        case .titles:
            TitlesStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick)
        }
    }
}

// MARK: - Thumbnails

/// Grid of live window previews. The default, and the reason to use this app —
/// picking by sight is faster than reading a list of titles.
struct ThumbnailsStyleView: View {
    let model: SwitcherViewModel
    let metrics: SwitcherMetrics
    let onHover: (Int) -> Void
    let onClick: (Int) -> Void

    private var columns: Int {
        SwitcherLayout.columnCount(
            forItemCount: model.windows.count,
            maxColumns: model.appearance.advanced.maxColumns,
            maxRows: model.appearance.advanced.maxRows
        )
    }

    var body: some View {
        let spacing = model.appearance.advanced.cellPadding

        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(metrics.thumbnailWidth), spacing: spacing),
                           count: max(1, columns)),
            spacing: spacing
        ) {
            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                ThumbnailCell(
                    window: window,
                    thumbnail: model.thumbnails[window.id],
                    metrics: metrics,
                    advanced: model.appearance.advanced,
                    isSelected: index == model.selection
                )
                .contentShape(Rectangle())
                .onHover { inside in if inside { onHover(index) } }
                .onTapGesture { onClick(index) }
            }
        }
    }
}

private struct ThumbnailCell: View {
    let window: WindowModel
    let thumbnail: NSImage?
    let metrics: SwitcherMetrics
    let advanced: AdvancedAppearanceSettings
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                preview
                    .frame(width: metrics.thumbnailWidth, height: metrics.thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                if advanced.showAppIconBadge, let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if advanced.showStatusBadges {
                    StatusBadges(window: window).padding(5)
                }
            }

            if advanced.showWindowTitle {
                Text(window.displayTitle)
                    .font(.system(size: advanced.titleFontSize))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: metrics.thumbnailWidth)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .padding(5)
        .background(SelectionBackground(isSelected: isSelected, style: advanced.highlightStyle))
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // No capture yet, or a minimized/other-Space window that cannot be
            // captured at all. The app icon is always available.
            ZStack {
                Rectangle().fill(Color.primary.opacity(0.07))
                if let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: metrics.thumbnailHeight * 0.45,
                               height: metrics.thumbnailHeight * 0.45)
                        .opacity(0.85)
                }
            }
        }
    }
}

// MARK: - App icons

/// Compact dock-like row of large app icons.
struct AppIconsStyleView: View {
    let model: SwitcherViewModel
    let metrics: SwitcherMetrics
    let onHover: (Int) -> Void
    let onClick: (Int) -> Void

    private var columns: Int {
        SwitcherLayout.columnCount(
            forItemCount: model.windows.count,
            maxColumns: max(model.appearance.advanced.maxColumns, 8),
            maxRows: model.appearance.advanced.maxRows
        )
    }

    var body: some View {
        let spacing = model.appearance.advanced.cellPadding

        VStack(spacing: 8) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(metrics.iconSize + 16), spacing: spacing),
                               count: max(1, columns)),
                spacing: spacing
            ) {
                ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                    VStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            if let icon = window.appIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.1))
                                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                            }

                            if model.appearance.advanced.showStatusBadges {
                                StatusBadges(window: window)
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        SelectionBackground(
                            isSelected: index == model.selection,
                            style: model.appearance.advanced.highlightStyle
                        )
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { onHover(index) } }
                    .onTapGesture { onClick(index) }
                }
            }

            // The icon row alone cannot say which *window* is selected when an app
            // has several, so the name is spelled out underneath.
            if model.windows.indices.contains(model.selection) {
                Text(model.windows[model.selection].qualifiedTitle)
                    .font(.system(size: model.appearance.advanced.titleFontSize + 1, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: CGFloat(max(1, columns)) * (metrics.iconSize + 24))
            }
        }
    }
}

// MARK: - Titles

/// Vertical list of "AppName — Window Title" rows with small icons.
struct TitlesStyleView: View {
    let model: SwitcherViewModel
    let metrics: SwitcherMetrics
    let onHover: (Int) -> Void
    let onClick: (Int) -> Void

    private var rowWidth: Double {
        switch model.appearance.size {
        case .small:  380
        case .medium: 480
        case .large:  600
        case .auto:   model.windows.count > 12 ? 380 : 480
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                HStack(spacing: 9) {
                    if let icon = window.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: metrics.titleRowHeight - 10,
                                   height: metrics.titleRowHeight - 10)
                    }

                    Text(window.appName)
                        .font(.system(size: model.appearance.advanced.titleFontSize + 1,
                                      weight: .medium))
                        .lineLimit(1)
                        .layoutPriority(1)

                    if !window.title.isEmpty, window.title != window.appName {
                        Text("—")
                            .font(.system(size: model.appearance.advanced.titleFontSize))
                            .foregroundStyle(.tertiary)
                        Text(window.title)
                            .font(.system(size: model.appearance.advanced.titleFontSize + 1))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 6)

                    if model.appearance.advanced.showStatusBadges {
                        StatusBadges(window: window, inline: true)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: metrics.titleRowHeight)
                .frame(width: rowWidth, alignment: .leading)
                .background(
                    SelectionBackground(
                        isSelected: index == model.selection,
                        style: model.appearance.advanced.highlightStyle,
                        cornerRadius: 6
                    )
                )
                .contentShape(Rectangle())
                .onHover { inside in if inside { onHover(index) } }
                .onTapGesture { onClick(index) }
            }
        }
    }
}

// MARK: - Shared pieces

/// Selection marker. Filled or outlined per the advanced appearance setting.
private struct SelectionBackground: View {
    let isSelected: Bool
    let style: HighlightStyle
    var cornerRadius: Double = 9

    var body: some View {
        Group {
            switch style {
            case .fill:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
            case .border:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            }
        }
    }
}

/// Minimized, hidden, and fullscreen indicators.
private struct StatusBadges: View {
    let window: WindowModel
    var inline: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if window.isMinimized { badge("arrow.down.right.and.arrow.up.left") }
            if window.isHidden { badge("eye.slash.fill") }
            if window.isFullscreen { badge("arrow.up.left.and.arrow.down.right") }
            if window.isApplicationEntry { badge("app.dashed") }
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: inline ? 9 : 8, weight: .semibold))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(Color.black.opacity(0.55)))
    }
}

/// Search field shown in search mode.
private struct SearchField: View {
    let query: String
    let onChange: (String) -> Void

    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Filter windows", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onChange(of: text) { _, newValue in onChange(newValue) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .onAppear { text = query }
    }
}

private struct EmptyStateView: View {
    let isSearching: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: isSearching ? "magnifyingglass" : "macwindow")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(isSearching ? "No windows match" : "No windows to show")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

/// `NSVisualEffectView` bridged into SwiftUI for the panel background.
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material

    public init(material: NSVisualEffectView.Material = .hudWindow) {
        self.material = material
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
