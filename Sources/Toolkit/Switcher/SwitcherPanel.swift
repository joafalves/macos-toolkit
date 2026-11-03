import AppKit
import SwiftUI

/// What the switcher list shows. Only `shown` rows are on screen at once; the
/// range follows the selection.
final class SwitcherListModel: ObservableObject {
    /// What the list or grid takes up, in the middle of the panel.
    @Published var size = CGSize.zero
    @Published var items: [SwitcherItem] = []
    @Published var selection = 0
    /// The row under the pointer, when that isn't what selects: shown apart
    /// from the selection, which stays the keyboard's.
    @Published var hovered: Int?
    /// Index of the first row on screen.
    @Published var first = 0
    @Published var shown = 0
    @Published var style = SwitcherStyle.list
    /// Pictures for the grid, by window.
    @Published var previews: [CGWindowID: CGImage] = [:]
    @Published var layout = GridLayout()
    @Published var previewIcons = PreviewIcons.small
    /// What's been typed. Shows above the rows, once there's something.
    @Published var query = ""
    /// The numbers on apps' icons, by the file name of the app.
    @Published var badges: [String: String] = [:]
    /// Apps making sound, by process (`AudioActivity`).
    @Published var sounding: Set<pid_t> = []

    func badge(of item: SwitcherItem) -> String? {
        item.appURL.flatMap { badges[$0.lastPathComponent] }
    }

