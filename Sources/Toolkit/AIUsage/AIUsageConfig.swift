import Foundation

/// AI usage's own settings, apart from System Stats' for its stat: where
/// it shows and how is the stat's.
struct AIUsageConfig: Codable, Equatable {
    /// Claude Code's transcripts hold conversations, and a long history takes
    /// a while to read first, so it's off until it's asked for. Codex is a
    /// few lines at the end of its latest files.
    var claude = false
    var codex = true
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
