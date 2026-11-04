import Foundation

struct AIUsageConfig: Codable, Equatable {
    /// Off until it's turned on: it reads folders that hold conversations,
    /// which an update shouldn't start doing by itself.
    var enabled = false
    var inMenuBar = false
    var claude = true
    var codex = true
    /// A notification when a limit runs short.
    var warnings = false

    var providers: [AIProvider] {
        AIProvider.allCases.filter { $0 == .claude ? claude : codex }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        inMenuBar = try c.decodeIfPresent(Bool.self, forKey: .inMenuBar) ?? false
        claude = try c.decodeIfPresent(Bool.self, forKey: .claude) ?? true
        codex = try c.decodeIfPresent(Bool.self, forKey: .codex) ?? true
        warnings = try c.decodeIfPresent(Bool.self, forKey: .warnings) ?? false
    }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("ai-usage.json")
    }

    static func load() -> AIUsageConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AIUsageConfig() }
        return (try? JSONDecoder().decode(AIUsageConfig.self, from: data)) ?? AIUsageConfig()
    }

    func save() {
        let url = AIUsageConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