    func sounds(_ item: SwitcherItem) -> Bool {
        !sounding.isEmpty && sounding.contains(item.pid)
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
/// allows, narrower only where a row of them doesn't fit, and the switcher's
/// grid has at most `maxRows` rows on screen: with more windows it scrolls a
/// row at a time, with dots down its right side. Fit, and a grid with no such
/// limit (Window Layout's suggestions), make them as large as fits the rows.
/// The columns come from the width alone, not from how many windows there
/// are, and rows fill from the left, the last one too: a window's place
/// depends only on its turn in the list, so the second is always in the same
/// spot. (Rows evened out moved every window when one opened or closed.)
/// Coordinates start at the top left.
struct GridLayout: Equatable {
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 14
    /// Height over width of a tile's picture.
    static let aspect: CGFloat = 0.66
    /// What a tile has beyond that, so its bar's two lines don't take from the picture.
    static let extraHeight: CGFloat = 14
    static let minimumWidth: CGFloat = 96
    /// Under the one row when it scrolls: its dots.
    static let dotsHeight: CGFloat = 22
    /// Beside the grid when it scrolls, on the right: its dots.
    static let dotsWidth: CGFloat = 24

    var tile = CGSize(width: 260, height: 260 * GridLayout.aspect + GridLayout.extraHeight)
    var columns = 1
    var count = 0
    /// One row, `columns` tiles of it on screen at a time, from `first`.
    var oneRow = false
    /// Rows of the grid on screen at a time.
    var shownRows = 1
    /// The first on screen: a tile of the one row, or a row of the grid.
    var first = 0

    init() {}

    /// With `belowMiddle`, the first row is centred where the area's middle
    /// is, and the grid can reach that far below it, not the area's height.
    /// With no `maxRows`, tiles shrink to fit every window, down to
    /// `minTileWidth`; past that, it scrolls.
    init(count: Int, maxTileWidth: CGFloat, area: CGSize, oneRow: Bool = false, maxRows: Int? = nil, fillRows: Bool = false,
         belowMiddle: CGFloat? = nil, minTileWidth: CGFloat = GridLayout.minimumWidth) {
        self.count = count
        self.oneRow = oneRow
        let n = max(count, 1)
        let maxRows = oneRow ? nil : maxRows
        func tileHeight(_ width: CGFloat) -> CGFloat { width * Self.aspect + Self.extraHeight }
        func height(rows: Int, width: CGFloat, dots: Bool) -> CGFloat {
            CGFloat(rows) * tileHeight(width) + CGFloat(rows - 1) * Self.spacing + Self.padding * 2 + (dots ? Self.dotsHeight : 0)
        }
        func room(_ width: CGFloat) -> CGFloat {
            belowMiddle.map { min($0 + Self.padding + tileHeight(width) / 2, area.height) } ?? area.height
        }
        // Never wider than the area: one tile would be, with a narrow one.
        var width = max(min(maxTileWidth, area.width - Self.padding * 2), Self.minimumWidth)
        var columns = 1, rows = 1
        while true {
            columns = min(n, Self.across(area.width, tile: width))
            rows = oneRow ? 1 : Int(ceil(Double(n) / Double(columns)))
            // What has to fit: every row; with a limit, that many (Fit) or one.
            let needed = maxRows.map { fillRows ? min(rows, $0) : 1 } ?? rows
            if height(rows: needed, width: width, dots: oneRow && columns < n) <= room(width) || width <= Self.minimumWidth { break }
            if width <= minTileWidth, height(rows: 1, width: width, dots: false) <= room(width) { break }
            width -= 4
        }
        self.columns = columns
        tile = CGSize(width: width.rounded(), height: tileHeight(width).rounded())
        if !oneRow {
            let fitting = max(1, Int((room(width) - Self.padding * 2 + Self.spacing) / (tileHeight(width) + Self.spacing)))
            shownRows = min(rows, maxRows ?? rows, fitting)
        }
    }

    var rows: Int { oneRow ? 1 : max(1, Int(ceil(Double(max(count, 1)) / Double(columns)))) }

    /// More windows than are on screen.
    var scrolls: Bool { oneRow ? count > columns : rows > shownRows }

    /// What `first` counts, and how many of them are on screen.
    private var units: Int { oneRow ? count : rows }
    private var unitsShown: Int { oneRow ? columns : shownRows }

    /// The unit a tile is in: itself in the one row, its row in the grid.
    func unit(of index: Int) -> Int { oneRow ? index : index / columns }

    /// How many tiles of this width fit across `width`, at most.
    static func across(_ width: CGFloat, tile: CGFloat) -> Int {
        max(1, Int((width - padding * 2 + spacing) / (tile + spacing)))
    }

    /// The tiles' part, without the dots.
    var tilesSize: CGSize {
        let rows = oneRow ? 1 : shownRows
        return CGSize(width: CGFloat(columns) * tile.width + CGFloat(columns - 1) * Self.spacing + Self.padding * 2,
                      height: CGFloat(rows) * tile.height + CGFloat(rows - 1) * Self.spacing + Self.padding * 2)
    }

    /// The grid's dots take from the margin on its right: the columns stay as they are.
    var size: CGSize {
        let tiles = tilesSize
        return CGSize(width: tiles.width + (scrolls && !oneRow ? Self.dotsWidth : 0), height: tiles.height + (scrolls && oneRow ? Self.dotsHeight : 0))
    }

    private func tiles(inRow row: Int) -> Int {
        min(columns, count - row * columns)
    }

    /// Where a tile is; off to the side, or above or below, for one scrolled away.
    func frame(of index: Int) -> CGRect {
        let row = oneRow ? 0 : index / columns - first, column = oneRow ? index - first : index % columns
        let x = Self.padding + CGFloat(column) * (tile.width + Self.spacing)
        let y = Self.padding + CGFloat(row) * (tile.height + Self.spacing)
        return CGRect(x: x, y: y, width: tile.width, height: tile.height)
    }

    /// The tiles on screen: the stretch of the one row, or the grid's rows from `first`.
    var onScreen: Range<Int> {
        oneRow ? first..<min(count, first + columns) : first * columns..<min(count, (first + shownRows) * columns)
    }

    func index(at point: CGPoint) -> Int? {
        onScreen.first { frame(of: $0).contains(point) }
    }

    /// Scrolled so the selection is on screen, with a tile or row beside it on
    /// the side it's heading for when there's room for one: what comes next shows.
    func showing(_ selection: Int) -> GridLayout {
        guard scrolls else { var layout = self; layout.first = 0; return layout }
        let unit = unit(of: selection), margin = unitsShown >= 3 ? 1 : 0
        var first = first
        if unit < first + margin { first = unit - margin }
        if unit > first + unitsShown - 1 - margin { first = unit - unitsShown + 1 + margin }
        return scrolled(to: first)
    }

    func scrolled(to first: Int) -> GridLayout {
        var layout = self
        layout.first = scrolls ? min(max(first, 0), units - unitsShown) : 0
        return layout
    }

    /// The tile above (`rows` -1) or below (+1), the one nearest across.
    func neighbour(of index: Int, rows step: Int) -> Int {
        let row = index / columns + step
        guard !oneRow, row >= 0, row < rows else { return index }
        let x = frame(of: index).midX
        let candidates = (row * columns)..<(row * columns + tiles(inRow: row))
        return candidates.min { abs(frame(of: $0).midX - x) < abs(frame(of: $1).midX - x) } ?? index
    }
}

struct SwitcherGridView: View {
    @ObservedObject var model: SwitcherListModel

    var body: some View {
        let layout = model.layout, tiles = layout.tilesSize
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        let frame = layout.frame(of: index)
                        PreviewTile(item: item, image: item.window.flatMap { model.previews[$0] },
                                    number: index < 9 ? index + 1 : nil, selected: index == model.selection,
                                    hovered: index == model.hovered && index != model.selection, badge: model.badge(of: item),
                                    sounds: model.sounds(item),
                                    width: frame.width, icons: model.previewIcons)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: tiles.width, height: tiles.height, alignment: .topLeading)
                // It slides only while it moves, so nothing animates at rest.
                .animation(.easeOut(duration: 0.18), value: layout.first)
                .clipped()
                .mask {
                    if layout.scrolls {
                        RowEdges(vertical: !layout.oneRow, before: layout.onScreen.lowerBound > 0, after: layout.onScreen.upperBound < layout.count)
                    } else {
                        Rectangle()
                    }
                }
                if layout.scrolls, !layout.oneRow {
                    // A dot for each row, down the side, as the grid goes.
                    RowDots(count: layout.rows, onScreen: layout.unit(of: layout.onScreen.lowerBound)..<layout.unit(of: layout.onScreen.upperBound - 1) + 1,
                            selection: layout.unit(of: model.selection), vertical: true, perDot: layout.columns, windows: layout.count)
                        .frame(width: GridLayout.dotsWidth)
                        // Into the grid's margin, nearer the tiles than the edge.
                        .offset(x: -GridLayout.padding / 3)
                }
            }
            if layout.scrolls, layout.oneRow {
                RowDots(count: layout.count, onScreen: layout.onScreen, selection: model.selection, windows: layout.count)
                    .frame(height: GridLayout.dotsHeight, alignment: .top)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }
}

/// The one row fades out at an end with more beyond it, and the grid at
/// its top or bottom.
private struct RowEdges: View {
    let vertical: Bool
    let before: Bool
    let after: Bool
    // Past the margin and a little way into the tile at the end.
    private static let fade: CGFloat = 64

