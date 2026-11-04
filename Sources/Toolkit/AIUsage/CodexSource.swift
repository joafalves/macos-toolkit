import Foundation

/// Codex writes the limits it's told of into its session files, with each
/// response: the latest is at the end of the latest file. No network and no
/// credentials, but nothing new while Codex isn't running.
final class CodexSource: AIUsageSource {
    let provider = AIProvider.codex
    let root: URL
    /// A session's last lines are what count, and one tool's output can be long.
    private let tail = 2 << 20
    /// How many of the latest files can hold the latest report.
    private let filesTried = 8
    /// What each of those files had in it, kept until it changes.
    private var known: [String: (date: Date, usage: ProviderUsage?)] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) {
        self.root = root
    }

    private struct Line: Decodable {
        struct Payload: Decodable {
            let type: String?
            let rate_limits: RateLimits?
        }
        let timestamp: String?
        let payload: Payload?
    }

    private struct RateLimits: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let window_minutes: Int?
            let resets_at: Double?
        }
        let limit_id: String?
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }

    func read(cancelled: () -> Bool) -> ProviderUsage {
        guard FileManager.default.fileExists(atPath: root.path) else { return ProviderUsage(provider: provider, state: .notFound) }
        let files = sessionFiles().prefix(filesTried)
        guard !files.isEmpty else { return ProviderUsage(provider: provider, state: .noData) }
        var kept: [String: (date: Date, usage: ProviderUsage?)] = [:]
        for file in files {
            if let same = known[file.url.path], same.date == file.date {
                kept[file.url.path] = same
            } else {
                kept[file.url.path] = (file.date, latest(in: file.url))
            }
        }
        known = kept
        // The latest report, wherever it is: the file changed last may be a
        // session still at work on something, whose last report is older.
        // Newest file first, which a tie goes to.
        let found = files.compactMap { kept[$0.url.path]?.usage }
        if let newest = found.filter({ $0.state == .read }).max(by: { Self.readAt($0) < Self.readAt($1) }) { return newest }
        if found.contains(where: { $0.state == .unreadable }) {
            Log.aiUsage.error("Codex's session files have limits in a format that can't be read")
            return ProviderUsage(provider: provider, state: .unreadable)
        }
        return ProviderUsage(provider: provider, state: .noData)
    }

    private static func readAt(_ usage: ProviderUsage) -> Date {
        usage.limits.map(\.readAt).max() ?? .distantPast
    }

    private func sessionFiles() -> [(url: URL, date: Date)] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var found: [(url: URL, date: Date)] = []
        for case let url as URL in files where url.pathExtension == "jsonl" {
            found.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
        }
        return found.sorted { $0.date > $1.date }
    }

    /// The last line with limits in the file; nil if it has no such line.
    private func latest(in url: URL) -> ProviderUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(tail) ? size - UInt64(tail) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var sawUnreadable = false
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: Data("\"rate_limits\"".utf8)) != nil else { continue }
            switch Self.parse(Data(line)) {
            case .limits(let usage): return usage
            case .unreadable: sawUnreadable = true
            case .none: break
            }
        }
        return sawUnreadable ? ProviderUsage(provider: provider, state: .unreadable) : nil
    }

    enum Parsed {
        case limits(ProviderUsage)
        /// A report of limits in a shape that can't be read: the format may have changed.
        case unreadable
        /// Not Codex's limits: a conversation quoting the word, an account
        /// with no limits, or another limit of the plan's, such as a model's.
        case none
    }

    static func parse(_ line: Data) -> Parsed {
        guard let parsed = try? JSONDecoder().decode(Line.self, from: line) else {
            return line.range(of: Data("\"token_count\"".utf8)) != nil ? .unreadable : .none
        }
        guard parsed.payload?.type == "token_count", let limits = parsed.payload?.rate_limits,
              limits.limit_id == nil || limits.limit_id == "codex" else { return .none }
        let readAt = AIUsageFormat.date(parsed.timestamp) ?? .distantPast
        let windows = [limits.primary, limits.secondary].compactMap { window -> UsageLimit? in
            guard let window, let used = window.used_percent, let minutes = window.window_minutes, minutes > 0,
                  let resets = window.resets_at else { return nil }
            return UsageLimit(provider: .codex, windowMinutes: minutes, usedShare: min(1, max(0, used / 100)),
                              resetsAt: Date(timeIntervalSince1970: resets), readAt: readAt)
        }
        guard !windows.isEmpty else {
            // Windows there, without what a window has.
            return limits.primary != nil || limits.secondary != nil ? .unreadable : .none
        }
        return .limits(ProviderUsage(provider: .codex, state: .read, plan: limits.plan_type.map { $0.prefix(1).uppercased() + $0.dropFirst() }, limits: windows))
    }
}
