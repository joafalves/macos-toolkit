import AppKit
import Combine

/// System Stats: reads what's shown in the menu bar, the stats only in the
/// panel (for their history), and everything a panel shows while it's open,
/// on one timer. Nothing else: with the tool off, or no stat in either place
/// and no panel open, there's no timer, no reader, no history and no IOReport
/// subscription.
final class StatsController: ObservableObject {
    @Published var config: StatsConfig {
        didSet {
            guard config != oldValue else { return }
            if persists { config.save() }
            apply()
        }
    }

    /// The readings, apart from the settings: the settings page watches this
    /// object, and would otherwise be drawn again with every reading.
    let live = StatsLive()

    var cpu: CPUReading? { live.cpu }
    var memory: MemoryReading? { live.memory }
    var network: NetworkReading? { live.network }
    var disk: DiskReading? { live.disk }
    var gpu: Double? { live.gpu }
    var power: PowerReading? { live.power }
    var apps: [AppUsage] { live.apps }
    var history: [Series: [Double]] { live.history }

    /// The stats a panel shows while it's open.
    var panel: [StatKind] = [] {
        didSet {
            guard panel != oldValue else { return }
            apply()
        }
    }

    enum Series: Hashable {
        case cpu, memory, up, down, read, write, gpu, power
        /// One core, by its number, for the CPU panel's charts.
        case core(Int)
    }

    /// False for the self-test and `--snapshot`: settings aren't saved.
    var persists = true
    /// For `--snapshot`: made-up readings, nothing read.
    private var isPreview = false
    private(set) var timer: Timer?
    /// What was read last time `apply` ran, to read only what's new at once.
    private var wasReading: Set<StatKind> = []
    private(set) var cpuReader: StatsReadings.CPU?
    private var networkReader: StatsReadings.Network?
    private var diskReader: StatsReadings.Disk?
    private(set) var energy: EnergyReport?
    private var topApps: TopApps?

    init() {
        config = StatsConfig.load()
    }

    func start() {
        apply()
    }

    /// Made-up readings and history, for `--snapshot`: nothing from this Mac.
    static func preview(layout: StatsLayout = .separate, looks: [StatKind: StatLook] = [:], shown: [StatKind]? = nil) -> StatsController {
        let stats = StatsController()
        stats.persists = false
        stats.isPreview = true
        var config = StatsConfig()
        config.layout = layout
        for kind in StatKind.allCases {
            config.set(kind) {
                $0.look = looks[kind] ?? .number
                if let shown { $0.shown = shown.contains(kind) }
            }
        }
        stats.config = config
        let gb: UInt64 = 1 << 30
        stats.live.cpu = CPUReading(total: 0.23, user: 0.15, system: 0.08,
                               cores: [0.42, 0.31, 0.18, 0.12, 0.08, 0.05, 0.36, 0.22, 0.14, 0.09],
                               groups: [CoreGroup(name: "Efficiency", cores: 0..<6), CoreGroup(name: "Performance", cores: 6..<10)])
        stats.live.memory = MemoryReading(total: 16 * gb, app: 6 * gb, wired: 2 * gb, compressed: gb + gb / 2, cached: 4 * gb, free: 2 * gb + gb / 2,
                                     swapUsed: gb / 4, pressure: .normal)
        stats.live.network = NetworkReading(up: 48_000, down: 1_240_000, interface: "en0", address: "192.168.1.20")
        stats.live.disk = DiskReading(total: 994_000_000_000, free: 312_000_000_000, read: 2_400_000, write: 860_000)
        stats.live.gpu = 0.18
        stats.live.power = PowerReading(system: 7.4, cpu: 2.1, gpu: 0.9, charger: nil, charging: false, battery: 82, health: 96, cycles: 143)
        func wave(_ count: Int, _ base: Double, _ swing: Double, _ seed: Double) -> [Double] {
            (0..<count).map { base + swing * (sin(Double($0) / 9 + seed) * 0.6 + sin(Double($0) / 3.7 + seed * 2) * 0.4) }
        }
        stats.live.history = [.cpu: wave(150, 0.22, 0.12, 0), .memory: wave(150, 0.6, 0.03, 1), .gpu: wave(150, 0.16, 0.1, 2),
                         .power: wave(150, 7, 2.5, 3), .down: wave(150, 900_000, 600_000, 4), .up: wave(150, 60_000, 40_000, 5),
                         .read: wave(150, 2_000_000, 1_500_000, 6), .write: wave(150, 700_000, 500_000, 7)]
        for (core, share) in (stats.live.cpu?.cores ?? []).enumerated() {
            stats.live.history[.core(core)] = wave(30, share, share * 0.6, Double(core) * 1.3).map { max(0, $0) }
        }
        // Apple's own apps, found by bundle: Safari's path is a link that shows as an alias.
        func icon(_ app: String) -> NSImage {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(app)")
            return NSWorkspace.shared.icon(forFile: url?.path ?? "/System/Applications/\(app).app")
        }
        stats.live.cpuOfAppsKnown = true
        stats.live.apps = [
            AppUsage(id: 1, name: "Safari", icon: icon("Safari"), cpu: 0.31, memory: 2 * gb),
            AppUsage(id: 2, name: "Mail", icon: icon("mail"), cpu: 0.06, memory: gb / 2),
            AppUsage(id: 3, name: "Music", icon: icon("Music"), cpu: 0.12, memory: gb / 3),
            AppUsage(id: 4, name: "Notes", icon: icon("Notes"), cpu: 0.02, memory: gb / 5),
            AppUsage(id: 5, name: "Calendar", icon: icon("iCal"), cpu: 0.01, memory: gb / 6),
            AppUsage(id: 6, name: "Photos", icon: icon("Photos"), cpu: 0.08, memory: gb),
        ]
        return stats
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        wasReading = []
    }

