import Foundation

/// AI usage's own settings, apart from System Stats' for its stat: where
/// it shows and how is the stat's.
struct AIUsageConfig: Codable, Equatable {
    /// Nothing is read until it's asked for: Claude Code's transcripts hold
    /// conversations, and Codex's sessions too.
    var claude = false
    var codex = false
    /// A notification when a limit runs short.
    var warnings = false

    var providers: [AIProvider] {
        AIProvider.allCases.filter(isOn)
    }

    func isOn(_ provider: AIProvider) -> Bool {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = try c.decodeIfPresent(Bool.self, forKey: .claude) ?? false
        codex = try c.decodeIfPresent(Bool.self, forKey: .codex) ?? false
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