    var body: some View {
        if vertical {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: before ? Self.fade : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: after ? Self.fade : 0)
            }
        } else {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: before ? Self.fade : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: after ? Self.fade : 0)
            }
        }
    }
}

/// Where the one row is: a dot for each window, below it; or for the grid,
/// a dot for each row, down its side. Brighter for those on screen, the
/// selection's long and in the accent colour. With more than `most`, only
/// those around what's on screen, the outer two smaller where it goes on,
/// and how many more windows beside them.
private struct RowDots: View {
    let count: Int
    let onScreen: Range<Int>
    let selection: Int
    var vertical = false
    /// Windows for each dot, and in all.
    var perDot = 1
    var windows: Int
    static let most = 11

    /// What gets a dot.
    private var dotted: Range<Int> {
        guard count > Self.most else { return 0..<count }
        let middle = Double(onScreen.lowerBound + onScreen.upperBound) / 2
        let from = min(max(Int((middle - Double(Self.most) / 2).rounded()), 0), count - Self.most)
        return from..<from + Self.most
    }

    private func scale(_ index: Int) -> CGFloat {
        guard index != selection else { return 1 }
        let range = dotted
        let fromEnd = min(range.lowerBound > 0 ? index - range.lowerBound : .max, range.upperBound < count ? range.upperBound - 1 - index : .max)
        return fromEnd == 0 ? 0.45 : fromEnd == 1 ? 0.7 : 1
    }

