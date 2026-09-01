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

    /// How many windows each application has in this list, for the window-count
    /// badge. Only meaningful above one, which is exactly when it is shown.
    public var windowCounts: [pid_t: Int]

    /// One entry per Desktop represented in `windows`, in draw order.
    ///
    /// Empty in the ordinary case. Populated only while the space bar is held to
    /// reveal the other Desktops, which is the one moment the extra structure
    /// earns the space it takes: the rest of the time a single list is what the
    /// user wants to read.
    public var spaceSections: [SpaceSection]

    /// Whether this update may animate the selection moving.
    ///
    /// False when the layout itself changed — revealing or hiding the Desktop
    /// columns. There the selection does not *move* between neighbours, it lands
    /// somewhere else entirely while the panel changes shape around it, and
    /// animating that reads as the highlight flying across the screen rather than
    /// as a considered transition.
    public var animatesSelection: Bool

    public init(
        windows: [WindowModel] = [],
        selection: Int = 0,
        appearance: AppearanceSettings = .default,
        searchQuery: String = "",
        isSearching: Bool = false,
        thumbnails: [WindowID: NSImage] = [:],
        windowCounts: [pid_t: Int] = [:],
        spaceSections: [SpaceSection] = [],
        animatesSelection: Bool = true
    ) {
        self.windows = windows
        self.selection = selection
        self.appearance = appearance
        self.searchQuery = searchQuery
        self.isSearching = isSearching
        self.thumbnails = thumbnails
        self.windowCounts = windowCounts
        self.spaceSections = spaceSections
        self.animatesSelection = animatesSelection
    }

    public static func == (lhs: SwitcherViewModel, rhs: SwitcherViewModel) -> Bool {
        lhs.selection == rhs.selection
            && lhs.searchQuery == rhs.searchQuery
            && lhs.isSearching == rhs.isSearching
            && lhs.appearance == rhs.appearance
            && lhs.windows == rhs.windows
            && lhs.spaceSections == rhs.spaceSections
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

    /// Nil disables the animation outright, which is what both the app's own
    /// "animate selection movement" toggle and the system's reduce-motion setting
    /// ask for. Deliberately brief — the selection has to keep up with someone
    /// holding the key down and cycling fast.
    private var selectionAnimation: Animation? {
        let animations = model.appearance.animations
        guard model.animatesSelection,
              animations.animateSelectionMove,
              MotionPreference.shouldAnimate(userReduceAnimations: animations.reduceAnimations)
        else { return nil }
        return .easeOut(duration: 0.09)
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
                // Animates the highlight sliding between entries. Driven off the
                // selection alone: animating on the whole model would also animate
                // thumbnails fading in, which arrive asynchronously and would make
                // the panel look like it was still loading.
                .animation(selectionAnimation, value: model.selection)

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
        if model.spaceSections.count > 1 {
            SpaceColumnsView(model: model, metrics: metrics, onHover: onHover, onClick: onClick)
        } else {
            styleView(for: model.windows, offset: 0)
        }
    }

    @ViewBuilder
    private func styleView(for windows: [WindowModel], offset: Int) -> some View {
        switch model.appearance.style {
        case .thumbnails:
            ThumbnailsStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick,
                                slice: windows, offset: offset)
        case .appIcons:
            AppIconsStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick,
                              slice: windows, offset: offset)
        case .titles:
            TitlesStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick,
                            slice: windows, offset: offset)
        }
    }
}

// MARK: - Desktop columns

/// One column per Desktop, drawn while the space bar reveals the hidden ones.
///
/// A column rather than a longer list because the question being asked changes:
/// normally it is "which window", but with every Desktop on screen it becomes
/// "which Desktop, then which window". Splicing the other Desktops into one flat
/// list answers neither — the user loses the boundary they were reasoning about,
/// and the entries they were already looking at shift under them.
///
/// Columns run in Desktop order, Desktop 1 leftmost, and do not rearrange
/// themselves around whichever Desktop the user is on. The headings are numbered
/// and those numbers are the navigation — pressing 2 jumps to Desktop 2 — which
/// only reads as dependable if 2 is also always in the same place on screen. The
/// current Desktop is marked in its heading instead of by position.
struct SpaceColumnsView: View {
    let model: SwitcherViewModel
    let metrics: SwitcherMetrics
    let onHover: (Int) -> Void
    let onClick: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(Array(model.spaceSections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    header(for: section)
                    styleView(
                        windows: Array(model.windows[section.range]),
                        offset: section.range.lowerBound
                    )
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func styleView(windows: [WindowModel], offset: Int) -> some View {
        switch model.appearance.style {
        case .thumbnails:
            ThumbnailsStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick,
                                slice: windows, offset: offset)
        case .appIcons:
            AppIconsStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick,
                              slice: windows, offset: offset)
        case .titles:
            TitlesStyleView(model: model, metrics: metrics, onHover: onHover, onClick: onClick,
                            slice: windows, offset: offset)
        }
    }

