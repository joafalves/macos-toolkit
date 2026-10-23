import AppKit
import SwiftUI

/// What the switcher list shows. Only `shown` rows are on screen at once; the
/// range follows the selection.
final class SwitcherListModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var selection = 0
    /// Index of the first row on screen.
    @Published var first = 0
    @Published var shown = 0
    @Published var style = SwitcherStyle.list
    /// Pictures for the grid, by window.
    @Published var previews: [CGWindowID: CGImage] = [:]
    @Published var layout = GridLayout()

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

    var body: some View {
        if model.style == .previews {
            SwitcherGridView(model: model)
        } else {
            SwitcherListView(model: model)
        }
    }
}

/// Where each tile of the grid goes. Tiles are as wide as the size setting
/// allows, and narrower when that's what it takes for every window to fit.
/// Rows are filled evenly and centred. Coordinates start at the top left.
struct GridLayout: Equatable {
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 14
    /// Height over width of a tile.
    static let aspect: CGFloat = 0.66
    static let minimumWidth: CGFloat = 96

    var tile = CGSize(width: 260, height: 260 * GridLayout.aspect)
    var columns = 1
    var count = 0

    init() {}

    init(count: Int, maxTileWidth: CGFloat, area: CGSize) {
        self.count = count
        let n = max(count, 1)
        var width = maxTileWidth
        var columns = 1
        while true {
            columns = max(1, min(n, Int((area.width - Self.padding * 2 + Self.spacing) / (width + Self.spacing))))
            let rows = Int(ceil(Double(n) / Double(columns)))
            let height = CGFloat(rows) * width * Self.aspect + CGFloat(rows - 1) * Self.spacing + Self.padding * 2
            if height <= area.height || width <= Self.minimumWidth { break }
            width -= 4
        }
        // As few columns as the same number of rows needs, so rows come out even.
        let rows = Int(ceil(Double(n) / Double(columns)))
        self.columns = Int(ceil(Double(n) / Double(rows)))
        tile = CGSize(width: width.rounded(), height: (width * Self.aspect).rounded())
    }

    var rows: Int { max(1, Int(ceil(Double(max(count, 1)) / Double(columns)))) }

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
                            number: index < 9 ? index + 1 : nil, selected: index == model.selection)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: model.layout.size.width, height: model.layout.size.height, alignment: .topLeading)
    }
}

/// How a preview tile looks: being chosen between (`--snapshot … look-…`).
enum PreviewTileLook: String, CaseIterable {
    /// The picture, the title in a dark bar across the bottom of the tile.
    case bar
    /// The window alone with its shadow, the title in plain text under it.
    case expose
    /// The picture across the top of a card, the title on the card under it.
    case card
    /// The picture, the title in a small frosted tag on its lower edge.
    case tag

    static var current = PreviewTileLook.bar
}

private struct PreviewTile: View {
    let item: SwitcherItem
    let image: CGImage?
    let number: Int?
    let selected: Bool

    var body: some View {
        switch PreviewTileLook.current {
        case .bar: bar
        case .expose: expose
        case .card: card
        case .tag: tag
        }
    }

    // MARK: Pieces

    /// The window, or the app's icon when there's no picture.
    @ViewBuilder
    private func picture(corner: CGFloat = 6, shadow: Bool = true) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: shadow ? 6 : 0, y: shadow ? 2 : 0)
        } else if let icon = item.icon {
            // Nothing to show of the window itself (minimized, hidden,
            // or not seen yet): its app instead.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
        }
    }

    private var icons: some View {
        Group {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            icons
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let symbol = item.stateSymbol {
                Image(systemName: symbol).font(.system(size: 10)).opacity(0.7)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func numberBadge(dark: Bool) -> some View {
        Group {
            if let number {
                Text(String(number))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(dark ? Color.white : Color.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(dark ? Color.black.opacity(0.45) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }

    // MARK: Looks

    private var bar: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
            picture()
                .padding(8)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            titleRow
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color.black.opacity(0.55))
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
        }
        .overlay(alignment: .topLeading) { numberBadge(dark: true).padding(6) }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3))
        .opacity(item.dimmed ? 0.55 : 1)
    }

    private var expose: some View {
        VStack(spacing: 7) {
            picture(corner: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 6) {
                numberBadge(dark: false)
                titleRow
            }
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.8))
            .frame(height: 20)
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 1.5))
        .opacity(item.dimmed ? 0.5 : 1)
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.primary.opacity(0.04)
                picture(corner: 5, shadow: false).padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 6) {
                titleRow
                Spacer(minLength: 4)
                numberBadge(dark: false)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 1))
        .opacity(item.dimmed ? 0.5 : 1)
    }

    private var tag: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
            picture(corner: 7)
                .padding(10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            titleRow
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
        .overlay(alignment: .topLeading) { numberBadge(dark: true).padding(8) }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5))
        .opacity(item.dimmed ? 0.5 : 1)
    }
}

extension SwitcherItem {
    /// What the row or tile marks a window that isn't simply open with.
    var stateSymbol: String? {
        switch state {
        case .window: return nil
        case .minimized: return "minus.circle"
        case .hiddenApp: return "eye.slash"
        case .noWindows: return "macwindow.badge.plus"
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
                SwitcherRow(item: item, number: index < 9 ? index + 1 : nil, selected: index == model.selection)
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
            .frame(width: 26, height: 26)
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
        }
        .font(.system(size: 14))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .opacity(item.dimmed ? 0.55 : 1)
        .padding(.horizontal, 8)
        .frame(height: SwitcherListView.rowHeight)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

    /// Margin between the panel and the edges of the area it fills.
    private static let inset: CGFloat = 12

    /// Set before `show`, for the session.
    var style = SwitcherStyle.list
    var previewSize = PreviewSize.medium
    var scale: CGFloat = 2

    func update(_ items: [SwitcherItem], selection: Int) {
        guard isVisible else { return }
        model.style = style
        if style == .previews {
            let area = fills ? CGSize(width: screen.width - Self.inset * 2, height: screen.height - Self.inset * 2)
                             : CGSize(width: screen.width * 0.92, height: screen.height * 0.8)
            let layout = GridLayout(count: items.count, maxTileWidth: previewSize.maxTileWidth, area: area)
            model.items = items
            model.selection = selection
            if layout != model.layout { model.layout = layout }
            place(layout.size)
            return
        }
        let height = fills ? screen.height - Self.inset * 2 : screen.height * 0.7
        let room = Int((height - SwitcherListView.padding * 2) / SwitcherListView.rowHeight)
        model.items = items
        model.selection = selection
        model.shown = min(items.count, max(room, fills ? 1 : 3))
        model.scroll()

        place(NSSize(width: min(620, screen.width - (fills ? Self.inset * 2 : 80)),
                     height: CGFloat(max(model.shown, 1)) * SwitcherListView.rowHeight + SwitcherListView.padding * 2))
    }

    private func place(_ size: NSSize) {
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height).integral
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
        panel.orderOut(nil)
    }

    fileprivate func index(at point: NSPoint) -> Int? {
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
