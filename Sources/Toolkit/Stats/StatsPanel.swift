import AppKit
import SwiftUI

/// The panel a stat opens from the menu bar: its history and details, and
/// for CPU and memory the apps using the most. In the compact layout it shows
/// every stat in the menu bar, one after another.
struct StatsPanelView: View {
    let stats: StatsController
    /// Watched for the readings, so the panel follows them.
    @ObservedObject private var live: StatsLive
    let kinds: [StatKind]
    var close: () -> Void
    var openSettings: () -> Void

    init(stats: StatsController, kinds: [StatKind], close: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}) {
        self.stats = stats
        live = stats.live
        self.kinds = kinds
        self.close = close
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider().padding(.vertical, 10) }
                section(kind)
            }
            Divider().padding(.top, 12).padding(.bottom, 8)
            PanelFooter(app: "Activity Monitor", openApp: {
                close()
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }, openSettings: openSettings)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private func section(_ kind: StatKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(kind.title, systemImage: kind.symbol)
                    .font(.headline)
                Spacer()
                Text(headline(kind))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(stats.tint(kind).map { Color(nsColor: $0) } ?? .primary)
            }
            chart(kind)
            details(kind)
        }
    }

    private func headline(_ kind: StatKind) -> String {
        switch kind {
        case .memory:
            guard let memory = stats.memory else { return "–" }
            return "\(StatsController.memory(memory.needed)) of \(StatsController.memory(memory.total))"
        case .disk:
            guard let disk = stats.disk else { return "–" }
            return "\(StatsController.bytes(disk.free)) free"
        case .network:
            guard let network = stats.network else { return "–" }
            return "↓ \(StatsController.speed(network.down))  ↑ \(StatsController.speed(network.up))"
        default:
            return stats.text(kind)
        }
    }

    // MARK: - Charts

    @ViewBuilder
    private func chart(_ kind: StatKind) -> some View {
        switch kind {
        case .cpu: HistoryChart(series: [(stats.history[.cpu] ?? [], .blue)], ceiling: 1)
        case .memory: HistoryChart(series: [(stats.history[.memory] ?? [], pressureColor)], ceiling: 1)
        case .gpu: HistoryChart(series: [(stats.history[.gpu] ?? [], .pink)], ceiling: 1)
        case .power: HistoryChart(series: [(stats.history[.power] ?? [], .orange)], ceiling: nil)
        case .network: HistoryChart(series: [(stats.history[.down] ?? [], .teal), (stats.history[.up] ?? [], .orange)], ceiling: nil)
        case .disk: HistoryChart(series: [(stats.history[.read] ?? [], .purple), (stats.history[.write] ?? [], .orange)], ceiling: nil)
        }
    }

    private var pressureColor: Color {
        guard stats.config.memoryColors else { return .green }
        switch stats.memory?.pressure {
        case .warning: return .yellow
        case .critical: return .red
        default: return .green
        }
    }

    // MARK: - Details

    @ViewBuilder
    private func details(_ kind: StatKind) -> some View {
        switch kind {
        case .cpu: cpuDetails
        case .memory: memoryDetails
        case .network: networkDetails
        case .disk: diskDetails
        case .gpu: EmptyView()
        case .power: powerDetails
        }
    }

    @ViewBuilder
    private var cpuDetails: some View {
        if let cpu = stats.cpu {
            Row("User", StatsController.percent(cpu.user))
            Row("System", StatsController.percent(cpu.system))
            CoreCharts(cpu: cpu, history: { stats.history[.core($0)] ?? [] }, slots: stats.chartReadings)
                .padding(.top, 2)
            // Two readings apart before there's CPU to tell; not a list of zeros.
            if live.cpuOfAppsKnown {
                TopList(apps: stats.apps.sorted { $0.cpu > $1.cpu }.prefix(5).map { ($0, "\(Int(($0.cpu * 100).rounded()))%") })
            }
        }
    }

    @ViewBuilder
    private var memoryDetails: some View {
        if let memory = stats.memory {
            MemoryBar(memory: memory)
            Row("Pressure", memory.pressure == .normal ? "Normal" : memory.pressure == .warning ? "Warning" : "Critical")
            Row("Swap used", StatsController.memory(memory.swapUsed))
            TopList(apps: stats.apps.sorted { $0.memory > $1.memory }.prefix(5).map { ($0, StatsController.memory($0.memory)) })
        }
    }

    @ViewBuilder
    private var networkDetails: some View {
        if let network = stats.network {
            Legend(items: [("Download", .teal), ("Upload", .orange)])
            if let interface = network.interface { Row("Interface", interface) }
            if let address = network.address { Row("Address", address) }
        }
    }

    @ViewBuilder
    private var diskDetails: some View {
        if let disk = stats.disk {
            Legend(items: [("Read", .purple), ("Write", .orange)])
            if let read = disk.read, let write = disk.write {
                Row("Read", StatsController.speed(read))
                Row("Write", StatsController.speed(write))
            }
            ShareBar(share: disk.usedShare, color: .purple)
                .padding(.top, 4)
            Row("Used", "\(StatsController.bytes(disk.total - disk.free)) of \(StatsController.bytes(disk.total))")
        }
    }

    @ViewBuilder
    private var powerDetails: some View {
        if let power = stats.power {
            if let cpu = power.cpu { Row("CPU", StatsController.watts(cpu)) }
            if let gpu = power.gpu { Row("GPU", StatsController.watts(gpu)) }
            if let charger = power.charger { Row("Charger", "\(charger) W" + (power.charging ? ", charging" : "")) }
            if let battery = power.battery { Row("Battery", "\(battery)%") }
            if let health = power.health { Row("Battery health", "\(health)%") }
            if let cycles = power.cycles { Row("Cycles", "\(cycles)") }
        }
    }
}

