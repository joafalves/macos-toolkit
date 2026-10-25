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

    /// Even in decibels from top to bottom, as macOS has the outputs with a
    /// volume of their own (the built-in speakers: 63.5 dB, about 4 a
    /// sixteenth), so each press of a key sounds the same change on any output.
    var gain: Float { muted || volume <= 0 ? 0 : Float(pow(10, Self.range * (volume - 1) / 20)) }

    static let range = 63.5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        if let level = try c.decodeIfPresent(Double.self, forKey: .level) {
            volume = min(max(level, 0), 1)
        } else {
            // Before 0.19 the gain was the volume squared: the level that
            // sounds the same on the even scale.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let old = min(max(try legacy.decodeIfPresent(Double.self, forKey: .volume) ?? 1, 0), 1)
            volume = old <= 0 ? 0 : max(0.01, 1 + 40 * log10(old) / Self.range)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volume, forKey: .level)
        try c.encode(muted, forKey: .muted)
    }

    /// `level`, not `volume`, so a file says which scale it's on.
    private enum CodingKeys: String, CodingKey { case level, muted }
    private enum LegacyKeys: String, CodingKey { case volume }
}

/// How far a press of a volume key goes.
enum VolumeKeyStep: String, Codable, CaseIterable {
    case fine, round, standard, large

    /// From silent to full. Standard is macOS's own; Round, 5% a press, keeps
    /// the volume on round numbers.
    var presses: Int {
        switch self {
        case .fine: return 32
        case .round: return 20
        case .standard: return 16
        case .large: return 10
        }
    }

    /// In the on-screen bar, one a press; Fine's 32 would be too thin, so it
    /// has two a segment.
    var segments: Int { self == .fine ? 16 : presses }
}

/// What the mixer shows in the menu bar besides the toolkit's own icon.
enum MixerMenuBarIcon: String, Codable, CaseIterable {
    /// Nothing: the mixer opens from the toolkit menu.
    case none
    /// The mixer glyph.
    case mixer
    /// A speaker that follows the volume and shows when it's muted.
    case volume
    /// The speaker with the volume next to it, like the battery's icon and percentage.
    case volumePercent
    /// A solid pill with the speaker and the volume cut out of it.
    case volumeBadge
    /// The same pill, small: the speaker and the fill, no number.
    case volumeSmallPill
}

struct MixerConfig: Codable, Equatable {
    /// The whole tool: when off, every app plays at the main volume, the keys
    /// are macOS's, and the menu has no mixer.
    var enabled = true
    /// In the menu bar from the start: turned on, the mixer is one click away.
    var menuBarIcon = MixerMenuBarIcon.volume {
        didSet { if menuBarIcon != .none { shownIcon = menuBarIcon } }
    }
    /// The look it had when last in the menu bar, for when it's put back.
    var shownIcon = MixerMenuBarIcon.volume

    /// For the header's switch: in the menu bar or not, in the last look.
    var inMenuBar: Bool {
        get { menuBarIcon != .none }
        set { menuBarIcon = newValue ? shownIcon : .none }
    }

    /// The look, whether it's shown now or not.
    var look: MixerMenuBarIcon {
        get { shownIcon }
        set {
            shownIcon = newValue
            if menuBarIcon != .none { menuBarIcon = newValue }
        }
    }
    /// Each output keeps its own volume, as macOS does. Off, one volume goes
    /// with whichever output is in use: switching sets the new one to it.
    var volumePerOutput = false
    /// That one volume, and whether it's muted, where the slider is.
    var sharedVolume: SoftwareVolume?
    /// For outputs with no volume control of their own (most monitors over
    /// HDMI or DisplayPort), the main slider and the volume keys lower the
    /// sound in software instead; with a volume for each output, theirs.
    /// Keyed by the output device's UID.
    var software: [String: SoftwareVolume] = [:]
    var keyStep = VolumeKeyStep.standard
    /// A press with ⇧⌥ held, in points of the volume as shown (1 takes 35 to
    /// 36): for small changes.
    var fineStep = 1
    static let fineStepRange = 1...5
    /// The equalizer for every output, or, with `equalizerPerOutput`, for an
    /// output that has none of its own yet.
    var equalizer = EqualizerConfig()
    /// Headphones and speakers can want different curves: each output keeps
    /// its own, made the first time it's changed there. Off, the per-output
    /// ones are kept for when it's on again.
    var equalizerPerOutput = false
    /// By the output device's UID.
    var equalizers: [String: EqualizerConfig] = [:]
    /// Ten bands or Simple's three handles, for every output: how it's
    /// edited, not how it sounds.
    var equalizerMode = EqualizerMode.bands
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
            if let standalone = try? legacy.decodeIfPresent(Bool.self, forKey: .standaloneIcon) {
                menuBarIcon = standalone ? .mixer : .none
            }
        }
        // A file from before this was kept has the look in use, if any.
        let shown = (try? c.decodeIfPresent(MixerMenuBarIcon.self, forKey: .shownIcon)) ?? nil
        shownIcon = menuBarIcon != .none ? menuBarIcon : shown.flatMap { $0 == .none ? nil : $0 } ?? .volume
        software = (try? c.decodeIfPresent([String: SoftwareVolume].self, forKey: .software)) ?? [:]
        volumePerOutput = try c.decodeIfPresent(Bool.self, forKey: .volumePerOutput) ?? false
        sharedVolume = try? c.decodeIfPresent(SoftwareVolume.self, forKey: .sharedVolume)
        keyStep = (try? c.decodeIfPresent(VolumeKeyStep.self, forKey: .keyStep)) ?? .standard
        fineStep = min(max(try c.decodeIfPresent(Int.self, forKey: .fineStep) ?? 1, Self.fineStepRange.lowerBound), Self.fineStepRange.upperBound)
        equalizer = (try? c.decodeIfPresent(EqualizerConfig.self, forKey: .equalizer)) ?? EqualizerConfig()
        equalizerPerOutput = try c.decodeIfPresent(Bool.self, forKey: .equalizerPerOutput) ?? false
        equalizerMode = (try? c.decodeIfPresent(EqualizerMode.self, forKey: .equalizerMode)) ?? .bands
        equalizers = (try? c.decodeIfPresent([String: EqualizerConfig].self, forKey: .equalizers)) ?? [:]
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
