import AppKit
import SwiftUI

/// What the switcher list shows. Only `shown` rows are on screen at once; the
/// range follows the selection.
final class SwitcherListModel: ObservableObject {
    /// What the list or grid takes up, in the middle of the panel.
    @Published var size = CGSize.zero
    @Published var items: [SwitcherItem] = []
    @Published var selection = 0
    /// Index of the first row on screen.
    @Published var first = 0
    @Published var shown = 0
    @Published var style = SwitcherStyle.list
    /// Pictures for the grid, by window.
    @Published var previews: [CGWindowID: CGImage] = [:]
    @Published var layout = GridLayout()
    @Published var previewIcons = PreviewIcons.large
    /// What's been typed. Shows above the rows, once there's something.
    @Published var query = ""
    /// The numbers on apps' icons, by the file name of the app.
    @Published var badges: [String: String] = [:]

    func badge(of item: SwitcherItem) -> String? {
        item.appURL.flatMap { badges[$0.lastPathComponent] }
    }

    var visible: ArraySlice<SwitcherItem> {
        items[min(first, items.count)..<min(first + shown, items.count)]
    }

    /// Moves the visible range by `delta` rows, or just far enough to show the selection.
    func scroll(by delta: Int = 0) {
        var first = first + delta
        if delta == 0 {
            if selection < first { first = selection }
            if selection >= first + shown { first = selection - shown + 1 }
        }
        self.first = max(0, min(first, items.count - shown))
    }
}

/// The list or the grid, as the switcher's style says.
struct SwitcherView: View {
    @ObservedObject var model: SwitcherListModel

    /// At its own size, in the middle of a panel that may be larger (filling
    /// part of a display, for the suggestions).
    var body: some View {
        VStack(spacing: 0) {
            if !model.query.isEmpty {
                SwitcherSearchBar(query: model.query)
            }
            if model.items.isEmpty, !model.query.isEmpty {
                Text("No matches")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.style == .previews {
                SwitcherGridView(model: model)
            } else {
                SwitcherListView(model: model)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
    }
}

/// What's been typed, above the rows.
private struct SwitcherSearchBar: View {
    static let height: CGFloat = 44
    let query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(verbatim: query).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8))
        .frame(height: Self.height, alignment: .top)
    }
}

/// An app's number, flat like its colours.
private struct SwitcherBadge: View {
    private static let red = Color(nsColor: AppPalette.oklch(0.58, 0.17, 25))
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(Self.red, in: Capsule())
    }
}

/// Where each tile of the grid goes. Tiles are as wide as the size setting
/// allows, and narrower when that's what it takes for every window to fit.
/// Rows are filled evenly and centred. Coordinates start at the top left.
struct GridLayout: Equatable {
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 14
    /// Height over width of a tile's picture.
    static let aspect: CGFloat = 0.66
    /// What a tile has beyond that, so its bar's two lines don't take from the picture.
    static let extraHeight: CGFloat = 14
    static let minimumWidth: CGFloat = 96

    var tile = CGSize(width: 260, height: 260 * GridLayout.aspect + GridLayout.extraHeight)
    var columns = 1
    var count = 0

    init() {}

    init(count: Int, maxTileWidth: CGFloat, area: CGSize) {
        self.count = count
        let n = max(count, 1)
        // Never wider than the area: one tile would be, with a narrow one.
        var width = max(min(maxTileWidth, area.width - Self.padding * 2), Self.minimumWidth)
        var columns = 1
        while true {
            columns = min(n, Self.across(area.width, tile: width))
            let rows = Int(ceil(Double(n) / Double(columns)))
            let height = CGFloat(rows) * (width * Self.aspect + Self.extraHeight) + CGFloat(rows - 1) * Self.spacing + Self.padding * 2
            if height <= area.height || width <= Self.minimumWidth { break }
            width -= 4
        }
        // As few columns as the same number of rows needs, so rows come out even.
        let rows = Int(ceil(Double(n) / Double(columns)))
        self.columns = Int(ceil(Double(n) / Double(rows)))
        tile = CGSize(width: width.rounded(), height: (width * Self.aspect + Self.extraHeight).rounded())
    }

