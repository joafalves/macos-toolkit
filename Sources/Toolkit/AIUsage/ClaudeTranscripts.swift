import Foundation

/// Claude Code writes each response's tokens into its transcripts, more than
/// a gigabyte a month on a Mac in daily use. Only what's new in each is read,
/// and what's been added up is kept in a small file, so a restart doesn't
/// read them all again. That file holds figures and the transcripts' paths,
/// none of what's in them.
///
/// The few fields counted are picked out of each line's bytes as they're
/// read, through a buffer that's reused: decoding the lines whole, a
/// conversation's text with them, took hundreds of megabytes on a first read.
final class ClaudeTranscripts: AIUsageSource {
    let provider = AIProvider.claude
    let root: URL
    var roots: [URL] { [root] }
    private let cacheURL: URL?
    /// The furthest back anything shows.
    private let keptDays = 31
    private let chunk = 1 << 20
    /// A line longer than this is passed over: no response's figures are on one.
    private let longestLine = 64 << 20
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
        /// most. A resumed session copies earlier ones into its own file. By a
        /// hash of its IDs, the same from one launch to the next.
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

    private static let marker = Array("\"usage\"".utf8)
    private static let tokensMarker = Array("\"input_tokens\"".utf8)
    /// A conversation can quote a few lines like these.
    private static let unreadableFrom = 10

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"), cacheURL: URL? = ClaudeTranscripts.defaultCacheURL) {
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

    /// With token history off, nothing it read stays behind.
    static func forgetCache() {
        try? FileManager.default.removeItem(at: defaultCacheURL)
    }

