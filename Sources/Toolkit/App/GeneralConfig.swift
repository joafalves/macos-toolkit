import Foundation

/// The app's own settings, apart from any tool's.
struct GeneralConfig: Codable, Equatable {
    /// Points between two parts of the menu bar item, the hairline included
    /// half on each side; also what the item keeps at its ends.
    var menuBarSpacing: Double = 12

    static let menuBarSpacings: ClosedRange<Double> = 4...24

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuBarSpacing = try c.decodeIfPresent(Double.self, forKey: .menuBarSpacing) ?? 12
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