    var rows: Int { max(1, Int(ceil(Double(max(count, 1)) / Double(columns)))) }

    /// How many tiles of this width fit across `width`, at most.
    static func across(_ width: CGFloat, tile: CGFloat) -> Int {
        max(1, Int((width - padding * 2 + spacing) / (tile + spacing)))
    }

    var size: CGSize {
        CGSize(width: CGFloat(columns) * tile.width + CGFloat(columns - 1) * Self.spacing + Self.padding * 2,
               height: CGFloat(rows) * tile.height + CGFloat(rows - 1) * Self.spacing + Self.padding * 2)
    }

    private func tiles(inRow row: Int) -> Int {
        min(columns, count - row * columns)
    }

    func frame(of index: Int) -> CGRect {
        let row = index / columns, column = index % columns
        let inRow = tiles(inRow: row)
        let rowWidth = CGFloat(inRow) * tile.width + CGFloat(inRow - 1) * Self.spacing
        let x = (size.width - rowWidth) / 2 + CGFloat(column) * (tile.width + Self.spacing)
        let y = Self.padding + CGFloat(row) * (tile.height + Self.spacing)
        return CGRect(x: x, y: y, width: tile.width, height: tile.height)
    }

    func index(at point: CGPoint) -> Int? {
        (0..<count).first { frame(of: $0).contains(point) }
    }

    /// The tile above (`rows` -1) or below (+1), the one nearest across.
    func neighbour(of index: Int, rows step: Int) -> Int {
        let row = index / columns + step
        guard row >= 0, row < rows else { return index }
        let x = frame(of: index).midX
        let candidates = (row * columns)..<(row * columns + tiles(inRow: row))
        return candidates.min { abs(frame(of: $0).midX - x) < abs(frame(of: $1).midX - x) } ?? index
    }
}

struct SwitcherGridView: View {
    @ObservedObject var model: SwitcherListModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                let frame = model.layout.frame(of: index)
                PreviewTile(item: item, image: item.window.flatMap { model.previews[$0] },
                            number: index < 9 ? index + 1 : nil, selected: index == model.selection, badge: model.badge(of: item),
                            width: frame.width, icons: model.previewIcons)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: model.layout.size.width, height: model.layout.size.height, alignment: .topLeading)
    }
}

/// The sizes app icons are drawn sharp at, since icons are made for them.
/// Anything between is scaled and comes out soft, most of all on a 1x display:
/// measured at 28 pt, a third as sharp as at 32 pt.
private enum AppIconSize {
    static let small: CGFloat = 16, medium: CGFloat = 32

    /// The sharp size nearest a share of the tile: 48 pt on a medium one.
    static func large(onTile width: CGFloat) -> CGFloat {
        [24, 32, 48, 64].min { abs($0 - width * 0.18) < abs($1 - width * 0.18) } ?? 48
    }
}

private struct PreviewTile: View {
    let item: SwitcherItem
    let image: CGImage?
    let number: Int?
    let selected: Bool
    let badge: String?
    let width: CGFloat
    let icons: PreviewIcons

    private static let barHeight: CGFloat = 40