    var body: some View {
        let range = dotted
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        let dots = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        stack {
            Text(verbatim: range.lowerBound > 0 ? "+\(range.lowerBound * perDot)" : "")
                .fixedSize()
                .frame(minWidth: vertical ? nil : 26, alignment: .trailing)
            dots {
                ForEach(range, id: \.self) { index in
                    let long: CGFloat = index == selection ? 14 : 6
                    Capsule()
                        .fill(index == selection ? Color.accentColor : Color.primary.opacity(onScreen.contains(index) ? 0.55 : 0.2))
                        .frame(width: vertical ? 6 : long, height: vertical ? long : 6)
                        .scaleEffect(scale(index))
                }
            }
            Text(verbatim: range.upperBound < count ? "+\(windows - range.upperBound * perDot)" : "")
                .fixedSize()
                .frame(minWidth: vertical ? nil : 26, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.18), value: selection)
        .animation(.easeOut(duration: 0.18), value: onScreen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sizes app icons are drawn sharp at, since icons are made for them.
/// Anything between is scaled and comes out soft, most of all on a 1x display:
/// measured at 28 pt, a third as sharp as at 32 pt.
private enum AppIconSize {
    static let tiny: CGFloat = 16, small: CGFloat = 24, medium: CGFloat = 32

    /// 48 pt, or the sharp size nearest a share of the tile if it's too narrow for that.
    static func large(onTile width: CGFloat) -> CGFloat {
        [24, 32, 48].min { abs($0 - width * 0.18) < abs($1 - width * 0.18) } ?? 48
    }
}

private struct PreviewTile: View {
    let item: SwitcherItem
    let image: CGImage?
    let number: Int?
    let selected: Bool
    let hovered: Bool
    let badge: String?
    let sounds: Bool
    let width: CGFloat
    let icons: PreviewIcons

    /// As much as its icon and text need. What that saves goes to the picture:
    /// the tile stays the same.
    private var barHeight: CGFloat {
        switch icons {
        case .small: return 30
        case .medium: return 40
        case .large: return 26
        }
    }

    /// The icon in the bar, smaller only on a tile too narrow for it.
    private var barIcon: CGFloat {
        width < 140 ? AppIconSize.tiny : icons == .small ? AppIconSize.small : AppIconSize.medium
    }

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
                        .padding(.bottom, barHeight - 4)
                } else if let icon = item.icon {
                    // Nothing to show of the window itself (minimized, hidden,
                    // or not seen yet): its app instead.
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .padding(.bottom, barHeight - 4)
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
        .overlay(alignment: .bottomTrailing) {
            // The picture's bottom right, above the bar: the Mixer's bars, on
            // a dark chip so they read over any window.
            if sounds {
                PlayingBars(color: .white, scale: 1.2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.trailing, 6)
                    .padding(.bottom, barHeight + 6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? (item.tint == nil ? Color.accentColor : Color.primary)
                                   : hovered ? Color.primary.opacity(0.45) : Color.clear, lineWidth: selected ? 3 : 2))
        // With a colour, only the content fades: the colour stays the app's.
        .opacity(item.tint == nil && item.dimmed ? 0.55 : 1)
    }

    /// The app and the window's title, across the bottom of the tile: the app
    /// is what the eye looks for, the title which of its windows. Below it beside
    /// a medium icon, which has the height; otherwise on the same line, the title
    /// to the right. Nothing more to say for a row that stands for an app, or a
    /// window that's only named after it.
    private var label: some View {
        HStack(spacing: 8) {
            if icons != .large, let icon = item.icon {
                // Less after it, for the icon's own empty margin (2 pt at 24 pt):
                // the name then sits as far from it as the icon from the edge.
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: barIcon, height: barIcon)
                    .padding(.trailing, -4)
            }
            let name = Text(item.appName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if icons == .medium {
                VStack(alignment: .leading, spacing: 0) {
                    name
                    if let title = item.titleBesideApp { windowTitle(title) }
                }
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // The name whole if it can be: on a narrow tile, it's all there's room for.
                    name.layoutPriority(1)
                    Spacer(minLength: 0)
                    if let title = item.titleBesideApp, width >= Self.widthForTitleBeside + (icons == .small ? barIcon + 8 : 0) {
                        windowTitle(title)
                    }
                }
            }
            if let symbol = item.stateSymbol {
                Image(systemName: symbol).font(.system(size: 11))
            }
        }
        .foregroundStyle(.white)
        .opacity(item.tint != nil && item.dimmed ? 0.65 : 1)
        // An icon has 2 to 3 pt of empty margin of its own (measured): less here,
        // so the gap on its left looks like the one after the text on the right.
        .padding(.leading, icons != .large && item.icon != nil ? 6 : 8)
        .padding(.trailing, 8)
        .frame(height: barHeight)
        .background(item.tint.map(AppPalette.selected) ?? Color.black.opacity(0.55))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
    }

    private static let widthForTitleBeside: CGFloat = 150

    private func windowTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(0.7)
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
                SwitcherRow(item: item, number: index < 9 ? index + 1 : nil, selected: index == model.selection,
                            hovered: index == model.hovered && index != model.selection, badge: model.badge(of: item),
                            sounds: model.sounds(item))
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
    let hovered: Bool
    let badge: String?
    let sounds: Bool

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
            // As in the Mixer, beside the app. White where the row has a colour.
            if sounds { PlayingBars(color: selected || item.tint != nil ? .white : nil) }
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
            } else if hovered {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.1))
            }
        }
        .overlay {
            // A coloured row has its fill already: an outline says it's under the pointer.
            if hovered, item.tint != nil {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5)
                    .padding(.vertical, 1.5)
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
    /// The pointer moved onto the row at this index, when `hoverSelects`.
    var onHover: (Int) -> Void = { _ in }
    private weak var catcher: MouseCatcher?
    /// Whether the row under the pointer is the selection. When not, it's
    /// only marked, and the keys go on from where they left the selection.
    var hoverSelects = true
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
        catcher = mouse
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

    /// The switcher's grid or row on a display of this size, as its settings say.
    /// With the first row in the middle, the grid goes as far below the middle
    /// as `gridArea` does.
    static func switcherGrid(count: Int, size: PreviewSize, layout: PreviewLayout, rows: Int, firstRowInMiddle: Bool,
                             on display: CGSize, percent: Double) -> GridLayout {
        GridLayout(count: count, maxTileWidth: size.maxTileWidth, area: gridArea(on: display, percent: percent), oneRow: layout == .row,
                   maxRows: rows, fillRows: size == .fit, belowMiddle: firstRowInMiddle && layout == .grid ? display.height * 0.4 : nil)
    }

    /// Margin between the panel and the edges of the area it fills.
    private static let inset: CGFloat = 12
    /// Window Layout's suggestions shrink to fit everything, but not past the
    /// switcher's own default size, where they scroll instead.
    static let suggestionsMinTileWidth = PreviewSize.medium.maxTileWidth

    /// Set before `show`, for the session.
    var style = SwitcherStyle.list
    var previewSize = PreviewSize.medium
    /// The switcher's. Window Layout's suggestions fill an area instead, with
    /// as many rows as fit there.
    var previewLayout = PreviewLayout.grid
    var gridRows = SwitcherConfig.gridRowsDefault
    var firstRowInMiddle = false
    var scale: CGFloat = 2
    /// The switcher's setting, for Window Layout's suggestions as well.
    static var previewIcons = PreviewIcons.small
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
            var layout = fills
                ? GridLayout(count: items.count, maxTileWidth: previewSize.maxTileWidth,
                             area: CGSize(width: screen.width - Self.inset * 2, height: screen.height - Self.inset * 2),
                             minTileWidth: Self.suggestionsMinTileWidth)
                : Self.switcherGrid(count: items.count, size: previewSize, layout: previewLayout, rows: gridRows,
                                    firstRowInMiddle: firstRowInMiddle, on: screen.size, percent: gridWidth)
            // It stays scrolled where it was, as far as the selection allows.
            layout = layout.scrolled(to: model.layout.oneRow == layout.oneRow ? model.layout.first : 0).showing(selection)
            if model.items.map(\.id) != items.map(\.id) { model.hovered = nil }
            model.items = items
            model.selection = selection
            if layout != model.layout { model.layout = layout }
            // The first row's middle on the display's, where a grid of one row has it.
            let top = firstRowInMiddle && !layout.oneRow ? screen.midY + GridLayout.padding + layout.tile.height / 2 : nil
            place(NSSize(width: layout.size.width, height: layout.size.height + header), top: top, centred: layout.tilesSize.width)
            return
        }
        let height = fills ? screen.height - Self.inset * 2 : screen.height * 0.7
        let room = Int((height - header - SwitcherListView.padding * 2) / SwitcherListView.rowHeight)
        if model.items.map(\.id) != items.map(\.id) { model.hovered = nil }
        model.items = items
        model.selection = selection
        model.shown = min(items.count, max(room, fills ? 1 : 3))
        model.scroll()

        place(NSSize(width: min(620, screen.width - (fills ? Self.inset * 2 : 80)),
                     height: CGFloat(max(model.shown, 1)) * SwitcherListView.rowHeight + SwitcherListView.padding * 2 + header))
    }

    /// The list or grid at `size`, from `top` if given, and centred across
    /// on its first `centred` points (the grid's tiles, not its dots, so they
    /// don't move when it starts to scroll); when filling, the panel is the
    /// whole area around it, a frosted surface over that part of the display.
    private func place(_ size: NSSize, top: CGFloat? = nil, centred: CGFloat? = nil) {
        if model.size != size { model.size = size }
        let y = searchTop.map { max($0 - size.height, screen.minY) }
            ?? top.map { max(min($0, screen.maxY) - size.height, screen.minY) }
            ?? screen.midY - size.height / 2
        let frame = fills ? screen.integral
                          : NSRect(x: screen.midX - (centred ?? size.width) / 2, y: y, width: size.width, height: size.height).integral
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
        model.hovered = nil
        // The next time starts at the start.
        model.layout.first = 0
        // Closed under the pointer: no hand left behind over whatever's there.
        catcher?.pointing(false)
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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    private func index(of event: NSEvent) -> Int? {
        panel?.index(at: convert(event.locationInWindow, from: nil))
    }

    // Only real movement counts, so the list can open under a resting pointer.
    override func mouseMoved(with event: NSEvent) {
        guard let panel else { return }
        let index = index(of: event)
        pointing(index != nil)
        if panel.hoverSelects {
            if let index { panel.onHover(index) }
        } else if panel.model.hovered != index {
            panel.model.hovered = index
        }
    }

    override func mouseExited(with event: NSEvent) {
        pointing(false)
        if panel?.model.hovered != nil { panel?.model.hovered = nil }
    }

    private var pointingHand = false

    /// The hand over a window, as over a link: a click goes there. The panel
    /// is never in the active app, which macOS doesn't let set the cursor
    /// unless asked, as the capture overlay does.
    func pointing(_ on: Bool) {
        guard on != pointingHand else { return }
        pointingHand = on
        if on { CaptureCursor.allowInBackground() }
        (on ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        if let index = index(of: event) { panel?.onClick(index) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let panel else { return }
        if panel.style == .previews {
            // The one row a tile at a time, the grid a row, either way the wheel or the trackpad goes.
            let layout = panel.model.layout
            guard layout.scrolls else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
            let step = (layout.oneRow ? layout.tile.width : layout.tile.height) + GridLayout.spacing
            scrolled += event.hasPreciseScrollingDeltas ? delta : delta * step
            let steps = Int(scrolled / step)
            guard steps != 0 else { return }
            scrolled -= CGFloat(steps) * step
            panel.model.layout = layout.scrolled(to: layout.first + steps)
            return
        }
        guard panel.style == .list else { return }
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * SwitcherListView.rowHeight
        let rows = Int(scrolled / SwitcherListView.rowHeight)
        guard rows != 0 else { return }
        scrolled -= CGFloat(rows) * SwitcherListView.rowHeight
        panel.model.scroll(by: -rows)
    }
}