    /// What's being read now.
    var reading: Set<StatKind> {
        guard config.enabled else { return [] }
        // Panel-only stats too, so their charts have their five minutes when it opens.
        return Set(config.shown).union(config.panelOnly).union(panel)
    }

    /// Readers for what's read, none for the rest; a timer only if anything
    /// is. What's newly read is read at once, so it shows straight away (and
    /// speeds have something to compare with); the rest waits for the timer,
    /// as a speed or a share of time read moments after the last one is noise.
    func apply() {
        guard !isPreview else { return }
        let reading = reading
        if !reading.contains(.cpu) { cpuReader = nil; live.cpu = nil }
        if !reading.contains(.memory) { live.memory = nil }
        if !reading.contains(.network) { networkReader = nil; live.network = nil }
        if !reading.contains(.disk) { diskReader = nil; live.disk = nil }
        if !reading.contains(.gpu) { live.gpu = nil }
        if !reading.contains(.power) { energy = nil; live.power = nil }
        if reading.contains(.cpu) { cpuReader = cpuReader ?? StatsReadings.CPU() }
        if reading.contains(.network) { networkReader = networkReader ?? StatsReadings.Network() }
        if reading.contains(.disk) { diskReader = diskReader ?? StatsReadings.Disk() }
        // IOReport only for what the battery doesn't say: the CPU and GPU in
        // the power panel, or the whole draw on a desktop, which has no
        // battery. Kept, it costs ~5 ms a reading; started, ~50 ms once.
        if reading.contains(.power), panel.contains(.power) || StatsReadings.power()?.system == nil {
            if energy == nil, let report = EnergyReport() {
                energy = report
                // Watts come from two samples: the first now, and the figures
                // a moment on, rather than at the next reading.
                _ = report.read()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak report] in
                    guard let self, let report, report === energy, live.power != nil else { return }
                    let watts = report.read()
                    live.power?.cpu = watts.cpu
                    live.power?.gpu = watts.gpu
                }
            }
        } else {
            energy = nil
        }
        var newApps = false
        if config.enabled, panel.contains(.cpu) || panel.contains(.memory) {
            newApps = topApps == nil
            topApps = topApps ?? TopApps()
        } else {
            topApps = nil
            if !live.apps.isEmpty { live.apps = [] }
            live.cpuOfAppsKnown = false
        }
        // History only for what's read; a stat turned back on starts afresh.
        let kept: Set<Series> = Set(reading.flatMap(Self.series))
        let keep = { (series: Series) in
            if case .core = series { return self.reading.contains(.cpu) }
            return kept.contains(series)
        }
        if live.history.keys.contains(where: { !keep($0) }) { live.history = live.history.filter { keep($0.key) } }

        let added = reading.subtracting(wasReading)
        wasReading = reading
        guard !reading.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        // Counted from the moment the panel opens, and read again as soon as
        // there's CPU to tell rather than at the next tick, so the top apps'
        // CPU shows within a second.
        if newApps {
            topApps?.restart()
            DispatchQueue.main.asyncAfter(deadline: .now() + TopApps.shortest) { [weak self] in self?.readApps() }
        }
        if !added.isEmpty || newApps { read(added, apps: newApps) }
        let interval = max(1, config.interval)
        if timer?.timeInterval != interval {
            timer?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.read() }
            timer.tolerance = interval / 10
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private static func series(_ kind: StatKind) -> [Series] {
        switch kind {
        case .cpu: return [.cpu]
        case .memory: return [.memory]
        case .network: return [.up, .down]
        case .disk: return [.read, .write]
        case .gpu: return [.gpu]
        case .power: return [.power]
        }
    }

    /// Reads what's read, or only `kinds`, and the top apps with `apps`.
    func read(_ kinds: Set<StatKind>? = nil, apps: Bool = true) {
        let reading = kinds.map { $0.intersection(self.reading) } ?? self.reading
        if reading.contains(.cpu), let value = cpuReader?.read() {
            live.cpu = value
            record(.cpu, value.total)
            // A minute each: the panel's charts per core are small.
            for (core, share) in value.cores.enumerated() { record(.core(core), share, seconds: 60) }
        }
        if reading.contains(.memory), let value = StatsReadings.memory() {
            live.memory = value
            record(.memory, value.neededShare)
        }
        if reading.contains(.network), let value = networkReader?.read() {
            live.network = value
            record(.up, value.up)
            record(.down, value.down)
        }
        if reading.contains(.disk), let value = diskReader?.read() {
            live.disk = value
            if let read = value.read, let write = value.write {
                record(.read, read)
                record(.write, write)
            }
        }
        if reading.contains(.gpu), let value = StatsReadings.gpu() {
            live.gpu = value
            record(.gpu, value)
        }
        if reading.contains(.power) {
            // Desktops have no battery readings, only IOReport's.
            var value = StatsReadings.power() ?? PowerReading(charging: false)
            if let watts = energy?.read() {
                value.cpu = watts.cpu
                value.gpu = watts.gpu
            }
            live.power = value
            if let drawn = value.drawn { record(.power, drawn) }
        }
        if apps, let topApps {
            live.apps = topApps.read()
            live.cpuOfAppsKnown = topApps.cpuKnown
        }
        live.tick += 1
    }

    /// Only the top apps, between the timer's readings.
    private func readApps() {
        guard let topApps else { return }
        live.apps = topApps.read()
        live.cpuOfAppsKnown = topApps.cpuKnown
        live.tick += 1
    }

    private func record(_ series: Series, _ value: Double, seconds: Double = 300) {
        let keep = Int(seconds / max(config.interval, 1))
        var values = live.history[series] ?? []
        values.append(value)
        if values.count > keep { values.removeFirst(values.count - keep) }
        live.history[series] = values
    }

    // MARK: - The menu bar

    /// The parts for the menu bar item: one a stat, or one for all of them,
    /// or, with every stat only in the panel, an icon that opens it.
    func segments() -> [MenuBarSegment] {
        guard config.enabled else { return [] }
        let shown = config.shown
        if shown.isEmpty {
            guard !config.panelOnly.isEmpty else { return [] }
            return [MenuBarSegment(kind: .stats, glyph: MenuBarArt.glyph(AppSection.stats.symbol), label: AppSection.stats.title)]
        }
        if config.layout == .compact {
            let lines = shown.map { compactLine($0) }
            // Two to a column, so they fit the menu bar's height.
            let columns = stride(from: 0, to: lines.count, by: 2).map { Array(lines[$0..<min($0 + 2, lines.count)]) }
            return [MenuBarSegment(kind: .stats, columns: columns.map(MenuBarArt.column), label: String(localized: "System Stats, \(shown.map(spoken).joined(separator: ", "))"))]
        }
        return shown.map(segment)
    }

    private func segment(_ kind: StatKind) -> MenuBarSegment {
        let look = config.setting(kind).look
        let label = kind.title + ", " + spoken(kind)
        let tint = self.tint(kind)
        switch (kind, kind.looks.contains(look) ? look : .number) {
        case (.network, .chart):
            return MenuBarSegment(kind: .stat(kind), glyph: MenuBarArt.sparkline(Array((history[.down] ?? []).suffix(chartReadings)), symbol: kind.symbol,
                                                                                         second: Array((history[.up] ?? []).suffix(chartReadings)), count: chartReadings),
                                  columns: [MenuBarArt.column([networkLine(\.up, "↑"), networkLine(\.down, "↓")])], label: label)
        case (.network, _):
            return MenuBarSegment(kind: .stat(kind), columns: [MenuBarArt.column([networkLine(\.up, "↑"), networkLine(\.down, "↓")])], label: label)
        case (_, .pill), (_, .smallPill):
            return MenuBarSegment(kind: .stat(kind), glyph: MenuBarArt.fillBadge(symbol: kind.symbol, fraction: share(kind) ?? 0, text: pillText(kind),
                                                                                  small: look == .smallPill),
                                  tint: tint, label: label)
        case (_, .chart):
            let values = chartValues(kind)
            return MenuBarSegment(kind: .stat(kind), glyph: MenuBarArt.sparkline(values.values, symbol: kind.symbol, ceiling: values.ceiling, count: chartReadings),
                                  text: text(kind), tint: tint, widthOf: Self.widest(kind), label: label)
        default:
            return MenuBarSegment(kind: .stat(kind), glyph: MenuBarArt.glyph(kind.symbol), text: text(kind), tint: tint,
                                  widthOf: Self.widest(kind), label: label)
        }
    }

    /// The last minute, at whatever rate it's read.
    /// Readings in a minute, which the menu bar's charts and the panel's per core show.
    var chartReadings: Int { max(2, Int(60 / max(config.interval, 1))) }

    /// The widest each figure gets, which its part keeps as its width.
    static func widest(_ kind: StatKind) -> String {
        switch kind {
        case .cpu, .memory, .gpu: return "99%"
        case .disk: return "888 GB"
        case .power: return "888 W"
        case .network: return "↓888 MB/s"
        }
    }

    /// The share a pill fills to.
    func share(_ kind: StatKind) -> Double? {
        switch kind {
        case .cpu: return cpu?.total
        case .memory: return memory?.neededShare
        case .gpu: return gpu
        case .disk: return disk?.usedShare
        case .network, .power: return nil
        }
    }

    /// The figure for the menu bar.
    func text(_ kind: StatKind) -> String {
        switch kind {
        case .cpu: return cpu.map { Self.percent($0.total) } ?? "–"
        case .memory: return memory.map { Self.percent($0.neededShare) } ?? "–"
        case .gpu: return gpu.map { Self.percent($0) } ?? "–"
        case .disk: return disk.map { Self.bytes($0.free) } ?? "–"
        case .power: return power?.drawn.map { Self.watts($0) } ?? "–"
        case .network: return network.map { "↓" + Self.speed($0.down) } ?? "–"
        }
    }

    /// Up to 100: the pill has room for it, as wide as Keep Awake's times.
    private func pillText(_ kind: StatKind) -> String {
        share(kind).map { "\(min(100, Int(($0 * 100).rounded())))" } ?? "–"
    }

    private func chartValues(_ kind: StatKind) -> (values: [Double], ceiling: Double?) {
        let last = { (series: Series) in Array((self.history[series] ?? []).suffix(self.chartReadings)) }
        switch kind {
        case .cpu: return (last(.cpu), 1)
        case .memory: return (last(.memory), 1)
        case .gpu: return (last(.gpu), 1)
        case .power: return (last(.power), nil)
        case .disk: return (last(.read), nil)
        case .network: return (last(.down), nil)
        }
    }

    private func networkLine(_ value: KeyPath<NetworkReading, Double>, _ arrow: String) -> MenuBarArt.Line {
        MenuBarArt.Line(text: arrow + " " + (network.map { Self.speed($0[keyPath: value]) } ?? "–"), widthOf: arrow + " 888 MB/s")
    }

    private func compactLine(_ kind: StatKind) -> MenuBarArt.Line {
        let value: String, widest: String
        switch kind {
        case .network:
            value = network.map { "↓" + Self.speed($0.down) + " ↑" + Self.speed($0.up) } ?? "–"
            widest = "↓888 MB/s ↑888 MB/s"
        default:
            value = text(kind)
            widest = Self.widest(kind)
        }
        return MenuBarArt.Line(text: kind.short + " " + value, tint: tint(kind), widthOf: kind.short + " " + widest)
    }

    /// Memory turns yellow, then red, as macOS reports it running short, if
    /// that's turned on.
    func tint(_ kind: StatKind) -> NSColor? {
        guard kind == .memory, config.memoryColors, let pressure = memory?.pressure else { return nil }
        switch pressure {
        case .normal: return nil
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }

    private func spoken(_ kind: StatKind) -> String {
        switch kind {
        case .network: return network.map { String(localized: "down \(Self.speed($0.down)), up \(Self.speed($0.up))") } ?? String(localized: "reading")
        default: return text(kind)
        }
    }

    // MARK: - Formats

    /// Up to 99%: a load of 100% says no more than 99%, and two digits keep
    /// the menu bar narrower than room for a third that almost never shows.
    static func percent(_ share: Double) -> String { "\(min(99, Int((share * 100).rounded())))%" }

    /// The cores an app's CPU is counted against: 100% per core.
    static let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)

    /// An app's CPU (1 is one core's worth), per core or as a share of
    /// `cores`, the panel's reading's: this Mac's, or a preview's own.
    static func appCPU(_ used: Double, ofWhole: Bool, cores: Int) -> String {
        guard ofWhole else { return "\(Int((used * 100).rounded()))%" }
        let share = used / Double(max(cores, 1)) * 100
        // Most apps are a fraction of a percent of every core: one decimal.
        return share < 10 ? String(format: "%.1f%%", locale: .current, share) : "\(Int(share.rounded()))%"
    }

    /// What the figures are out of, for perspective.
    static func appCPUScale(ofWhole: Bool, cores: Int) -> String {
        ofWhole ? String(localized: "Of the whole CPU, up to 100%") : String(localized: "Per core, up to \(max(cores, 1) * 100)%")
    }

    static func watts(_ watts: Double) -> String {
        watts < 10 ? String(format: "%.1f W", locale: .current, watts) : "\(Int(watts.rounded())) W"
    }

    /// 0 KB/s, 840 KB/s, 1.2 MB/s, 34 MB/s.
    static func speed(_ bytes: Double) -> String {
        let units = ["KB/s", "MB/s", "GB/s"]
        var value = bytes / 1000
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return (value < 10 && unit > 0 ? String(format: "%.1f", locale: .current, value) : "\(Int(value.rounded()))") + " " + units[unit]
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func memory(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }
}

/// What System Stats has read, and the history behind its charts.
final class StatsLive: ObservableObject {
    @Published var cpu: CPUReading?
    @Published var memory: MemoryReading?
    @Published var network: NetworkReading?
    @Published var disk: DiskReading?
    @Published var gpu: Double?
    @Published var power: PowerReading?
    /// The apps using the most, while a CPU or memory panel is open.
    @Published var apps: [AppUsage] = []
    /// False until there are two readings of the apps to tell their CPU from.
    @Published var cpuOfAppsKnown = false
    /// Goes up with every reading, for the menu bar to redraw from.
    @Published var tick = 0
    /// The last five minutes, oldest first, by series.
    var history: [StatsController.Series: [Double]] = [:]
}