    /// In proportion to the tile. Without a picture, the icon in the middle
    /// says it already.
    private var largeIcon: CGFloat? {
        icons == .large && image != nil ? AppIconSize.large(onTile: width) : nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // A card of its own: a fainter one was lost on the frosted
            // surface behind, and windows with see-through parts seemed to
            // have no background.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(item.tint.map(AppPalette.row) ?? (selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected || item.tint != nil ? 0 : 0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(8)
                        .padding(.bottom, Self.barHeight - 4)
                } else if let icon = item.icon {
                    // Nothing to show of the window itself (minimized, hidden,
                    // or not seen yet): its app instead.
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .padding(.bottom, Self.barHeight - 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(item.tint != nil && item.dimmed ? 0.55 : 1)
            label
        }
        .overlay(alignment: .topLeading) {
            if let number {
                Text(String(number))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.black.opacity(selected ? 0.55 : 0.4), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let largeIcon, let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: largeIcon, height: largeIcon)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .opacity(item.tint != nil && item.dimmed ? 0.55 : 1)
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            // On the corner of the large icon, as on the Dock's.
            if let badge { SwitcherBadge(text: badge).padding(largeIcon == nil ? 6 : 2) }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? (item.tint == nil ? Color.accentColor : Color.primary) : Color.clear, lineWidth: 3))
        // With a colour, only the content fades: the colour stays the app's.
        .opacity(item.tint == nil && item.dimmed ? 0.55 : 1)
    }

    /// The app, and below it the window's title, across the bottom of the
    /// tile: the app is what the eye looks for, the title which of its windows.
    private var label: some View {
        HStack(spacing: 8) {
            if icons == .small, let icon = item.icon {
                let size = width < 140 ? AppIconSize.small : AppIconSize.medium
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                // Nothing more to say for a row that stands for an app, or a
                // window that's only named after it.
                if let title = item.titleBesideApp {
                    Text(title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(0.8)
                }
            }
            Spacer(minLength: 0)
            if let symbol = item.stateSymbol {
                Image(systemName: symbol).font(.system(size: 11))
            }
        }
        .foregroundStyle(.white)
        .opacity(item.tint != nil && item.dimmed ? 0.65 : 1)
        .padding(.horizontal, 8)
        .frame(height: Self.barHeight)
        .background(item.tint.map(AppPalette.selected) ?? Color.black.opacity(0.55))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
    }
}

extension SwitcherItem {
    /// The title with the app's name taken off, for showing under that name:
    /// "Inbox - Mail" is "Inbox". Nil if that leaves nothing.
    var titleBesideApp: String? {
        Self.title(title, without: appName)
    }

    static func title(_ title: String, without app: String) -> String? {
        let rest = title.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        if rest.compare(app, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return nil }
        // Only set off by a separator: "Notes" stays in "Notes for Monday".
        for separator in [" - ", " – ", " — ", " | ", ": "] {
            if let range = rest.range(of: app + separator, options: options) { return String(rest[range.upperBound...]) }
            if let range = rest.range(of: separator + app, options: options.union(.backwards)) { return String(rest[..<range.lowerBound]) }
        }
        return rest
    }

    /// What the row or tile marks a window that isn't simply open with.
    var stateSymbol: String? {
        switch state {
        case .window: return nil
        case .minimized: return "minus.circle"
        case .hiddenApp: return "eye.slash"
        case .noWindows: return "macwindow.badge.plus"
        case .notListed: return "arrow.up.forward.app"
        }
    }
}

struct SwitcherListView: View {
    static let rowHeight: CGFloat = 38
    static let padding: CGFloat = 8

    @ObservedObject var model: SwitcherListModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.visible.enumerated()), id: \.element.id) { offset, item in
                let index = model.first + offset
                SwitcherRow(item: item, number: index < 9 ? index + 1 : nil, selected: index == model.selection, badge: model.badge(of: item))
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SwitcherRow: View {
    let item: SwitcherItem
    let number: Int?
    let selected: Bool
    let badge: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(number == nil ? 0 : (selected ? 0.22 : 0.1)),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .frame(width: AppIconSize.medium, height: AppIconSize.medium)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if let stateSymbol = item.stateSymbol {
                Image(systemName: stateSymbol).font(.footnote)
            }
            // Rows that stand for an app already show its name as the title.
            if item.window != nil, item.title != item.appName {
                Text(item.appName)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .opacity(0.6)
            }
            // Says what picking this row does: there's no window to go to.
            if item.state == .notListed {
                Text("Open").opacity(0.6)
            }
            // Last, so it's always in the same place, whatever comes before it.
            if let badge { SwitcherBadge(text: badge) }
        }
        .font(.system(size: 14))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .opacity(item.dimmed ? 0.55 : 1)
        .padding(.horizontal, 8)
        .frame(height: SwitcherListView.rowHeight)
        .background {
            // Flat, with a small gap between rows so each reads as a block. A
            // dimmed row keeps its colour whole: faded, it looked like another app.
            if let tint = item.tint {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AppPalette.selected(tint) : AppPalette.row(tint))
                    .padding(.vertical, 1.5)
            } else if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor)
            }
        }
    }
}

