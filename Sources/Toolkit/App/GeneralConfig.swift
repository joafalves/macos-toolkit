import Foundation

/// What can have a place in the menu bar item, in the order it's set.
enum MenuBarTool: String, Codable, CaseIterable {
    case toolkit, stats, capture, awake, mixer

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

/// The app's own settings, apart from any tool's.
struct GeneralConfig: Codable, Equatable {
    /// Points between two parts of the menu bar item, the hairline included
    /// half on each side; also what the item keeps at its ends.
    var menuBarSpacing: Double = 12

    static let menuBarSpacings: ClosedRange<Double> = 4...24
    /// Left to right. Always every tool, shown or not, so each keeps its place.
    var menuBarOrder = MenuBarTool.defaultOrder

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Within the slider's range: a file edited by hand can say anything.
        let spacing = try c.decodeIfPresent(Double.self, forKey: .menuBarSpacing) ?? 12
        menuBarSpacing = min(max(spacing, Self.menuBarSpacings.lowerBound), Self.menuBarSpacings.upperBound)
        let order = (try? c.decodeIfPresent([String].self, forKey: .menuBarOrder)) ?? nil
        menuBarOrder = MenuBarTool.complete((order ?? []).compactMap(MenuBarTool.init(rawValue:)))
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
