import SwiftUI

/// The panel a click on AI Usage opens from the menu bar.
struct AIUsagePanelView: View {
    let usage: AIUsageController
    /// The display's room below the menu bar.
    var maxHeight: CGFloat?
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                AIUsageContent(usage: usage)
                    .padding([.horizontal, .top], 14)
                    .background(OverlayScroller())
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider().padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            PanelFooter(openSettings: openSettings)
                .padding([.horizontal, .bottom], 14)
        }
        .frame(width: 320)
        .frame(maxHeight: maxHeight)
    }
}

/// How far back the tokens' chart and split go.
enum AIUsagePeriod: CaseIterable {
    case today, yesterday, month

    var title: LocalizedStringKey {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .month: return "30 Days"
        }
    }

    func range(at now: Date) -> (from: Date, to: Date) {
        let today = Calendar.current.startOfDay(for: now)
        switch self {
        case .today: return (today, now)
        case .yesterday: return (Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today, today.addingTimeInterval(-1))
        case .month: return (now.addingTimeInterval(-30 * 86400), now)
        }
    }

    /// Hours to a point on the chart.
    var step: Int { self == .month ? 24 : 1 }
    /// Points across the chart: today's fills as the day goes on.
    var slots: Int { self == .month ? 30 : 24 }
}

/// What's read of each provider: the panel, and the tool's page.
struct AIUsageContent: View {
    let usage: AIUsageController
    @ObservedObject private var live: AIUsageLive
    @StateObject private var period = ViewState(AIUsagePeriod.today)

    init(usage: AIUsageController) {
        self.usage = usage
        live = usage.live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if live.usage.isEmpty {
                Text(live.isReading ? "Reading…" : "Nothing to show yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(live.usage.enumerated()), id: \.element.provider) { index, provider in
                if index > 0 { Divider().padding(.vertical, 10) }
                section(provider)
            }
        }
    }

    @ViewBuilder
    private func section(_ provider: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: provider.provider.title).font(.headline)
                Spacer()
                if let plan = provider.plan {
                    Text(verbatim: plan).font(.callout).foregroundStyle(.secondary)
                }
            }
            switch provider.state {
            case .notFound: note("Not on this Mac.")
            case .noData: note("Nothing to show yet.")
            case .unreadable: note("Its files have changed and can't be read. An update to the toolkit should bring this back.")
            case .read:
                ForEach(provider.limits) { AIUsageLimitRow(limit: $0, now: live.now) }
                if let tokens = provider.tokens { self.tokens(tokens) }
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private static let modelColors: [Color] = [.purple, .blue, .orange]

    @ViewBuilder
    private func tokens(_ tokens: TokenUsage) -> some View {
        let now = live.now
        let range = period.value.range(at: now)
        // By name: a model's dated and undated IDs are one model.
        let models = Dictionary(tokens.byModel(from: range.from, to: range.to).map { (AIUsageFormat.modelName($0.key), $0.value) }, uniquingKeysWith: +)
            .sorted { $0.value > $1.value }
        let total = max(models.reduce(0) { $0 + $1.value }, 1)
        let parts = Array(models.prefix(3).enumerated().map { (name: $1.key, tokens: $1.value, color: Self.modelColors[$0]) })
            + (models.count > 3 ? [(name: String(localized: "Other"), tokens: models.dropFirst(3).reduce(0) { $0 + $1.value }, color: Color.gray.opacity(0.5))] : [])

        Row("Last 5 hours", AIUsageFormat.tokens(tokens.total(from: now.addingTimeInterval(-5 * 3600), to: now)))
        Row("Last 7 days", AIUsageFormat.tokens(tokens.total(from: now.addingTimeInterval(-7 * 86400), to: now)))
        Picker("Period", selection: $period.value.afterUpdate) {
            ForEach(AIUsagePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        HistoryChart(series: [(tokens.series(from: range.from, to: range.to, step: period.value.step), .purple)], ceiling: nil, slots: period.value.slots)
        StackedBar(parts: parts.map { (Double($0.tokens) / Double(total), $0.color) })
        ForEach(parts, id: \.name) { part in
            HStack(spacing: 4) {
                Circle().fill(part.color).frame(width: 7, height: 7)
                Text(verbatim: part.name).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: AIUsageFormat.tokens(part.tokens)).monospacedDigit()
            }
            .font(.caption)
        }
        note("Counted by the whole hour, so a figure can be up to an hour short. Claude's files don't say how much of its limits is left.")
    }
}

/// A limit as a bar of what's left, with a mark where an even pace would put
/// it, red when this pace runs out before the reset.
private struct AIUsageLimitRow: View {
    let limit: UsageLimit
    let now: Date

    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private func time(_ seconds: TimeInterval) -> String {
        Self.duration.string(from: max(60, seconds)) ?? ""
    }

    var body: some View {
        let left = limit.leftShare(at: now)
        let running = left != nil
        let age = now.timeIntervalSince(limit.readAt)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: limit.title).font(.callout.weight(.medium))
                Spacer()
                if let left {
                    Text("\(Int((left * 100).rounded()))% left").font(.callout).monospacedDigit()
                } else {
                    Text("Not known").font(.callout).foregroundStyle(.secondary)
                }
            }
            ShareBar(share: left ?? 0, color: limit.isOverPace(at: now) ? .red : .purple)
                .overlay {
                    if running {
                        GeometryReader { geometry in
                            Rectangle().fill(Color.primary.opacity(0.7))
                                .frame(width: 1.5, height: 12)
                                .position(x: geometry.size.width * CGFloat(1 - limit.elapsedShare(at: now)), y: geometry.size.height / 2)
                        }
                    }
                }
            HStack {
                if !limit.isFresh(at: now) { Text("Read \(time(age)) ago") }
                Spacer()
                if running {
                    Text("Resets in \(time(limit.resetsAt.timeIntervalSince(now)))")
                } else {
                    Text("Window has ended")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
