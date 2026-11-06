import SwiftUI

/// The AI usage stat's section of System Stats' panel: its figure, then a
/// tab for all of them and one for each provider. The page has the rest.
/// Watches AI usage's own readings, which come apart from System Stats'.
struct AIUsageStatSection: View {
    let usage: AIUsageController
    @ObservedObject private var live: AIUsageLive
    @StateObject private var tab = ViewState(AIUsageTab.overview)

    init(usage: AIUsageController) {
        self.usage = usage
        live = usage.live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(StatKind.ai.title, systemImage: StatKind.ai.symbol)
                    .font(.headline)
                Spacer()
                if let headline = usage.headline(at: live.now) {
                    Text(verbatim: headline)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(usage.isOverPace(at: live.now) ? .red : .primary)
                }
            }
            AIUsageContent(usage: usage, tab: tab, detailed: false)
        }
    }
}

/// What the panel and the page show: every provider, or one.
enum AIUsageTab: Hashable {
    case overview
    case provider(AIProvider)
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

/// The tabs, in a row that scrolls sideways once there are more than fit,
/// faded at its end so one cut off shows there's more.
struct AIUsageTabs: View {
    let tabs: [AIUsageTab]
    @ObservedObject var selection: ViewState<AIUsageTab>

    private func title(_ tab: AIUsageTab) -> Text {
        switch tab {
        case .overview: return Text("Overview")
        case .provider(let provider): return Text(verbatim: provider.title)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs, id: \.self) { tab in
                        let selected = tab == selection.value
                        Button {
                            selection.value = tab
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(tab, anchor: .center) }
                        } label: {
                            title(tab)
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(selected ? 0.1 : 0)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(tab)
                    }
                }
                // Room for the fade, so a row that fits isn't faded.
                .padding(.trailing, 16)
            }
            .mask(HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
            })
            .onAppear { proxy.scrollTo(selection.value, anchor: .center) }
        }
    }
}

/// What's read of each provider, for the panel (`detailed` false) and the
/// tool's page, which adds the token history's chart and split.
struct AIUsageContent: View {
    let usage: AIUsageController
    @ObservedObject private var live: AIUsageLive
    @ObservedObject private var tab: ViewState<AIUsageTab>
    let detailed: Bool
    var openSettings: () -> Void = {}
    @StateObject private var period = ViewState(AIUsagePeriod.today)

    init(usage: AIUsageController, tab: ViewState<AIUsageTab>, detailed: Bool, openSettings: @escaping () -> Void = {}) {
        self.usage = usage
        live = usage.live
        self.tab = tab
        self.detailed = detailed
        self.openSettings = openSettings
    }

    /// The panel leaves out a provider that isn't on this Mac; the page says so.
    private var shown: [ProviderUsage] {
        live.usage.filter { detailed || $0.state != .notFound }
    }

