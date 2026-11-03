import AppKit

/// Which display the switcher opens on.
enum SwitcherPlacement: String, Codable, CaseIterable {
    /// The primary display, the one at the origin of the arrangement.
    case mainScreen
    case mouse
    /// The display with the window that has the keyboard.
    case activeWindow
}

/// Which windows the switcher lists.
enum SwitcherWindows: String, Codable, CaseIterable {
    case all
    /// Only those on the display it opens on, by where most of each is.
    /// The main display shows them all: it's the same display every time.
    case display
}

/// A list of rows, or a grid of window previews.
enum SwitcherStyle: String, Codable, CaseIterable {
    case list, previews
}

/// The largest a preview tile gets: narrower only where the display has no
/// room for one. Fit makes them as large as the rows allow.
enum PreviewSize: String, Codable, CaseIterable {
    case small, medium, large
    /// As large as the display allows for the windows, in as many rows as the grid has.
    case fit

    var title: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        case .fit: return String(localized: "Fit")
        }
    }

    /// Points.
    var maxTileWidth: CGFloat {
        switch self {
        case .small: return 180
        case .medium: return 260
        case .large: return 360
        case .fit: return 620
        }
    }
}

/// How the previews are laid out: rows of them, or one row that scrolls
/// sideways, with dots for where it is.
enum PreviewLayout: String, Codable, CaseIterable {
    case grid, row

    var title: String {
        switch self {
        case .grid: return String(localized: "Grid")
        case .row: return String(localized: "One row")
        }
    }
}

/// Where a preview shows its app's icon.
enum PreviewIcons: String, Codable, CaseIterable {
    /// 24 pt in the bar along the bottom, with the app's name and the title on one line.
    case small
    /// 32 pt in the bar, with the title below the app's name.
    case medium
    /// 48 pt in the top right corner, over the picture, with the app's badge.
    case large
}

/// How up to date the previews are when the switcher opens.
enum PreviewFreshness: String, Codable, CaseIterable {
    /// The last picture of each window at once, replaced by a new one a moment later.
    case cached
    /// Only new pictures: the app's icon until it arrives.
    case fresh
    /// New pictures a few times a second while the switcher is open.
    case live

    var title: String {
        switch self {
        case .cached: return String(localized: "Cached")
        case .fresh: return String(localized: "Fresh")
        case .live: return String(localized: "Live")
        }
    }
}

/// How much of a display's width the grid can use, in percent.
enum GridWidth {
    /// Low enough for four tiles across even on a 5K ultrawide.
    static let range = 20.0...92.0
    /// A display starts with room for this many tiles across.
    static let across = 4

    /// The narrowest that has room for `across` tiles of this width.
    static func suggested(points: Double, tile: CGFloat) -> Double {
        let needed = Double(GridLayout.padding * 2 + CGFloat(across) * tile + CGFloat(across - 1) * GridLayout.spacing)
        return min(max((needed / max(points, 1) * 100).rounded(.up), range.lowerBound), range.upperBound)
    }
}

struct SwitcherConfig: Codable, Equatable {
    /// When off, the switcher is gone and ⌘Tab is macOS's again.
    var enabled = true
    /// Its modifiers are the ones held to keep the list open. macOS's own
    /// ⌘Tab is only switched off while this is ⌘Tab.
    var shortcut = Shortcut.commandTab
    /// The same list, with only the windows of the app in front. Can be cleared.
    var appShortcut = Shortcut.commandAboveTab
    var placement = SwitcherPlacement.mainScreen
    var windows = SwitcherWindows.all
    /// What's listed, all told: on the main display, every window.
    var shownWindows: SwitcherWindows { placement == .mainScreen ? .all : windows }
    /// When the list or grid appears, the window before the current one is
    /// selected, as in macOS's own ⌘Tab. When off, the current one is. A quick
    /// ⌘Tab that never shows them goes back to the previous window either way.
    var startOnPrevious = true
    var style = SwitcherStyle.previews
    var previewSize = PreviewSize.medium
    var previewFreshness = PreviewFreshness.cached
    var previewIcons = PreviewIcons.small
    var previewLayout = PreviewLayout.grid
    /// How wide the grid gets on each display, by its UUID, where it's been set.
    var gridWidths: [String: Double] = [:]
    /// For every other display, once it's been applied to all of them.
    /// Otherwise a display starts with room for four tiles across.
    var gridWidthForAll: Double?
    /// The most rows of the grid on screen; with more windows it scrolls.
    var gridRows = SwitcherConfig.gridRowsDefault
    static let gridRowsRange = 2...6
    static let gridRowsDefault = 3
    /// The grid's first row in the middle of the display, where a grid of one
    /// row is, and the rest below it, rather than the whole grid centred: the
    /// first windows are always in the same place.
    var firstRowInMiddle = false
    /// A flat colour per app on its rows, here and in Window Layout's offers.
    var appColors = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        shortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .shortcut)) ?? .commandTab
        appShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .appShortcut)) ?? .commandAboveTab
        placement = (try? c.decodeIfPresent(SwitcherPlacement.self, forKey: .placement)) ?? .mainScreen
        windows = (try? c.decodeIfPresent(SwitcherWindows.self, forKey: .windows)) ?? .all
        startOnPrevious = try c.decodeIfPresent(Bool.self, forKey: .startOnPrevious) ?? true
        style = (try? c.decodeIfPresent(SwitcherStyle.self, forKey: .style)) ?? .previews
        previewSize = (try? c.decodeIfPresent(PreviewSize.self, forKey: .previewSize)) ?? .medium
        previewFreshness = (try? c.decodeIfPresent(PreviewFreshness.self, forKey: .previewFreshness)) ?? .cached
        previewIcons = (try? c.decodeIfPresent(PreviewIcons.self, forKey: .previewIcons)) ?? .small
        previewLayout = (try? c.decodeIfPresent(PreviewLayout.self, forKey: .previewLayout)) ?? .grid
        gridWidths = (try? c.decodeIfPresent([String: Double].self, forKey: .gridWidths)) ?? [:]
        gridWidthForAll = try? c.decodeIfPresent(Double.self, forKey: .gridWidthForAll)
        gridRows = min(max((try? c.decodeIfPresent(Int.self, forKey: .gridRows)) ?? Self.gridRowsDefault, Self.gridRowsRange.lowerBound), Self.gridRowsRange.upperBound)
        firstRowInMiddle = try c.decodeIfPresent(Bool.self, forKey: .firstRowInMiddle) ?? false
        appColors = try c.decodeIfPresent(Bool.self, forKey: .appColors) ?? false
    }

    func gridWidth(for display: LayoutDisplay) -> Double {
        // Fit's tiles are as large as there's room for: four across goes by Large's.
        let tile = (previewSize == .fit ? PreviewSize.large : previewSize).maxTileWidth
        let chosen = gridWidths[display.uuid] ?? gridWidthForAll ?? GridWidth.suggested(points: display.usable.width, tile: tile)
        return min(max(chosen, GridWidth.range.lowerBound), GridWidth.range.upperBound)
    }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("switcher.json")
    }

    static func load() -> SwitcherConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return SwitcherConfig() }
        return (try? JSONDecoder().decode(SwitcherConfig.self, from: data)) ?? SwitcherConfig()
    }

    func save() {
        let url = SwitcherConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