    func read(cancelled: () -> Bool) -> ProviderUsage {
        guard FileManager.default.fileExists(atPath: root.path) else { return ProviderUsage(provider: provider, state: .notFound) }
        load()
        let now = Date()
        let oldest = now.addingTimeInterval(-Double(keptDays) * 86400)
        var present = Set<String>()
        var reading = ReadPages.take(chunk)
        defer { ReadPages.release(reading) }
        // Each file's URLs and attributes let go of as it's done with.
        let files = autoreleasepool { self.files() }
        for file in files where file.date >= oldest {
            guard !cancelled() else { break }
            present.insert(file.url.path)
            autoreleasepool { readNew(in: file, oldest: oldest, buffer: &reading, cancelled: cancelled) }
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
            Log.aiUsage.error("Claude Code's transcripts have usage in a format that can't be read")
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

    /// Whole lines only: the rest of one still being written waits for next
    /// time. The buffer grows for a long line and is kept for the next file.
    private func readNew(in file: (url: URL, date: Date, size: UInt64), oldest: Date, buffer: inout UnsafeMutableRawBufferPointer, cancelled: () -> Bool) {
        var offset = cache.offsets[file.url.path] ?? 0
        // Shorter than it was: a different file. `seen` keeps what's in both from counting twice.
        if file.size < offset { offset = 0 }
        guard file.size > offset, buffer.count > 0 else { return }
        let descriptor = open(file.url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var filled = 0
        // Past a line too long to hold, up to its end.
        var skipping = false
        var lines = 0
        reading: while true {
            if filled == buffer.count {
                if buffer.count >= longestLine {
                    offset += UInt64(filled)
                    filled = 0
                    skipping = true
                } else {
                    let larger = ReadPages.take(buffer.count * 2)
                    guard larger.count > 0 else { break }
                    larger.copyMemory(from: UnsafeRawBufferPointer(rebasing: buffer[0..<filled]))
                    ReadPages.release(buffer)
                    buffer = larger
                }
            }
            let count = pread(descriptor, buffer.baseAddress! + filled, buffer.count - filled, off_t(offset) + off_t(filled))
            guard count > 0 else { break }
            filled += count
            let bytes = UnsafeBufferPointer(start: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: filled)
            var start = 0
            while start < filled, let newline = memchr(bytes.baseAddress! + start, 0x0A, filled - start) {
                let end = UnsafeRawPointer(newline) - UnsafeRawPointer(bytes.baseAddress!)
                if skipping {
                    skipping = false
                } else {
                    add(UnsafeBufferPointer(rebasing: bytes[start..<end]), oldest: oldest)
                }
                start = end + 1
                lines += 1
                if lines % 2048 == 0, cancelled() { break reading }
            }
            if start > 0 {
                offset += UInt64(start)
                filled -= start
                if filled > 0 { memmove(buffer.baseAddress!, buffer.baseAddress! + start, filled) }
            }
            if cancelled() { break }
        }
        if buffer.count > chunk {
            ReadPages.release(buffer)
            buffer = ReadPages.take(chunk)
        }
        if cache.offsets[file.url.path] != offset {
            cache.offsets[file.url.path] = offset
            unsaved = true
        }
    }

    private func add(_ line: UnsafeBufferPointer<UInt8>, oldest: Date) {
        guard Self.contains(line, Self.marker) else { return }
        // Only a line with what a usage has in it counts against the format:
        // the text of a conversation can say "usage" too.
        guard let fields = TranscriptLine.scan(line), let id = fields.id, let date = AIUsageFormat.date(fields.timestamp),
              fields.input != nil || fields.output != nil, let tokens = fields.tokens else {
            if Self.contains(line, Self.tokensMarker) {
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
        guard tokens > 0, let model = fields.model else { return }
        let key = Self.hash(id + "/" + (fields.requestId ?? ""))
        let hour = cache.seen[key].map { Int($0.hour) } ?? TokenUsage.hour(date)
        let added = tokens - Int(cache.seen[key]?.tokens ?? 0)
        guard added > 0 else { return }
        cache.seen[key] = Seen(tokens: Int32(clamping: tokens), hour: Int32(clamping: hour))
        cache.hours[hour, default: [:]][model, default: 0] += added
        unsaved = true
    }

    private static func contains(_ line: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress, line.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, line.count, $0.baseAddress, needle.count) } != nil
    }

    private func prune(before oldest: Date) {
        let first = TokenUsage.hour(oldest)
        guard cache.hours.keys.contains(where: { $0 < first }) else { return }
        cache.hours = cache.hours.filter { $0.key >= first }
        cache.seen = cache.seen.filter { Int($0.value.hour) >= first }
        unsaved = true
    }

    /// Now and then rather than with each read, as it's a megabyte or so.
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

/// The fields of a transcript line that are counted, picked out of its bytes
/// by following the JSON's structure, so a key of the same name in what was
/// said or in a tool's input is never taken for them. Everything else is
/// stepped over without being decoded.
enum TranscriptLine {
    struct Fields: Equatable {
        var timestamp: String?
        var requestId: String?
        var id: String?
        var model: String?
        var input: Int?
        var output: Int?
        var cacheCreation: Int?

        /// Nil for figures no response could have: added up unchecked, they'd trap.
        var tokens: Int? {
            let figures = [input, output, cacheCreation].map { $0 ?? 0 }
            return figures.allSatisfy({ (0...Int(Int32.max)).contains($0) }) ? figures.reduce(0, +) : nil
        }
    }

    /// Nil for a line that isn't a JSON object, or has a counted field of
    /// another type than it should: a format that's changed.
    static func scan(_ line: UnsafeBufferPointer<UInt8>) -> Fields? {
        var scanner = Scanner(bytes: line)
        var fields = Fields()
        var valid = true
        let parsed = scanner.object { scanner, key in
            if scanner.equals(key, "timestamp") { fields.timestamp = scanner.text(); return fields.timestamp != nil }
            if scanner.equals(key, "requestId") { fields.requestId = scanner.text(); return fields.requestId != nil }
            guard scanner.equals(key, "message"), scanner.peek() == UInt8(ascii: "{") else { return false }
            return scanner.object { scanner, key in
                if scanner.equals(key, "id") { fields.id = scanner.text(); return fields.id != nil }
                if scanner.equals(key, "model") { fields.model = scanner.text(); return fields.model != nil }
                guard scanner.equals(key, "usage") else { return false }
                guard scanner.peek() == UInt8(ascii: "{") else { valid = false; return false }
                return scanner.object { scanner, key in
                    let figure: WritableKeyPath<Fields, Int?>
                    if scanner.equals(key, "input_tokens") { figure = \.input }
                    else if scanner.equals(key, "output_tokens") { figure = \.output }
                    else if scanner.equals(key, "cache_creation_input_tokens") { figure = \.cacheCreation }
                    else { return false }
                    guard let value = scanner.integer() else { valid = false; return false }
                    fields[keyPath: figure] = value
                    return true
                }
            }
        }
        return parsed && valid ? fields : nil
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")

        mutating func space() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0D { index += 1 }
        }

        func peek() -> UInt8? {
            var at = index
            while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x09 || bytes[at] == 0x0D { at += 1 }
            return at < bytes.count ? bytes[at] : nil
        }

        mutating func take(_ byte: Character) -> Bool {
            space()
            guard index < bytes.count, bytes[index] == byte.asciiValue! else { return false }
            index += 1
            return true
        }

        /// A string's bytes between its quotes, escapes left as they are.
        mutating func string() -> Range<Int>? {
            space()
            guard index < bytes.count, bytes[index] == Self.quote else { return nil }
            index += 1
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case Self.backslash: index += 2
                case Self.quote:
                    defer { index += 1 }
                    return start..<index
                default: index += 1
                }
            }
            return nil
        }

        /// A string as text; nil for another kind of value, or one with escapes,
        /// which no ID, model or time has.
        /// Left where it was when it says nil, for the value to be stepped over.
        mutating func text() -> String? {
            let start = index
            guard peek() == Self.quote, let range = string() else { index = start; return nil }
            let slice = UnsafeBufferPointer(rebasing: bytes[range])
            guard !slice.contains(Self.backslash) else { index = start; return nil }
            return String(decoding: slice, as: UTF8.self)
        }

        func equals(_ range: Range<Int>, _ key: StaticString) -> Bool {
            guard range.count == key.utf8CodeUnitCount else { return false }
            return memcmp(bytes.baseAddress! + range.lowerBound, key.utf8Start, range.count) == 0
        }

        /// A whole number that fits; nil for anything else, a fraction included.
        mutating func integer() -> Int? {
            space()
            var negative = false
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { negative = true; index += 1 }
            var value = 0
            var digits = 0
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                let (times, overflow) = value.multipliedReportingOverflow(by: 10)
                let (sum, overflowAgain) = times.addingReportingOverflow(Int(bytes[index] - UInt8(ascii: "0")))
                guard !overflow, !overflowAgain else { return nil }
                value = sum
                digits += 1
                index += 1
            }
            guard digits > 0 else { return nil }
            if index < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) { return nil }
            return negative ? -value : value
        }

        /// Steps over one value of any kind.
        mutating func skip() -> Bool {
            space()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case Self.quote: return string() != nil
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case Self.quote:
                        guard string() != nil else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { index += 1; return true }
                    default: break
                    }
                    index += 1
                }
                return false
            default:
                let start = index
                while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[index]) { index += 1 }
                return index > start
            }
        }

        /// Each key of the object here, with the scanner at its value: `visit`
        /// reads the value and says true, or says false to have it stepped over.
        mutating func object(_ visit: (inout Scanner, Range<Int>) -> Bool) -> Bool {
            guard take("{") else { return false }
            if take("}") { return true }
            repeat {
                guard let key = string(), take(":") else { return false }
                if !visit(&self, key) { guard skip() else { return false } }
            } while take(",")
            return take("}")
        }
    }
}
