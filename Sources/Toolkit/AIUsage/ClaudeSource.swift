import Foundation

/// Claude Code writes each response's tokens into its transcripts, a gigabyte
/// of them on a Mac in daily use, and they say nothing of how much of a limit
/// is left. Only what's new in each is read, and what's been added up is kept
/// in a small file, so a restart doesn't read them all again. That file holds
/// figures and the transcripts' paths, none of what's in them.
final class ClaudeSource: AIUsageSource {
    let provider = AIProvider.claude
    let root: URL
    private let cacheURL: URL?
    /// The furthest back anything shows.
    private let keptDays = 31
    private let chunk = 1 << 20
    private let saveEvery: TimeInterval = 300

    private struct Seen: Codable {
        var tokens: Int32
        var hour: Int32
    }

    private struct Cache: Codable {
        var version = 1
        var offsets: [String: UInt64] = [:]
        var hours: [Int: [String: Int]] = [:]
        /// One response takes a line per block of what it says, all with its
        /// tokens so far: half of the lines in practice, and the last has the
        /// most. By a hash of its IDs, the same from one launch to the next.
        var seen: [UInt64: Seen] = [:]
        /// Lines in a row that looked like usage and couldn't be read. Kept, as
        /// the offsets have moved past them. A parser that reads a new format
        /// raises `version`, so they're counted after all.
        var unreadLines = 0
    }

    private var cache = Cache()
    private var unsaved = false
    private var lastSave = Date.distantPast
    private var loaded = false

