import CoreGraphics
import Foundation

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

/// The largest a preview tile gets. With many windows they shrink to fit.
enum PreviewSize: String, Codable, CaseIterable {
    case small, medium, large
    /// As large as the display allows for the number of windows.
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

struct SwitcherConfig: Codable, Equatable {
    /// When off, the switcher is gone and ⌘Tab is macOS's again.
    var enabled = true
    /// Its modifiers are the ones held to keep the list open. macOS's own
    /// ⌘Tab is only switched off while this is ⌘Tab.
    var shortcut = Shortcut.commandTab
    var placement = SwitcherPlacement.mainScreen
    var windows = SwitcherWindows.all
    /// What's listed, all told: on the main display, every window.
    var shownWindows: SwitcherWindows { placement == .mainScreen ? .all : windows }
    /// When the list or grid appears, the window before the current one is
    /// selected, as in macOS's own ⌘Tab. When off, the current one is. A quick
    /// ⌘Tab that never shows them goes back to the previous window either way.
    var startOnPrevious = true
    var style = SwitcherStyle.list
    var previewSize = PreviewSize.medium
    var previewFreshness = PreviewFreshness.cached

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        shortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .shortcut)) ?? .commandTab
        placement = (try? c.decodeIfPresent(SwitcherPlacement.self, forKey: .placement)) ?? .mainScreen
        windows = (try? c.decodeIfPresent(SwitcherWindows.self, forKey: .windows)) ?? .all
        startOnPrevious = try c.decodeIfPresent(Bool.self, forKey: .startOnPrevious) ?? true
        style = (try? c.decodeIfPresent(SwitcherStyle.self, forKey: .style)) ?? .list
        previewSize = (try? c.decodeIfPresent(PreviewSize.self, forKey: .previewSize)) ?? .medium
        previewFreshness = (try? c.decodeIfPresent(PreviewFreshness.self, forKey: .previewFreshness)) ?? .cached
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
