import Foundation

/// Which display the switcher opens on.
enum SwitcherPlacement: String, Codable, CaseIterable {
    /// The primary display, the one at the origin of the arrangement.
    case mainScreen
    case mouse
    /// The display with the window that has the keyboard.
    case activeWindow
}

struct SwitcherConfig: Codable, Equatable {
    /// When off, Cmd-Tab is left to macOS.
    var enabled = true
    var placement = SwitcherPlacement.mainScreen

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        placement = (try? c.decodeIfPresent(SwitcherPlacement.self, forKey: .placement)) ?? .mainScreen
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
