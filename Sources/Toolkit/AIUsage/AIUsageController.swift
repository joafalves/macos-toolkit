import AppKit
import Combine
import UserNotifications

/// System Stats' AI usage stat: what the AI tools on this Mac have already
/// written down about their limits and tokens, read from their own files. No
/// network and no credentials. Read on its own, when the files change, not on
/// System Stats' timer; with the stat off there's no reader, no watcher, no
/// timer and nothing held.
final class AIUsageController: ObservableObject {
    @Published var config: AIUsageConfig {
        didSet {
            guard config != oldValue else { return }
            if persists { config.save() }
            if config.warnings, !oldValue.warnings { askToNotify() }
            apply()
        }
    }

    /// Set by System Stats: the stat is in the menu bar or the panel, and
    /// System Stats is on.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            if !active, persists { UserDefaults.standard.removeObject(forKey: Self.warnedKey) }
            apply()
        }
    }

    /// What's read, apart from the settings: the page watches this object.
    let live = AIUsageLive()

    /// False for `--snapshot`: settings aren't saved.
    var persists = true
    private var isPreview = false
    private var reader: AIUsageReader?
    /// What the running reader reads: a change starts it afresh.
    private var readerProviders: [AIProvider] = []
    /// Goes up as a reader stops: what it had already sent is out of date.
    private var readerGeneration = 0
    /// What's shown depends on the time as well: a window ends, and the hours
    /// behind a figure move on.
    private var clock: Timer?

    init() {
        config = AIUsageConfig.load()
    }

    /// At launch, before System Stats sets `active`.
    func start(active: Bool) {
        // Turned off and quit before the reader got to it.
        if !(active && config.claude) { ClaudeTranscripts.forgetCache() }
        self.active = active
    }

    func stop() {
        reader?.stop()
        reader = nil
        readerProviders = []
        clock?.invalidate()
        clock = nil
    }

    /// Made-up usage, for `--snapshot`: nothing from this Mac.
    static func preview() -> AIUsageController {
        let usage = AIUsageController()
        usage.persists = false
        usage.isPreview = true
        var config = AIUsageConfig()
        config.claude = true
        usage.config = config
        usage.live.usage = previewUsage(at: usage.live.now)
        return usage
    }

    private static func previewUsage(at now: Date) -> [ProviderUsage] {
        let codex = ProviderUsage(provider: .codex, state: .read, plan: "Plus", limits: [
            UsageLimit(provider: .codex, windowMinutes: 300, usedShare: 0.62, resetsAt: now.addingTimeInterval(2.5 * 3600), readAt: now.addingTimeInterval(-300)),
            UsageLimit(provider: .codex, windowMinutes: 10080, usedShare: 0.24, resetsAt: now.addingTimeInterval(4.3 * 86400), readAt: now.addingTimeInterval(-300)),
        ])
        var tokens = TokenUsage()
        let hour = TokenUsage.hour(now)
        for back in 0..<(31 * 24) {
            let wave = 0.5 + 0.5 * sin(Double(back) / 5)
            guard back % 24 < 12 else { continue }
            tokens.hours[hour - back] = ["claude-opus-5-5": Int(90_000 * wave), "claude-sonnet-5-5": Int(30_000 * wave), "claude-haiku-5-5": Int(8_000 * wave)]
        }
        return [ProviderUsage(provider: .claude, state: .read, tokens: tokens), codex]
    }

    // MARK: - The menu bar

    /// The limit closest to running out among `providers`, of those whose
    /// windows are running and read lately: the pill has no room to say how
    /// old a figure is, so an old one would pass for now. The panel shows
    /// those, with their age.
    func tightestLimit(at now: Date, among providers: [AIProvider] = AIProvider.allCases) -> UsageLimit? {
        live.usage.filter { providers.contains($0.provider) }.flatMap(\.limits)
            .filter { $0.isRunning(at: now) && $0.isFresh(at: now) }
            .min { ($0.leftShare(at: now) ?? 1) < ($1.leftShare(at: now) ?? 1) }
    }

    /// What the stat's pill fills to: what's left of the tightest limit.
    func share(at now: Date) -> Double? {
        tightestLimit(at: now).flatMap { $0.leftShare(at: now) }
    }

    /// The stat's figure: what's left of the tightest limit, or with none
    /// read lately, Claude Code's tokens in the last 5 hours.
    func figure(at now: Date) -> String? {
        if let left = share(at: now) { return StatsController.percent(left) }
        if let tokens = live.usage.compactMap(\.tokens).first {
            return AIUsageFormat.tokens(tokens.total(from: now.addingTimeInterval(-5 * 3600), to: now))
        }
        return nil
    }

    /// The figure in words, for the panel: what's left, or tokens.
    func headline(at now: Date) -> String? {
        if let left = share(at: now) { return String(localized: "\(min(100, Int((left * 100).rounded())))% left") }
        return figure(at: now).map { String(localized: "\($0) tokens") }
    }

    /// The pill's text: a percent without its sign, as the other stats', or tokens.
    func pillText(at now: Date) -> String? {
        if let left = share(at: now) { return "\(min(100, Int((left * 100).rounded())))" }
        return figure(at: now)
    }

    /// Red when the tightest limit runs out before its reset at this pace.
    func isOverPace(at now: Date) -> Bool {
        tightestLimit(at: now)?.isOverPace(at: now) ?? false
    }

    /// A reader for what's turned on. A change of what it reads starts it afresh.
    func apply() {
        guard !isPreview else { return }
        let providers = active ? config.providers : []
        if providers != readerProviders { restartReader(providers) }
        if providers.isEmpty {
            clock?.invalidate()
            clock = nil
        } else if clock == nil {
            let clock = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.live.now = Date() }
            clock.tolerance = 10
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        }
    }

    private func restartReader(_ providers: [AIProvider]) {
        // After the reader has done with it, as it could save it once more.
        let forget = readerProviders.contains(.claude) && !providers.contains(.claude)
        reader?.stop(afterwards: forget ? ClaudeTranscripts.forgetCache : nil)
        reader = nil
        readerGeneration += 1
        readerProviders = providers
        live.usage = live.usage.filter { providers.contains($0.provider) }
        guard !providers.isEmpty else {
            live.isReading = false
            return
        }
        live.isReading = true
        let generation = readerGeneration
        let sources: [AIUsageSource] = providers.map { provider in
            switch provider {
            case .claude: return ClaudeTranscripts()
            case .codex: return CodexSource()
            }
        }
        let reader = AIUsageReader(sources: sources) { [weak self] usage in
            guard let self, generation == readerGeneration else { return }
            live.isReading = false
            received(usage)
        }
        self.reader = reader
        reader.start()
    }

    private func received(_ usage: [ProviderUsage]) {
        live.now = Date()
        live.usage = usage
        warn(usage)
    }

    // MARK: - Warnings

    static let warnedShare = 0.8

    /// By `UsageLimit.id`, when the window warned of resets. Remembered in the
    /// defaults, so a restart doesn't warn again; not a setting to export.
    private static let warnedKey = "aiUsageWarned"

    /// The limits to warn of now: past the mark and not warned of in this
    /// window. A window's reset time moves by a little from one reading to the
    /// next, so one within half a window of the last is the same window.
    static func toWarn(_ usage: [ProviderUsage], warned: [String: Double], at now: Date) -> [UsageLimit] {
        usage.flatMap(\.limits).filter { limit in
            guard limit.isRunning(at: now), limit.usedShare >= warnedShare else { return false }
            guard let last = warned[limit.id] else { return true }
            return abs(last - limit.resetsAt.timeIntervalSince1970) > Double(limit.windowMinutes) * 30
        }
    }

    private func askToNotify() {
        guard persists, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func warn(_ usage: [ProviderUsage]) {
        guard config.warnings, persists, Bundle.main.bundleIdentifier != nil else { return }
        let defaults = UserDefaults.standard
        var warned = defaults.dictionary(forKey: Self.warnedKey) as? [String: Double] ?? [:]
        let now = live.now
        for limit in Self.toWarn(usage, warned: warned, at: now) {
            warned[limit.id] = limit.resetsAt.timeIntervalSince1970
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(limit.provider.title) is running short")
            content.body = String(localized: "\(limit.title): \(Int(((limit.leftShare(at: now) ?? 0) * 100).rounded()))% left")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ai-usage-\(limit.id)", content: content, trigger: nil))
        }
        defaults.set(warned, forKey: Self.warnedKey)
    }
}

/// What AI Usage has read.
final class AIUsageLive: ObservableObject {
    @Published var usage: [ProviderUsage] = []
    /// Nothing read yet since the reader started.
    @Published var isReading = false
    @Published var now = Date()
}