/// A label and its value, on one line.
private struct Row: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

private struct Legend: View {
    let items: [(String, Color)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.1).frame(width: 7, height: 7)
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The last five minutes: the first series as a filled area, the rest as lines.
/// Drawn with shapes, not a `Canvas`: a canvas redrawn with each reading made
/// SwiftUI hold about 40 MB of graphics memory while the panel was open.
struct HistoryChart: View {
    let series: [([Double], Color)]
    /// The top of the chart, or nil for the highest reading.
    let ceiling: Double?
    var height: CGFloat = 64
    /// Readings across the whole width, so a short history fills from the
    /// right at the same pace instead of stretching. Nil: as many as there are.
    var slots: Int?

    var body: some View {
        let top = max(ceiling ?? series.flatMap(\.0).max() ?? 0, 1e-9)
        let count = max(slots ?? series.map(\.0.count).max() ?? 0, 2)
        ZStack {
            ChartGrid().stroke(Color.primary.opacity(0.07), lineWidth: 1)
            ForEach(Array(series.enumerated()), id: \.offset) { index, line in
                let values = line.0.map { $0 / top }
                if index == 0 {
                    ChartLine(values: values, slots: count, closed: true)
                        .fill(LinearGradient(colors: [line.1.opacity(0.35), line.1.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                }
                ChartLine(values: values, slots: count, closed: false)
                    .stroke(line.1, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Lines across at a quarter, half and three quarters.
private struct ChartGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for share in [0.25, 0.5, 0.75] {
            let y = rect.height * (1 - share)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// Readings from 0 to 1 as a line against the right edge, one slot apart;
/// `closed` takes it down to the bottom, for the filled area under it.
private struct ChartLine: Shape {
    let values: [Double]
    let slots: Int
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(max(slots - 1, 1))
        let start = rect.width - step * CGFloat(values.count - 1)
        path.addLines(values.enumerated().map { offset, value in
            CGPoint(x: start + step * CGFloat(offset), y: rect.height * (1 - CGFloat(min(1, max(0, value)))))
        })
        if closed {
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: start, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}

/// A share of something, as a thin bar.
private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(color)
                .frame(width: geometry.size.width * CGFloat(min(1, max(0, share))))
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.08))
        .clipShape(Capsule())
    }
}

/// Each core's last minute as a small chart, like Activity Monitor's CPU
/// History, grouped by kind of core with the group's average, and each with
/// what it's at now.
private struct CoreCharts: View {
    let cpu: CPUReading
    let history: (Int) -> [Double]
    let slots: Int

    /// Three or four across, whichever fills the rows evenly: six cores as
    /// two rows of three rather than four and two.
    private static func columns(_ count: Int) -> Int {
        count <= 4 ? max(count, 1) : count % 4 == 0 ? 4 : count % 3 == 0 ? 3 : 4
    }

    var body: some View {
        let groups = cpu.groups.isEmpty ? [CoreGroup(name: "Cores", cores: 0..<cpu.cores.count)] : cpu.groups
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.element.name) { index, group in
                let cores = group.cores.filter { $0 < cpu.cores.count }
                // macOS lists the slower cores first; with more than one kind, those in teal.
                let color: Color = groups.count > 1 && index == 0 ? .teal : .blue
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(group.name)
                        Spacer()
                        Text(StatsController.percent(cores.isEmpty ? 0 : cores.map { cpu.cores[$0] }.reduce(0, +) / Double(cores.count)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: Self.columns(cores.count)), spacing: 6) {
                        ForEach(cores, id: \.self) { core in
                            HistoryChart(series: [(history(core), color)], ceiling: 1, height: 34, slots: slots)
                                .overlay(alignment: .topTrailing) {
                                    Text(StatsController.percent(cpu.cores[core]))
                                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.top, 2)
                                }
                        }
                    }
                }
            }
        }
    }
}

/// Where memory goes, as one bar: what apps need, then what macOS could free.
private struct MemoryBar: View {
    let memory: MemoryReading

    private var parts: [(String, UInt64, Color)] {
        [("App", memory.app, .blue), ("Wired", memory.wired, .orange), ("Compressed", memory.compressed, .purple),
         ("Cached", memory.cached, .gray.opacity(0.5))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2)
                            .frame(width: geometry.size.width * CGFloat(Double(part.1) / Double(max(memory.total, 1))))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.2).frame(width: 7, height: 7)
                        Text(part.0).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(StatsController.memory(part.1)).monospacedDigit()
                    }
                    .font(.caption)
                    .padding(.trailing, 8)
                }
            }
        }
    }
}

/// The apps using the most, with what each uses.
private struct TopList: View {
    let apps: [(AppUsage, String)]

    var body: some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Top apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(apps, id: \.0.id) { app, value in
                    HStack(spacing: 6) {
                        Group {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable()
                            } else {
                                Image(systemName: "gearshape").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 16, height: 16)
                        Text(app.name).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Text(value).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 4)
        }
    }
}