    private func header(for section: SpaceSection) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(section.isCurrent ? .primary : .secondary)

            if section.isCurrent {
                Text("current")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 2)
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

    /// The entries this instance draws, and where they start in `model.windows`.
    ///
    /// Selection is a single index into the whole list, so a view drawing only a
    /// slice of it has to add its offset back before comparing or reporting —
    /// otherwise every Desktop column would highlight its own first entry.
    var slice: [WindowModel]? = nil
    var offset: Int = 0

    private var windows: [WindowModel] { slice ?? model.windows }

    private var columns: Int {
        SwitcherLayout.columnCount(
            forItemCount: windows.count,
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
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                ThumbnailCell(
                    window: window,
                    thumbnail: model.thumbnails[window.id],
                    windowCount: model.windowCounts[window.id.pid] ?? 1,
                    metrics: metrics,
                    advanced: model.appearance.advanced,
                    isSelected: index + offset == model.selection
                )
                .contentShape(Rectangle())
                .onHover { inside in if inside { onHover(index + offset) } }
                .onTapGesture { onClick(index + offset) }
            }
        }
    }
}

private struct ThumbnailCell: View {
    let window: WindowModel
    let thumbnail: NSImage?
    let windowCount: Int
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
            .overlay(alignment: .topTrailing) {
                if advanced.showWindowCountBadge, windowCount > 1 {
                    WindowCountBadge(count: windowCount).padding(5)
                }
            }

            // With window titles off the caption falls back to the application
            // name rather than disappearing: a grid of previews with nothing
            // written under them is harder to read, not cleaner.
            Text(advanced.showWindowTitle
                 ? window.displayTitle
                 : AppDisplayName.display(window.appName, shorten: advanced.shortenApplicationNames))
                .font(.system(size: advanced.titleFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: metrics.thumbnailWidth)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
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

    /// The entries this instance draws, and where they start in `model.windows`.
    ///
    /// Selection is a single index into the whole list, so a view drawing only a
    /// slice of it has to add its offset back before comparing or reporting —
    /// otherwise every Desktop column would highlight its own first entry.
    var slice: [WindowModel]? = nil
    var offset: Int = 0

    private var windows: [WindowModel] { slice ?? model.windows }

    private var columns: Int {
        SwitcherLayout.columnCount(
            forItemCount: windows.count,
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
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
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
                        .overlay(alignment: .topTrailing) {
                            let count = model.windowCounts[window.id.pid] ?? 1
                            if model.appearance.advanced.showWindowCountBadge, count > 1 {
                                WindowCountBadge(count: count).offset(x: 5, y: -3)
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        SelectionBackground(
                            isSelected: index + offset == model.selection,
                            style: model.appearance.advanced.highlightStyle
                        )
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { onHover(index + offset) } }
                    .onTapGesture { onClick(index + offset) }
                }
            }

            // The icon row alone cannot say which *window* is selected when an app
            // has several, so the name is spelled out underneath. In Desktop
            // columns only the column holding the selection shows it — one caption
            // per column would repeat the same name across the panel.
            let localSelection = model.selection - offset
            if windows.indices.contains(localSelection) {
                Text(windows[localSelection].displayLabel(
                    shortenAppName: model.appearance.advanced.shortenApplicationNames,
                    includeWindowTitle: model.appearance.advanced.showWindowTitle
                ))
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

    /// The entries this instance draws, and where they start in `model.windows`.
    ///
    /// Selection is a single index into the whole list, so a view drawing only a
    /// slice of it has to add its offset back before comparing or reporting —
    /// otherwise every Desktop column would highlight its own first entry.
    var slice: [WindowModel]? = nil
    var offset: Int = 0

    private var windows: [WindowModel] { slice ?? model.windows }

    private var rowWidth: Double {
        switch model.appearance.size {
        case .small:  380
        case .medium: 480
        case .large:  600
        case .auto:   windows.count > 12 ? 380 : 480
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                HStack(spacing: 9) {
                    if let icon = window.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: metrics.titleRowHeight - 10,
                                   height: metrics.titleRowHeight - 10)
                    }

                    Text(AppDisplayName.display(
                        window.appName,
                        shorten: model.appearance.advanced.shortenApplicationNames
                    ))
                        .font(.system(size: model.appearance.advanced.titleFontSize + 1,
                                      weight: .medium))
                        .lineLimit(1)
                        .layoutPriority(1)

                    if model.appearance.advanced.showWindowTitle,
                       !window.title.isEmpty,
                       window.title != window.appName {
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
                        isSelected: index + offset == model.selection,
                        style: model.appearance.advanced.highlightStyle,
                        cornerRadius: 6
                    )
                )
                .contentShape(Rectangle())
                .onHover { inside in if inside { onHover(index + offset) } }
                .onTapGesture { onClick(index + offset) }
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

/// How many windows the owning application has.
///
/// Only drawn above one: a "1" on every entry would be noise, and the number is
/// only telling you something when there is more than one window to disambiguate.
private struct WindowCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
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
