import Foundation

/// What can have a place in the menu bar item, in the order it's set.
enum MenuBarTool: String, Codable, CaseIterable {
    case toolkit, stats, capture, awake, mixer, mouse, layout

    /// The order before it could be set.
    static let defaultOrder: [MenuBarTool] = allCases

    /// Every tool once: unknown and repeated ones dropped, and one missing (an
    /// older file, or a tool added since) put back at its default place.
    static func complete(_ order: [MenuBarTool]) -> [MenuBarTool] {
        var result: [MenuBarTool] = []
        for tool in order where !result.contains(tool) { result.append(tool) }
        for (index, tool) in defaultOrder.enumerated() where !result.contains(tool) {
            result.insert(tool, at: min(index, result.count))
        }
        return result
    }
}

/// The language the app shows, when it's not the one macOS picks for it.
enum AppLanguage: String, Codable, CaseIterable {
    case system, english = "en", portuguese = "pt-PT"

    /// Each language in its own words, as macOS lists them, so it can be
    /// found whatever language the app is in.
    var title: String {
        switch self {
        case .system: return String(localized: "Same as macOS")
        case .english: return "English"
        case .portuguese: return "Português (Portugal)"
        }
    }

    /// The one the app was started in. A change takes a restart: the text
    /// already shown was looked up when it was drawn.
    private(set) static var launched = AppLanguage.system

    /// At launch, before any text is looked up: macOS picks the app's
    /// translations from its own AppleLanguages, then from the system's.
    static func apply(_ language: AppLanguage) {
        launched = language
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

/// The app's own settings, apart from any tool's.
struct GeneralConfig: Codable, Equatable {
    /// Points between two parts of the menu bar item, the hairline included
    /// half on each side; also what the item keeps at its ends.
    var menuBarSpacing: Double = 12

    static let menuBarSpacings: ClosedRange<Double> = 4...24
    /// What goes between two tools in the menu bar item.
    var menuBarSeparator = MenuBarSeparator.pipe
    /// What goes between one tool's own parts (System Stats' stats): a dot
    /// by default, so they read as one tool.
    var menuBarToolSeparator = MenuBarToolSeparator.dot
    /// Left to right. Always every tool, shown or not, so each keeps its place.
    var menuBarOrder = MenuBarTool.defaultOrder
    /// Looks for a new version at launch and once a day; it only says so.
    var checkForUpdates = true
    var language = AppLanguage.system

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Within the slider's range: a file edited by hand can say anything.
        let spacing = try c.decodeIfPresent(Double.self, forKey: .menuBarSpacing) ?? 12
        menuBarSpacing = min(max(spacing, Self.menuBarSpacings.lowerBound), Self.menuBarSpacings.upperBound)
        menuBarSeparator = (try? c.decodeIfPresent(MenuBarSeparator.self, forKey: .menuBarSeparator)) ?? .pipe
        menuBarToolSeparator = (try? c.decodeIfPresent(MenuBarToolSeparator.self, forKey: .menuBarToolSeparator)) ?? .dot
        let order = (try? c.decodeIfPresent([String].self, forKey: .menuBarOrder)) ?? nil
        menuBarOrder = MenuBarTool.complete((order ?? []).compactMap(MenuBarTool.init(rawValue:)))
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
        language = (try? c.decodeIfPresent(AppLanguage.self, forKey: .language)) ?? .system
    }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("general.json")
    }

    static func load() -> GeneralConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return GeneralConfig() }
        return (try? JSONDecoder().decode(GeneralConfig.self, from: data)) ?? GeneralConfig()
    }

    func save() {
        let url = GeneralConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
