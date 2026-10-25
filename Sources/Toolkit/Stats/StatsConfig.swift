import Foundation

/// One thing System Stats watches.
enum StatKind: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, network, disk, gpu, power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return String(localized: "CPU")
        case .memory: return String(localized: "Memory")
        case .network: return String(localized: "Network")
        case .disk: return String(localized: "Disk")
        case .gpu: return String(localized: "GPU")
        case .power: return String(localized: "Power")
        }
    }

    /// The short name in the compact layout.
    var short: String {
        switch self {
        case .cpu: return String(localized: "CPU")
        case .memory: return String(localized: "MEM")
        case .network: return String(localized: "NET")
        case .disk: return String(localized: "SSD")
        case .gpu: return String(localized: "GPU")
        case .power: return String(localized: "PWR")
        }
    }

    var caption: String {
        switch self {
        case .cpu: return String(localized: "How busy the processor is.")
        case .memory: return String(localized: "What apps need, without the files macOS keeps cached.")
        case .network: return String(localized: "Upload and download speed.")
        case .disk: return String(localized: "Free space on the startup disk.")
        case .gpu: return String(localized: "How busy the graphics processor is.")
        case .power: return String(localized: "What the Mac draws, in watts.")
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive"
        case .gpu: return "cube"
        case .power: return "bolt"
        }
    }

    /// The looks that make sense for it: a pill needs a share of something.
    var looks: [StatLook] {
        switch self {
        case .cpu, .memory, .gpu: return [.number, .pill, .smallPill, .chart]
        case .disk: return [.number, .pill, .smallPill]
        case .network, .power: return [.number, .chart]
        }
    }
}

/// How a stat shows in the menu bar.
enum StatLook: String, Codable, CaseIterable {
    /// Its icon and the number.
    case number
    /// A pill that fills, like the volume badge.
    case pill
    /// The pill without the number: the fill alone.
    case smallPill
    /// The last minute as a small chart, and the number.
    case chart

    var title: String {
        switch self {
        case .number: return String(localized: "Number")
        case .pill: return String(localized: "Pill")
        case .smallPill: return String(localized: "Small pill")
        case .chart: return String(localized: "Chart")
        }
    }
}

enum StatsLayout: String, Codable {
    /// Each stat a part of its own.
    case separate
    /// Every stat in one part, as small labels two to a column.
    case compact
}

/// Where a stat shows: the panel is the one a click on System Stats opens.
enum StatPlace: CaseIterable {
    case menuBar, panel, off

    var title: String {
        switch self {
        case .menuBar: return String(localized: "Menu bar")
        case .panel: return String(localized: "Panel only")
        case .off: return String(localized: "Off")
        }
    }
}

struct StatSetting: Codable, Equatable {
    /// In the menu bar, and so in the panel.
    var shown: Bool
    var look: StatLook
    /// In the panel but not the menu bar, for a stat that isn't shown: kept
    /// apart from `shown` so a file from before it still reads, and an older
    /// version reading a newer file sees the stat as off.
    var panelOnly = false

    var place: StatPlace {
        get { shown ? .menuBar : panelOnly ? .panel : .off }
        set {
            shown = newValue == .menuBar
            panelOnly = newValue == .panel
        }
    }
}

extension StatSetting {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shown = try c.decodeIfPresent(Bool.self, forKey: .shown) ?? false
        look = (try? c.decodeIfPresent(StatLook.self, forKey: .look)) ?? .number
        panelOnly = try c.decodeIfPresent(Bool.self, forKey: .panelOnly) ?? false
    }
}

struct StatsConfig: Codable, Equatable {
    var enabled = true
    var layout = StatsLayout.separate
    /// Seconds between readings.
    var interval: Double = 2
    /// Memory in yellow, then red, as macOS reports it running short. Off by
    /// default: some find a coloured figure alarming, even at 99% used.
    var memoryColors = false
    /// An app's CPU in the panels as a share of every core, up to 100%, like
    /// the CPU figure itself; off, per core, as Activity Monitor counts it.
    var topAppsOfWholeCPU = false
    /// By `StatKind.rawValue`.
    var stats: [String: StatSetting] = StatsConfig.defaultStats

    static let intervals: [Double] = [1, 2, 5]
    static let defaultStats: [String: StatSetting] = Dictionary(uniqueKeysWithValues: StatKind.allCases.map {
        ($0.rawValue, StatSetting(shown: $0 == .cpu || $0 == .memory, look: .number))
    })

    func setting(_ kind: StatKind) -> StatSetting {
        stats[kind.rawValue] ?? Self.defaultStats[kind.rawValue] ?? StatSetting(shown: false, look: .number)
    }

    mutating func set(_ kind: StatKind, _ change: (inout StatSetting) -> Void) {
        var setting = setting(kind)
        change(&setting)
        stats[kind.rawValue] = setting
    }

    /// The stats in the menu bar, in their order.
    var shown: [StatKind] { StatKind.allCases.filter { setting($0).shown } }

    /// The stats only in the panel, in their order.
    var panelOnly: [StatKind] { StatKind.allCases.filter { setting($0).place == .panel } }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        layout = (try? c.decodeIfPresent(StatsLayout.self, forKey: .layout)) ?? .separate
        // One of the offered rates; a file saying 0 would read without pause.
        let interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 2
        self.interval = Self.intervals.contains(interval) ? interval : 2
        memoryColors = try c.decodeIfPresent(Bool.self, forKey: .memoryColors) ?? false
        topAppsOfWholeCPU = try c.decodeIfPresent(Bool.self, forKey: .topAppsOfWholeCPU) ?? false
        // Stats added later get their defaults; unknown looks fall back to a number.
        var stats = Self.defaultStats
        if let saved = try? c.decodeIfPresent([String: StatSetting].self, forKey: .stats) {
            for (key, value) in saved where stats[key] != nil { stats[key] = value }
        }
        self.stats = stats
    }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("stats.json")
    }

    static func load() -> StatsConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return StatsConfig() }
        return (try? JSONDecoder().decode(StatsConfig.self, from: data)) ?? StatsConfig()
    }

    func save() {
        let url = StatsConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
