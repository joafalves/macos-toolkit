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
            HStack {
                Button("Activity Monitor") {
                    close()
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Settings…", action: openSettings)
            }
            .buttonStyle(.borderless)
            .font(.callout)
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
            let groups = cpu.groups.isEmpty ? [CoreGroup(name: "Cores", cores: 0..<cpu.cores.count)] : cpu.groups
            ForEach(groups, id: \.name) { group in
                HStack(spacing: 8) {
                    Text(group.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(group.cores.filter { $0 < cpu.cores.count }, id: \.self) { core in
                            CoreBar(share: cpu.cores[core])
                        }
                    }
                }
            }
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
struct HistoryChart: View {
    let series: [([Double], Color)]
    /// The top of the chart, or nil for the highest reading.
    let ceiling: Double?

    var body: some View {
        Canvas { context, size in
            let top = max(ceiling ?? series.flatMap(\.0).max() ?? 0, 1e-9)
            let count = max(series.map(\.0.count).max() ?? 0, 2)
            let step = size.width / CGFloat(max(count - 1, 1))
            for line in stride(from: 0.25, through: 0.75, by: 0.25) {
                let y = size.height * (1 - line)
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.primary.opacity(0.07)), lineWidth: 1)
            }
            for (index, (values, color)) in series.enumerated() where values.count > 1 {
                let start = size.width - step * CGFloat(values.count - 1)
                let points = values.enumerated().map { offset, value in
                    CGPoint(x: start + step * CGFloat(offset), y: size.height * (1 - CGFloat(min(1, max(0, value / top)))))
                }
                var line = Path()
                line.addLines(points)
                if index == 0 {
                    var area = line
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    area.addLine(to: CGPoint(x: start, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.05)]),
                                                            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .frame(height: 64)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// One core's share, as a short bar.
private struct CoreBar: View {
    let share: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
            RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.8))
                .frame(height: max(1, 22 * share))
        }
        .frame(width: 10, height: 22)
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
