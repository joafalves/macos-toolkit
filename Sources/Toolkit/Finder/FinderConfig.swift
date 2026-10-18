import AppKit

struct FinderConfig: Codable, Equatable {
    /// ⌘X in Finder, or Cut in its right-click menu, marks the selection to be
    /// moved by the next ⌘V.
    var cut = true
    // Right-click menu items. The Finder extension reads these keys too.
    var newTextFile = true
    var openInTerminal = true
    /// Bundle ID of the terminal to open, from `Terminals.known`. Empty means
    /// automatic: the first of those that is installed.
    var terminal = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cut = try c.decodeIfPresent(Bool.self, forKey: .cut) ?? true
        newTextFile = try c.decodeIfPresent(Bool.self, forKey: .newTextFile) ?? true
        openInTerminal = try c.decodeIfPresent(Bool.self, forKey: .openInTerminal) ?? true
        terminal = try c.decodeIfPresent(String.self, forKey: .terminal) ?? ""
    }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("finder.json")
    }

    static func load() -> FinderConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return FinderConfig() }
        return (try? JSONDecoder().decode(FinderConfig.self, from: data)) ?? FinderConfig()
    }

    func save() {
        let url = FinderConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Terminals that open a new window in a folder handed to them, in the order
/// automatic picks them. The Finder extension keeps the same list.
enum Terminals {
    static let known: [(id: String, name: String)] = [
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.apple.Terminal", "Terminal"),
    ]

    static var installed: [(id: String, name: String)] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// The chosen terminal if it is installed (settings may come from another
    /// Mac), otherwise the first one installed.
    static func resolve(_ id: String) -> (id: String, name: String) {
        let installed = installed
        return installed.first { $0.id == id } ?? installed.first ?? known[known.count - 1]
    }
}
