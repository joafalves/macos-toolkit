import Foundation

/// An app's volume relative to the main volume. Apps at 100% and not muted
/// are not stored, and their sound is left alone.
struct AppVolume: Codable, Equatable {
    /// Shown in the settings while the app is not running.
    var name: String
    /// 0 to 1, where the slider is.
    var volume = 1.0
    var muted = false
    /// Where the slider was before it was dragged to 0, for unmuting.
    var restoreVolume: Double?

    var isDefault: Bool { volume >= 1 && !muted }
    /// Muted, or at 0%, which sounds the same and is shown the same.
    var isSilent: Bool { muted || volume == 0 }

    /// The slider position as an amplitude. Squared so that the middle of the
    /// slider sounds about half as loud, rather than barely quieter.
    var gain: Float { muted ? 0 : Float(volume * volume) }
}

/// The main volume of an output that has none of its own, applied by the
/// mixer in software.
struct SoftwareVolume: Codable, Equatable {
    var volume = 1.0
    var muted = false

    var isDefault: Bool { volume >= 1 && !muted }

    /// Squared like the app volumes, so the middle of the scale sounds about half as loud.
    var gain: Float { muted ? 0 : Float(volume * volume) }
}

/// What the mixer shows in the menu bar besides the toolkit's own icon.
enum MixerMenuBarIcon: String, Codable, CaseIterable {
    /// Nothing: the mixer opens from the toolkit menu.
    case none
    /// The mixer glyph.
    case mixer
    /// A speaker that follows the volume and shows when it's muted.
    case volume
}

struct MixerConfig: Codable, Equatable {
    /// The whole tool: when off, every app plays at the main volume, the keys
    /// are macOS's, and the menu has no mixer.
    var enabled = true
    var menuBarIcon = MixerMenuBarIcon.none
    /// For outputs with no volume control of their own (most monitors over
    /// HDMI or DisplayPort): the main slider and the volume keys lower the
    /// sound in software instead.
    var softwareVolume = true
    /// Keyed by the output device's UID.
    var software: [String: SoftwareVolume] = [:]
    /// When on and not flat, all sound goes through the toolkit to be equalized.
    var equalizer = EqualizerConfig()
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
        if let icon = try? c.decodeIfPresent(MixerMenuBarIcon.self, forKey: .menuBarIcon) {
            menuBarIcon = icon
        } else {
            // Before the choice of icons there was only an on/off switch.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            menuBarIcon = (try? legacy.decodeIfPresent(Bool.self, forKey: .standaloneIcon)) == true ? .mixer : .none
        }
        softwareVolume = try c.decodeIfPresent(Bool.self, forKey: .softwareVolume) ?? true
        software = (try? c.decodeIfPresent([String: SoftwareVolume].self, forKey: .software)) ?? [:]
        equalizer = (try? c.decodeIfPresent(EqualizerConfig.self, forKey: .equalizer)) ?? EqualizerConfig()
        apps = (try? c.decodeIfPresent([String: AppVolume].self, forKey: .apps)) ?? [:]
        ignored = (try? c.decodeIfPresent([String: String].self, forKey: .ignored)) ?? [:]
        played = (try? c.decodeIfPresent(Set<String>.self, forKey: .played)) ?? []
        hidden = (try? c.decodeIfPresent(Set<String>.self, forKey: .hidden)) ?? []
    }

    private enum LegacyKeys: String, CodingKey {
        case standaloneIcon
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