    private struct Line: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
            }
            let id: String?
            let model: String?
            let usage: Usage?
        }
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    private static let marker = Data("\"usage\"".utf8)
    private static let tokensMarker = Data("\"input_tokens\"".utf8)
    /// A conversation can quote a few lines like these.
    private static let unreadableFrom = 10
    private static let decoder = JSONDecoder()

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"), cacheURL: URL? = ClaudeSource.defaultCacheURL) {
        self.root = root
        self.cacheURL = cacheURL
    }

    /// At the first read, on the reader's queue: tens of thousands of entries,
    /// which would hold up the launch on the main thread.
    private func load() {
        guard !loaded else { return }
        loaded = true
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let saved = try? PropertyListDecoder().decode(Cache.self, from: data), saved.version == cache.version {
            cache = saved
        }
    }

    static var defaultCacheURL: URL {
        AIUsageConfig.fileURL.deletingLastPathComponent().appendingPathComponent("ai-usage-claude.plist")
    }

    /// With the tool off, nothing it read stays behind.
    static func forgetCache() {
        try? FileManager.default.removeItem(at: defaultCacheURL)
    }

    func read(cancelled: () -> Bool) -> ProviderUsage {
        guard FileManager.default.fileExists(atPath: root.path) else { return ProviderUsage(provider: provider, state: .notFound) }
        load()
        let now = Date()
        let oldest = now.addingTimeInterval(-Double(keptDays) * 86400)
        var present = Set<String>()
        for file in files() where file.date >= oldest {
            guard !cancelled() else { break }
            present.insert(file.url.path)
            autoreleasepool { readNew(in: file, oldest: oldest, cancelled: cancelled) }
        }
        guard !cancelled() else {
            save(force: true)
            return ProviderUsage(provider: provider, state: .noData)
        }
        // Out of the window or deleted: figures already added up stay until they're old.
        if cache.offsets.keys.contains(where: { !present.contains($0) }) {
            cache.offsets = cache.offsets.filter { present.contains($0.key) }
            unsaved = true
        }
        prune(before: oldest)
        save(force: false)

        if cache.unreadLines >= Self.unreadableFrom {
            Log.aiUsage.error("Claude's transcripts have usage in a format that can't be read")
            return ProviderUsage(provider: provider, state: .unreadable)
        }
        guard !cache.hours.isEmpty else { return ProviderUsage(provider: provider, state: .noData) }
        return ProviderUsage(provider: provider, state: .read, tokens: TokenUsage(hours: cache.hours))
    }

    private func files() -> [(url: URL, date: Date, size: UInt64)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return [] }
        var found: [(url: URL, date: Date, size: UInt64)] = []
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: keys), let date = values.contentModificationDate, let size = values.fileSize else { continue }
            found.append((url, date, UInt64(size)))
        }
        return found
    }

    /// Whole lines only: the rest of one still being written waits for next time.
    private func readNew(in file: (url: URL, date: Date, size: UInt64), oldest: Date, cancelled: () -> Bool) {
        var offset = cache.offsets[file.url.path] ?? 0
        // Shorter than it was: a different file. `seen` keeps what's in both from counting twice.
        if file.size < offset { offset = 0 }
        guard file.size > offset, let handle = try? FileHandle(forReadingFrom: file.url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var pending = Data()
        while !cancelled() {
            let piece: Data
            do {
                guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { break }
                piece = data
            } catch {
                break
            }
            // A line can be many chunks long, so the search starts at the new piece.
            var searchFrom = pending.count
            pending.append(piece)
            var lineStart = 0
            while let newline = pending[searchFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                add(pending[lineStart..<newline], oldest: oldest)
                lineStart = newline + 1
                searchFrom = lineStart
            }
            if lineStart > 0 {
                offset += UInt64(lineStart)
                pending = Data(pending[lineStart...])
            }
        }
        if cache.offsets[file.url.path] != offset {
            cache.offsets[file.url.path] = offset
            unsaved = true
        }
    }

    private func add(_ line: Data, oldest: Date) {
        guard line.range(of: Self.marker) != nil else { return }
        // Only a line with what a usage has in it counts against the format:
        // the text of a conversation can say "usage" too.
        guard let parsed = try? Self.decoder.decode(Line.self, from: Data(line)), let message = parsed.message, let usage = message.usage,
              let id = message.id, let date = AIUsageFormat.date(parsed.timestamp), usage.input_tokens != nil || usage.output_tokens != nil,
              let tokens = Self.tokens(usage) else {
            if line.range(of: Self.tokensMarker) != nil {
                cache.unreadLines += 1
                unsaved = true
            }
            return
        }
        if cache.unreadLines > 0 {
            cache.unreadLines = 0
            unsaved = true
        }
        guard date >= oldest else { return }
        // A response with none: Claude Code's own messages, not a model's.
        guard tokens > 0, let model = message.model else { return }
        let key = Self.hash(id + "/" + (parsed.requestId ?? ""))
        let hour = cache.seen[key].map { Int($0.hour) } ?? TokenUsage.hour(date)
        let added = tokens - Int(cache.seen[key]?.tokens ?? 0)
        guard added > 0 else { return }
        cache.seen[key] = Seen(tokens: Int32(clamping: tokens), hour: Int32(clamping: hour))
        cache.hours[hour, default: [:]][model, default: 0] += added
        unsaved = true
    }

    /// Nil for figures no response could have: added up unchecked, they'd trap.
    private static func tokens(_ usage: Line.Message.Usage) -> Int? {
        let figures = [usage.input_tokens, usage.output_tokens, usage.cache_creation_input_tokens].map { $0 ?? 0 }
        return figures.allSatisfy({ (0...Int(Int32.max)).contains($0) }) ? figures.reduce(0, +) : nil
    }

    private func prune(before oldest: Date) {
        let first = TokenUsage.hour(oldest)
        guard cache.hours.keys.contains(where: { $0 < first }) else { return }
        cache.hours = cache.hours.filter { $0.key >= first }
        cache.seen = cache.seen.filter { Int($0.value.hour) >= first }
        unsaved = true
    }

    /// Now and then rather than with each read, as it's a couple of megabytes.
    /// What's lost in a crash is read again: `seen` went with the offsets.
    private func save(force: Bool) {
        guard unsaved, let cacheURL, force || Date().timeIntervalSince(lastSave) >= saveEvery else { return }
        lastSave = Date()
        unsaved = false
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    /// FNV-1a: Swift's own hash differs from one launch to the next.
    private static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01b3
        }
        return value
    }
}