/// The floating list. For the switcher it never becomes key: the keyboard is
/// handled by the controller's event tap, and the mouse by a view laid over
/// the rows. Window Layout's suggestions use it too, filling an empty part of
/// a display, and there it takes the keys itself, still without making the
/// toolkit the active app.
final class SwitcherPanel {
    let model = SwitcherListModel()
    /// The pointer moved onto the row at this index.
    var onHover: (Int) -> Void = { _ in }
    var onClick: (Int) -> Void = { _ in }
    /// Keys, when it `takesKeys`; and the keyboard went elsewhere.
    var onKey: (NSEvent) -> Void = { _ in }
    var onResign: () -> Void = {}

    private let takesKeys: Bool
    private lazy var panel = makePanel()
    /// Area of the display the list is on. Chosen when it opens, so it does
    /// not jump displays while open.
    private var screen = NSRect.zero
    /// Shown in `screen` filling it, rather than centred in part of it.
    private var fills = false
    private(set) var isVisible = false
    /// Keeps the top of the list still while a search changes how long it is.
    private var searchTop: CGFloat?

    init(takesKeys: Bool = false) {
        self.takesKeys = takesKeys
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.takesKeys = takesKeys
        panel.onKey = { [weak self] in self?.onKey($0) }
        panel.onResign = { [weak self] in
            guard let self, self.isVisible else { return }
            self.onResign()
        }
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Shows over full-screen apps and on whichever Space is current.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let list = NSHostingView(rootView: SwitcherView(model: model))
        let mouse = MouseCatcher()
        mouse.panel = self
        for view in [list, mouse] {
            view.frame = background.bounds
            view.autoresizingMask = [.width, .height]
            background.addSubview(view)
        }
        panel.contentView = background
        return panel
    }

    /// The display the switcher opens on.
    static func screen(for placement: SwitcherPlacement) -> NSScreen? {
        let screens = NSScreen.screens
        let chosen: NSScreen?
        switch placement {
        case .mainScreen: chosen = screens.first
        case .mouse: chosen = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        case .activeWindow: chosen = NSScreen.main
        }
        return chosen ?? screens.first
    }

    func show(_ items: [SwitcherItem], selection: Int, on placement: SwitcherPlacement) {
        let chosen = Self.screen(for: placement)
        screen = chosen?.visibleFrame ?? .zero
        scale = chosen?.backingScaleFactor ?? 2
        fills = false
        isVisible = true
        update(items, selection: selection)
        panel.orderFrontRegardless()
    }

    /// Fills `area` (AppKit coordinates) with the list or grid, for as long
    /// as it's shown.
    func show(_ items: [SwitcherItem], selection: Int, filling area: NSRect) {
        screen = area
        scale = NSScreen.screens.first { $0.frame.intersects(area) }?.backingScaleFactor ?? 2
        fills = true
        isVisible = true
        update(items, selection: selection)
        panel.orderFrontRegardless()
        if takesKeys { panel.makeKey() }
    }

    /// The most the grid takes of a display, centred on it.
    static func gridArea(on display: CGSize, percent: Double) -> CGSize {
        CGSize(width: display.width * percent / 100, height: display.height * 0.8)
    }

    /// Margin between the panel and the edges of the area it fills.
    private static let inset: CGFloat = 12

    /// Set before `show`, for the session.
    var style = SwitcherStyle.list
    var previewSize = PreviewSize.medium
    var scale: CGFloat = 2
    /// The switcher's setting, for Window Layout's suggestions as well.
    static var previewIcons = PreviewIcons.large
    /// How much of the display's width the grid can use, set before `show`.
    var gridWidth = GridWidth.range.upperBound
    /// What's been typed, shown from the next `update`.
    var query = ""

    private var header: CGFloat { query.isEmpty ? 0 : SwitcherSearchBar.height }