    var body: some View {
        let shown = shown
        VStack(alignment: .leading, spacing: 10) {
            if shown.isEmpty {
                Text(live.isReading ? "Reading…" : "Nothing to show yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if shown.count == 1 {
                section(shown[0])
            } else {
                let tabs = [AIUsageTab.overview] + shown.map { .provider($0.provider) }
                let selected = tabs.contains(tab.value) ? tab.value : .overview
                AIUsageTabs(tabs: tabs, selection: tab)
                switch selected {
                case .overview: overview(shown)
                case .provider(let provider):
                    if let found = shown.first(where: { $0.provider == provider }) { section(found) }
                }
            }
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private func overview(_ shown: [ProviderUsage]) -> some View {
        let now = live.now
        VStack(alignment: .leading, spacing: 12) {
            // The one a single pill would show, when there's more than one to pick from.
            if shown.filter({ !$0.limits.isEmpty }).count > 1, let tightest = usage.tightestLimit(at: now) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Closest to running out").font(.caption).foregroundStyle(.secondary)
                    AIUsageLimitRow(limit: tightest, now: now, title: "\(tightest.provider.title) · \(tightest.title)")
                }
                Divider()
            }
            ForEach(shown, id: \.provider) { provider in
                Button {
                    tab.value = .provider(provider.provider)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        header(provider, chevron: true)
                        summary(provider)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A provider in a line or two: its tightest limit, or what it does have.
    @ViewBuilder
    private func summary(_ provider: ProviderUsage) -> some View {
        let now = live.now
        let running = provider.limits.filter { $0.isRunning(at: now) }
        if provider.state == .read, let limit = running.min(by: { ($0.leftShare(at: now) ?? 1) < ($1.leftShare(at: now) ?? 1) }) ?? provider.limits.first {
            AIUsageLimitRow(limit: limit, now: now)
        } else if provider.state == .read, let tokens = provider.tokens {
            Row("Last 5 hours", String(localized: "\(AIUsageFormat.tokens(tokens.total(from: now.addingTimeInterval(-5 * 3600), to: now))) tokens"))
        } else {
            status(provider)
        }
    }

    // MARK: - One provider

    @ViewBuilder
    private func section(_ provider: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(provider, chevron: false)
            switch provider.state {
            case .read:
                ForEach(provider.limits) { AIUsageLimitRow(limit: $0, now: live.now) }
                if let tokens = provider.tokens { self.tokens(tokens) }
                if provider.provider == .claude, provider.limits.isEmpty { claudeLimitsNote() }
            default:
                status(provider)
            }
        }
    }

    private func header(_ provider: ProviderUsage, chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: provider.provider.title).font(.headline)
            Spacer()
            if let plan = provider.plan {
                Text(verbatim: plan).font(.callout).foregroundStyle(.secondary)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }

    /// Why there's nothing to show.
    @ViewBuilder
    private func status(_ provider: ProviderUsage) -> some View {
        switch provider.state {
        case .notFound: note("Not on this Mac.")
        case .unreadable: note("Its files have changed and can't be read. An update to the toolkit should bring this back.")
        case .noData, .read:
            note(live.isReading ? "Reading…" : "Nothing to show yet.")
        }
    }

    /// Its limits are only in its own `/usage`, which it doesn't hand to
    /// other apps without its credential: tokens are what there is.
    private func claudeLimitsNote() -> some View {
        note("Claude Code doesn't give other apps its limits, so only what it has used shows here.")
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Tokens

    private static let modelColors: [Color] = [.purple, .blue, .orange]

    @ViewBuilder
    private func tokens(_ tokens: TokenUsage) -> some View {
        let now = live.now
        Row("Last 5 hours", AIUsageFormat.tokens(tokens.total(from: now.addingTimeInterval(-5 * 3600), to: now)))
        Row("Last 7 days", AIUsageFormat.tokens(tokens.total(from: now.addingTimeInterval(-7 * 86400), to: now)))
        if detailed { history(tokens) }
    }

    @ViewBuilder
    private func history(_ tokens: TokenUsage) -> some View {
        let now = live.now
        let range = period.value.range(at: now)
        // By name: a model's dated and undated IDs are one model.
        let models = Dictionary(tokens.byModel(from: range.from, to: range.to).map { (AIUsageFormat.modelName($0.key), $0.value) }, uniquingKeysWith: +)
            .sorted { $0.value > $1.value }
        let total = max(models.reduce(0) { $0 + $1.value }, 1)
        let parts = Array(models.prefix(3).enumerated().map { (name: $1.key, tokens: $1.value, color: Self.modelColors[$0]) })
            + (models.count > 3 ? [(name: String(localized: "Other"), tokens: models.dropFirst(3).reduce(0) { $0 + $1.value }, color: Color.gray.opacity(0.5))] : [])

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
        note("Without what's read back from the cache. Counted by the whole hour, so a figure can be up to an hour short.")
    }
}

/// A limit as a bar of what's left, with a mark where an even pace would put
/// it, red when this pace runs out before the reset.
struct AIUsageLimitRow: View {
    let limit: UsageLimit
    let now: Date
    /// In place of the limit's own, as the overview names its provider too.
    var title: String?

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
                Text(verbatim: title ?? limit.title).font(.callout.weight(.medium))
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
