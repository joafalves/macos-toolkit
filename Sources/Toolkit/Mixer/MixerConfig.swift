import Foundation

/// An app's volume relative to the main volume. Apps at 100% and not muted
/// are not stored, and their sound is left alone.
struct AppVolume: Codable, Equatable {
    /// Shown in the settings while the app is not running.
    var name: String
    /// 0 to 1, where the slider is.
    var volume = 1.0
    var muted = false

    var isDefault: Bool { volume >= 1 && !muted }

    /// The slider position as an amplitude. Squared so that the middle of the
    /// slider sounds about half as loud, rather than barely quieter.
    var gain: Float { muted ? 0 : Float(volume * volume) }
}

struct MixerConfig: Codable, Equatable {
    /// When off, every app plays at the main volume and the menu has no mixer.
    var enabled = true
    /// Gives the mixer an icon of its own in the menu bar, besides the
    /// entry in the toolkit menu.
    var standaloneIcon = false
    /// Keyed by bundle ID.
    var apps: [String: AppVolume] = [:]
    /// Apps the mixer never lists or taps: bundle ID to name.
    var ignored: [String: String] = [:]
    /// Menu bar apps that have played sound. Many of them keep audio open
    /// without ever making a sound, so only these are listed while quiet.
    var played: Set<String> = []
    /// Apps taken off the list until they play again.
    var hidden: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        standaloneIcon = try c.decodeIfPresent(Bool.self, forKey: .standaloneIcon) ?? false
        apps = (try? c.decodeIfPresent([String: AppVolume].self, forKey: .apps)) ?? [:]
        ignored = (try? c.decodeIfPresent([String: String].self, forKey: .ignored)) ?? [:]
        played = (try? c.decodeIfPresent(Set<String>.self, forKey: .played)) ?? []
        hidden = (try? c.decodeIfPresent(Set<String>.self, forKey: .hidden)) ?? []
    }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("mixer.json")
    }

    static func load() -> MixerConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return MixerConfig() }
        return (try? JSONDecoder().decode(MixerConfig.self, from: data)) ?? MixerConfig()
    }

    func save() {
        let url = MixerConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
