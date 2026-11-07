import Foundation

/// A service whose usage the tool reads.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    /// A product's name, the same in every language.
    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Whether it tells of its limits, which a pill fills to: Claude Code
    /// only has tokens.
    var hasLimits: Bool { self == .codex }

    /// Its own pill's symbol, so two side by side can be told apart. Plain
    /// shapes, not either product's mark.
    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "hexagon"
        }
    }
}

/// A limit a provider itself reports, as of when it was read.
struct UsageLimit: Equatable, Identifiable {
    let provider: AIProvider
    let windowMinutes: Int
    let usedShare: Double
    let resetsAt: Date
    let readAt: Date

    var id: String { "\(provider.rawValue) \(windowMinutes)" }

    var title: String {
        switch windowMinutes {
        case 10080: return String(localized: "Weekly")
        default:
            let hours = max(1, windowMinutes / 60)
            return String(localized: "\(hours) hours")
        }
    }

    /// How old a reading can be and pass for now.
    static let freshFor: TimeInterval = 3600

    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(readAt) <= Self.freshFor }

    func isRunning(at now: Date) -> Bool { now < resetsAt }

    /// Nil once its window has ended: what was read says nothing about the
    /// next one, which may have been used from elsewhere.
    func leftShare(at now: Date) -> Double? {
        isRunning(at: now) ? min(1, max(0, 1 - usedShare)) : nil
    }

    /// How far through its window it is: at an even pace, what would be used by now.
    func elapsedShare(at now: Date) -> Double {
        let window = Double(windowMinutes) * 60
        guard window > 0 else { return 0 }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / window))
    }

    /// At this pace it runs out before the reset. Not at the very start of a
    /// window, nor on a little use, where one request looks like a sprint.
    func isOverPace(at now: Date) -> Bool {
        guard isRunning(at: now) else { return false }
        let elapsed = elapsedShare(at: now)
        return usedShare >= 1 || (elapsed >= 0.05 && usedShare >= 0.1 && usedShare > elapsed)
    }
}

/// Tokens by the hour and model, without what's read back from a cache, which
/// dwarfs the rest and costs next to nothing.
struct TokenUsage: Equatable {
    /// By hours since 1970.
    var hours: [Int: [String: Int]] = [:]

    static func hour(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 3600) }

    func total(from: Date, to: Date) -> Int {
        byModel(from: from, to: to).values.reduce(0, +)
    }

    /// By whole hours from the first to start within the range, so a figure
    /// never covers more than it says, nor counts the hour before it.
    func byModel(from: Date, to: Date) -> [String: Int] {
        var models: [String: Int] = [:]
        let first = Int((from.timeIntervalSince1970 / 3600).rounded(.up))
        for hour in first..<max(first, Self.hour(to) + 1) {
            for (model, tokens) in hours[hour] ?? [:] { models[model, default: 0] += tokens }
        }
        return models
    }

    /// One figure per `step` hours, oldest first, whole ones counted back from
    /// `to`: counted from `from`, the last would be an hour against a day.
    func series(from: Date, to: Date, step: Int) -> [Double] {
        let (first, last) = (Self.hour(from), Self.hour(to))
        guard first <= last, step > 0 else { return [] }
        let count = (last - first + 1) / step
        return (0..<count).map { index in
            let start = last + 1 - step * (count - index)
            return (start..<(start + step)).reduce(0.0) { $0 + Double(hours[$1]?.values.reduce(0, +) ?? 0) }
        }
    }
}

/// What a source has to say.
struct ProviderUsage: Equatable {
    enum State: Equatable {
        /// Its folder isn't on this Mac.
        case notFound
        /// Its folder is there, with nothing in it to read yet.
        case noData
        /// Its files have lines of the kind that matter, none of which could
        /// be read: its format has changed, which shouldn't look like no use.
        case unreadable
        case read
    }

    let provider: AIProvider
    var state: State
    var plan: String?
    var limits: [UsageLimit] = []
    var tokens: TokenUsage?
}

/// Reads one provider's files. Called on the reader's queue only.
protocol AIUsageSource: AnyObject {
    var provider: AIProvider { get }
    /// The folders it reads, which the reader watches.
    var roots: [URL] { get }
    /// `cancelled` is checked along the way: a first read can take a while,
    /// and turning the tool off shouldn't wait for it.
    func read(cancelled: () -> Bool) -> ProviderUsage
}

enum AIUsageFormat {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }

    /// 840, 12K, 1.2M: at most four characters, so its part keeps its width.
    static func tokens(_ count: Int) -> String {
        let units = ["", "K", "M", "B"]
        var value = Double(max(0, count))
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = value < 9.95 && unit > 0 ? String(format: "%.1f", locale: .current, value) : "\(Int(value.rounded()))"
        return digits + units[unit]
    }

    /// The widest `tokens` gets.
    static let widestTokens = "888M"

    /// claude-opus-5-5 is Opus 5.5, and a date at the end is left out.
    static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if parts.last?.count == 8, parts.last?.allSatisfy(\.isNumber) == true { parts.removeLast() }
        let numbers = parts.filter { $0.allSatisfy(\.isNumber) }
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        guard !words.isEmpty else { return id }
        return (words + (numbers.isEmpty ? [] : [numbers.joined(separator: ".")])).joined(separator: " ")
    }
}

/// Memory to read files into, straight from the system and back to it:
/// malloc keeps a large block it's freed for reuse, so a buffer grown for a
/// long line, or a file's last megabytes, went on counting against the app,
/// 20 MB after Claude Code's first read and 13 after Codex's.
enum ReadPages {
    /// Empty if the system has none to give, and then nothing's read this time.
    static func take(_ count: Int) -> UnsafeMutableRawBufferPointer {
        guard count > 0, let start = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), start != MAP_FAILED else {
            return UnsafeMutableRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeMutableRawBufferPointer(start: start, count: count)
    }

    static func release(_ pages: UnsafeMutableRawBufferPointer) {
        guard let start = pages.baseAddress else { return }
        munmap(start, pages.count)
    }

    static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = bytes.baseAddress, bytes.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, needle.count) } != nil
    }
}