    func update(_ items: [SwitcherItem], selection: Int) {
        guard isVisible else { return }
        model.style = style
        if model.previewIcons != Self.previewIcons { model.previewIcons = Self.previewIcons }
        if model.query != query { model.query = query }
        if query.isEmpty {
            searchTop = nil
        } else if searchTop == nil, panel.isVisible {
            searchTop = panel.frame.maxY
        }
        if style == .previews, !items.isEmpty || query.isEmpty {
            let area = fills ? CGSize(width: screen.width - Self.inset * 2, height: screen.height - Self.inset * 2)
                             : Self.gridArea(on: screen.size, percent: gridWidth)
            let layout = GridLayout(count: items.count, maxTileWidth: previewSize.maxTileWidth, area: area)
            model.items = items
            model.selection = selection
            if layout != model.layout { model.layout = layout }
            place(NSSize(width: layout.size.width, height: layout.size.height + header))
            return
        }
        let height = fills ? screen.height - Self.inset * 2 : screen.height * 0.7
        let room = Int((height - header - SwitcherListView.padding * 2) / SwitcherListView.rowHeight)
        model.items = items
        model.selection = selection
        model.shown = min(items.count, max(room, fills ? 1 : 3))
        model.scroll()

        place(NSSize(width: min(620, screen.width - (fills ? Self.inset * 2 : 80)),
                     height: CGFloat(max(model.shown, 1)) * SwitcherListView.rowHeight + SwitcherListView.padding * 2 + header))
    }

    /// The list or grid at `size`; when filling, the panel is the whole area
    /// around it, a frosted surface over that part of the display.
    private func place(_ size: NSSize) {
        if model.size != size { model.size = size }
        let y = searchTop.map { max($0 - size.height, screen.minY) } ?? screen.midY - size.height / 2
        let frame = fills ? screen.integral
                          : NSRect(x: screen.midX - size.width / 2, y: y, width: size.width, height: size.height).integral
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    /// The tile `rows` above or below in the grid.
    func neighbour(of index: Int, rows: Int) -> Int {
        model.layout.neighbour(of: index, rows: rows)
    }

    /// Pixels across a tile's picture, for taking previews at the size shown.
    var previewWidth: Int {
        Int(model.layout.tile.width * scale)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        searchTop = nil
        query = ""
        model.query = ""
        panel.orderOut(nil)
    }

    fileprivate func index(at point: NSPoint) -> Int? {
        // From the panel to the list or grid, in its middle.
        let point = NSPoint(x: point.x - (panel.frame.width - model.size.width) / 2, y: point.y - (panel.frame.height - model.size.height) / 2 - header)
        guard !model.items.isEmpty else { return nil }
        if style == .previews { return model.layout.index(at: point) }
        let row = Int(floor((point.y - SwitcherListView.padding) / SwitcherListView.rowHeight))
        return (0..<model.shown).contains(row) ? model.first + row : nil
    }
}

/// Takes keys only when asked to, and says when it lets go of them.
private final class KeyPanel: NSPanel {
    var takesKeys = false
    var onKey: (NSEvent) -> Void = { _ in }
    var onResign: () -> Void = {}

    override var canBecomeKey: Bool { takesKeys }
    override func keyDown(with event: NSEvent) { onKey(event) }
    override func cancelOperation(_ sender: Any?) {}
    override func resignKey() {
        super.resignKey()
        onResign()
    }
}

/// Sits on top of the list and turns pointer positions into row indexes.
/// SwiftUI's own hover and tap handling needs a key window, which the panel never is.
private final class MouseCatcher: NSView {
    weak var panel: SwitcherPanel?
    private var scrolled: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    private func index(of event: NSEvent) -> Int? {
        panel?.index(at: convert(event.locationInWindow, from: nil))
    }

    // Only real movement selects, so the list can open under a resting pointer.
    override func mouseMoved(with event: NSEvent) {
        if let index = index(of: event) { panel?.onHover(index) }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = index(of: event) { panel?.onClick(index) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard panel?.style == .list else { return }
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * SwitcherListView.rowHeight
        let rows = Int(scrolled / SwitcherListView.rowHeight)
        guard rows != 0 else { return }
        scrolled -= CGFloat(rows) * SwitcherListView.rowHeight
        panel?.model.scroll(by: -rows)
    }
}
