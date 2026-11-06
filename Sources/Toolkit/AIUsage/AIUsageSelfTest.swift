#if TOOLKIT_DEV
import Foundation

enum AIUsageSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok    " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    /// `--test-ai-usage`: the sources on made-up files in a scratch folder,
    /// never the real ones.
    static func run() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        limits()
        warnings()
        tokens()
        formats()
        codex(in: folder.appendingPathComponent("codex"))
        claude(in: folder.appendingPathComponent("claude"), cache: folder.appendingPathComponent("cache.plist"))
        scanner()
        print(failures == 0 ? "all ok" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--list-ai-usage`: what's read from this Mac's own files, and what the
    /// first read costs, leaving the app's saved figures alone. Figures only.
    static func list() {
        func memory() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return Double(info.phys_footprint) / 1_048_576
        }
        let now = Date()
        for source in [ClaudeTranscripts(cacheURL: nil), CodexSource()] as [AIUsageSource] {
            let (start, before) = (Date(), memory())
            let usage = source.read(cancelled: { false })
            let first = Date().timeIntervalSince(start)
            let again = Date()
            _ = source.read(cancelled: { false })
            print(String(format: "%@: %@, first read %.2f s, next %.1f ms, memory %.0f to %.0f MB", usage.provider.title, String(describing: usage.state), first,
                         Date().timeIntervalSince(again) * 1000, before, memory()))
            if let plan = usage.plan { print("  plan \(plan)") }
            for limit in usage.limits {
                print("  \(limit.title): \(Int((limit.leftShare(at: now) ?? 0) * 100))% left, running \(limit.isRunning(at: now)), over pace \(limit.isOverPace(at: now))")
            }
            if let tokens = usage.tokens {
                print("  5 hours \(AIUsageFormat.tokens(tokens.total(from: now.addingTimeInterval(-5 * 3600), to: now))), 7 days \(AIUsageFormat.tokens(tokens.total(from: now.addingTimeInterval(-7 * 86400), to: now)))")
                for (model, count) in tokens.byModel(from: now.addingTimeInterval(-30 * 86400), to: now).sorted(by: { $0.value > $1.value }) {
                    print("  \(AIUsageFormat.modelName(model)): \(AIUsageFormat.tokens(count))")
                }
            }
        }
        exit(0)
    }

    /// `--measure-ai-usage [seconds]`: the reader on this Mac's own files, with
    /// no saved figures: how long until the first figures, what it costs after
    /// them while nothing's asked of it, and that stopping lets go of everything.
    static func measure(seconds: Double) {
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        var delivered = 0
        let start = Date()
        var reader: AIUsageReader? = AIUsageReader(sources: [ClaudeTranscripts(cacheURL: nil), CodexSource()]) { _ in delivered += 1 }
        reader?.start()
        while delivered == 0, Date().timeIntervalSince(start) < 120 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        check(delivered > 0, String(format: "first figures after %.1f s", Date().timeIntervalSince(start)))
        let before = cpu()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print(String(format: "      left alone for %.0f s: %.2f%% of a core, %d more deliveries", seconds, (cpu() - before) / seconds * 100, delivered - 1))
        weak var gone = reader
        reader?.stop()
        reader = nil
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        check(gone == nil, "stopped, the reader is let go of")

        // A file changed in a watched folder is read, within the latency and a little.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        write(usageLine(id: "w1", output: 5, input: 0, at: Date()), to: folder.appendingPathComponent("a.jsonl"))
        var latest = 0
        let watching = AIUsageReader(sources: [ClaudeTranscripts(root: folder, cacheURL: nil)]) { usage in
            latest = usage.first?.tokens?.total(from: Date().addingTimeInterval(-3600), to: Date()) ?? 0
        }
        watching.start()
        func wait(for figure: Int, _ limit: TimeInterval) {
            let start = Date()
            while latest != figure, Date().timeIntervalSince(start) < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        }
        wait(for: 5, 5)
        write(usageLine(id: "w1", output: 5, input: 0, at: Date()) + usageLine(id: "w2", output: 7, input: 0, at: Date()), to: folder.appendingPathComponent("a.jsonl"))
        let written = Date()
        wait(for: 12, 60)
        check(latest == 12, String(format: "a change in the folder is read, after %.0f s", Date().timeIntervalSince(written)))
        watching.stop()
        exit(failures == 0 ? 0 : 1)
    }

    private static func limits() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func limit(used: Double, resetsIn: TimeInterval) -> UsageLimit {
            UsageLimit(provider: .codex, windowMinutes: 300, usedShare: used, resetsAt: now.addingTimeInterval(resetsIn), readAt: now)
        }
        check(limit(used: 0.3, resetsIn: 3600).leftShare(at: now) == 0.7, "what's left of a running window")
        check(limit(used: 0.9, resetsIn: -1).leftShare(at: now) == nil, "what's left of a window that has ended isn't known")
        check(!limit(used: 0.9, resetsIn: -1).isOverPace(at: now), "a window that has ended isn't over pace")
        check(limit(used: 0.5, resetsIn: 3 * 3600).isOverPace(at: now), "half used, two fifths through: over pace")
        check(!limit(used: 0.3, resetsIn: 3 * 3600).isOverPace(at: now), "under a third used, two fifths through: fine")
        check(!limit(used: 0.05, resetsIn: 299 * 60).isOverPace(at: now), "a little use at the start isn't a sprint")
        check(limit(used: 1, resetsIn: 299 * 60).isOverPace(at: now), "all used is over pace, whenever")
        let controller = AIUsageController.preview()
        let at = controller.live.now
        func reading(age: TimeInterval) -> [ProviderUsage] {
            [ProviderUsage(provider: .codex, state: .read, limits: [UsageLimit(provider: .codex, windowMinutes: 10080, usedShare: 0.3, resetsAt: at.addingTimeInterval(86400), readAt: at.addingTimeInterval(-age))])]
        }
        controller.live.usage = reading(age: 60)
        check(controller.tightestLimit(at: at) != nil, "a reading from a minute ago takes the pill")
        controller.live.usage = reading(age: 2 * 86400)
        check(controller.tightestLimit(at: at) == nil, "one from days ago doesn't, as it would pass for now")
    }

    private static func warnings() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func usage(used: Double, resetsIn: TimeInterval) -> [ProviderUsage] {
            [ProviderUsage(provider: .codex, state: .read, limits: [UsageLimit(provider: .codex, windowMinutes: 300, usedShare: used, resetsAt: now.addingTimeInterval(resetsIn), readAt: now)])]
        }
        let warn = AIUsageController.toWarn
        check(warn(usage(used: 0.79, resetsIn: 3600), [:], now).isEmpty, "warnings: under the mark, none")
        check(warn(usage(used: 0.8, resetsIn: 3600), [:], now).count == 1, "warnings: at the mark, one")
        check(warn(usage(used: 0.9, resetsIn: -60), [:], now).isEmpty, "warnings: a window that has ended, none")
        let resets = now.timeIntervalSince1970 + 3600
        check(warn(usage(used: 0.9, resetsIn: 3600), ["codex 300": resets + 20], now).isEmpty, "warnings: once for a window, as its reset time moves a little")
        check(warn(usage(used: 0.9, resetsIn: 3600), ["codex 300": resets - 18000], now).count == 1, "warnings: again in the next window")
    }

    private static func tokens() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let hour = TokenUsage.hour(now)
        var usage = TokenUsage()
        for back in 0..<(31 * 24) { usage.hours[hour - back] = ["m": 1] }
        let month = usage.series(from: now.addingTimeInterval(-30 * 86400), to: now, step: 24)
        check(month.count == 30 && month.allSatisfy { $0 == 24 }, "tokens: thirty whole days, the last no less than the others")
        check(usage.total(from: now.addingTimeInterval(-5 * 3600), to: now) <= 5, "tokens: the last 5 hours count no more than 5 hours' worth")
    }

    private static func formats() {
        check(AIUsageFormat.tokens(840) == "840", "tokens: hundreds")
        check(AIUsageFormat.tokens(12_400) == "12K", "tokens: thousands")
        check(AIUsageFormat.tokens(999_700) == "1\(Locale.current.decimalSeparator ?? ".")0M", "tokens: rounding up to the next unit")
        check(AIUsageFormat.modelName("claude-opus-5-5") == "Opus 5.5", "model name")
        check(AIUsageFormat.modelName("claude-sonnet-4-20250514") == "Sonnet 4", "model name without its date")
        check(AIUsageFormat.modelName("<synthetic>") == "<synthetic>", "a name of another kind stays as it is")
    }

    private static func limitLine(used: Double = 26, minutes: Int? = 300, resets: Double = 2_000_000_000, type: String = "token_count") -> String {
        let window = minutes.map { "{\"used_percent\":\(used),\"window_minutes\":\($0),\"resets_at\":\(resets)}" } ?? "null"
        return "{\"timestamp\":\"2033-05-18T03:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"rate_limits\":{\"primary\":\(window),\"secondary\":null,\"plan_type\":\"plus\"}}}\n"
    }

    private static func write(_ text: String, to url: URL, date: Date? = nil) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        if let date { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    private static func codex(in root: URL) {
        check(CodexSource(root: root).read(cancelled: { false }).state == .notFound, "codex: no folder")
        let source = CodexSource(root: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        check(source.read(cancelled: { false }).state == .noData, "codex: an empty folder")

        let older = Date().addingTimeInterval(-60)
        write(limitLine(used: 10) + limitLine(used: 26), to: root.appendingPathComponent("2033/a.jsonl"), date: older)
        var usage = source.read(cancelled: { false })
        check(usage.state == .read && usage.limits.first?.usedShare == 0.26, "codex: the last line of a file counts")
        check(usage.plan == "Plus", "codex: the plan")
        check(usage.limits.first?.readAt == AIUsageFormat.date("2033-05-18T03:00:00.000Z"), "codex: read as of the line's time")

        // The newest file has no response yet, and the one before does.
        write("{\"type\":\"session_meta\"}\n", to: root.appendingPathComponent("2033/b.jsonl"), date: older.addingTimeInterval(1))
        usage = source.read(cancelled: { false })
        check(usage.limits.first?.usedShare == 0.26, "codex: a new session with no response yet doesn't hide the last limits")

        // Limits with no windows, for a plan's other models, as Codex also sends.
        write(limitLine(used: 40) + limitLine(minutes: nil), to: root.appendingPathComponent("2033/c.jsonl"), date: older.addingTimeInterval(2))
        usage = source.read(cancelled: { false })
        check(usage.limits.first?.usedShare == 0.4, "codex: limits with no windows are passed over")

        // A line cut off where it was being written, after a good one.
        write(limitLine(used: 55) + String(limitLine().prefix(60)), to: root.appendingPathComponent("2033/d.jsonl"), date: older.addingTimeInterval(3))
        usage = source.read(cancelled: { false })
        check(usage.limits.first?.usedShare == 0.55, "codex: a line cut off is passed over")

        // The session changed last isn't the one that reported last.
        let two = root.deletingLastPathComponent().appendingPathComponent("codex-two")
        func report(used: Double, at time: String) -> String { limitLine(used: used).replacingOccurrences(of: "2033-05-18T03:00:00.000Z", with: time) }
        write(report(used: 70, at: "2033-05-18T05:00:00.000Z"), to: two.appendingPathComponent("a.jsonl"), date: older)
        write(report(used: 20, at: "2033-05-18T04:00:00.000Z") + "{\"type\":\"tool_output\"}\n", to: two.appendingPathComponent("b.jsonl"), date: older.addingTimeInterval(1))
        let both = CodexSource(root: two)
        check(both.read(cancelled: { false }).limits.first?.usedShare == 0.7, "codex: the latest report counts, not the file changed last")
        // An older file gets a newer report, staying older than the newest file.
        write(report(used: 80, at: "2033-05-18T06:00:00.000Z"), to: two.appendingPathComponent("a.jsonl"), date: older.addingTimeInterval(0.5))
        check(both.read(cancelled: { false }).limits.first?.usedShare == 0.8, "codex: a new report in a file that isn't the newest is seen")

        // Another limit of the plan's, with windows of its own, after Codex's.
        let plan = root.deletingLastPathComponent().appendingPathComponent("codex-plan")
        write(limitLine(used: 33).replacingOccurrences(of: "\"rate_limits\":{", with: "\"rate_limits\":{\"limit_id\":\"codex\",")
              + limitLine(used: 90).replacingOccurrences(of: "\"rate_limits\":{", with: "\"rate_limits\":{\"limit_id\":\"premium\","), to: plan.appendingPathComponent("a.jsonl"))
        check(CodexSource(root: plan).read(cancelled: { false }).limits.first?.usedShare == 0.33, "codex: another limit of the plan's isn't taken for Codex's")

        // No limits to report, or a conversation quoting the word: not a new format.
        let none = root.deletingLastPathComponent().appendingPathComponent("codex-none")
        write("{\"timestamp\":\"2033-05-18T03:00:00.000Z\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n"
              + "{\"payload\":{\"type\":\"message\",\"text\":\"what are rate_limits?\"}}\n" + limitLine(minutes: nil), to: none.appendingPathComponent("a.jsonl"))
        check(CodexSource(root: none).read(cancelled: { false }).state == .noData, "codex: no limits, or the word in a conversation, isn't a new format")

        // A format of the future: lines with limits, none of them readable.
        let other = root.deletingLastPathComponent().appendingPathComponent("codex-new")
        write("{\"timestamp\":1,\"payload\":{\"type\":\"token_count\",\"rate_limits\":\"soon\"}}\n", to: other.appendingPathComponent("a.jsonl"))
        check(CodexSource(root: other).read(cancelled: { false }).state == .unreadable, "codex: a new format says so, rather than looking like no use")
    }

    private static func usageLine(id: String, output: Int, input: Int = 10, cacheRead: Int = 5000, model: String = "claude-opus-5-5", at date: Date) -> String {
        let time = ISO8601DateFormatter().string(from: date)
        return "{\"timestamp\":\"\(time)\",\"requestId\":\"r\(id)\",\"type\":\"assistant\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheRead)}}}\n"
    }

    private static func claude(in root: URL, cache: URL) {
        func read(_ source: ClaudeTranscripts) -> ProviderUsage { source.read(cancelled: { false }) }
        let now = Date()
        let day = now.addingTimeInterval(-86400)
        func total(_ usage: ProviderUsage) -> Int { usage.tokens?.total(from: now.addingTimeInterval(-40 * 86400), to: now) ?? -1 }

        check(read(ClaudeTranscripts(root: root, cacheURL: cache)).state == .notFound, "claude: no folder")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = ClaudeTranscripts(root: root, cacheURL: cache)
        check(read(source).state == .noData, "claude: an empty folder")

        let file = root.appendingPathComponent("project/a.jsonl")
        write(usageLine(id: "m1", output: 3, at: day) + usageLine(id: "m1", output: 90, at: day)
              + "{\"type\":\"user\",\"message\":{\"content\":\"what does usage mean?\"}}\n" + usageLine(id: "m2", output: 40, input: 0, model: "claude-haiku-5-5", at: now), to: file)
        var usage = read(source)
        check(usage.state == .read, "claude: read")
        check(total(usage) == 100 + 40, "claude: a response's lines count once, at its last figure, without cache reads")
        check(usage.tokens?.byModel(from: day.addingTimeInterval(-3600), to: day)["claude-opus-5-5"] == 100, "claude: by the hour and model")

        check(total(read(source)) == 140, "claude: nothing new, nothing added")

        func append(_ text: String) {
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        }
        // Half a line, as it's being written, then the rest of it.
        let line = usageLine(id: "m3", output: 7, input: 0, at: now)
        append(String(line.prefix(30)))
        check(total(read(source)) == 140, "claude: half a line waits")
        append(String(line.dropFirst(30)))
        check(total(read(source)) == 147, "claude: the rest of it counts, once")

        // The same response in a second file, as a resumed session copies it.
        write(usageLine(id: "m1", output: 90, at: day), to: root.appendingPathComponent("project/b.jsonl"))
        check(total(read(source)) == 147, "claude: a copy in another file doesn't count twice")

        // A long line, longer than a chunk, doesn't get lost.
        let long = "{\"type\":\"user\",\"text\":\"\(String(repeating: "x", count: 3 << 20))\"}\n"
        append(long + usageLine(id: "m4", output: 3, input: 0, at: now))
        check(total(read(source)) == 150, "claude: a line longer than a chunk")

        // Old lines are left out.
        append(usageLine(id: "m5", output: 1000, input: 0, at: now.addingTimeInterval(-60 * 86400)))
        check(total(read(source)) == 150, "claude: older than it keeps is left out")

        // A restart reads nothing again, from what was saved.
        let saving = ClaudeTranscripts(root: root, cacheURL: cache)
        check(total(read(saving)) == 150, "claude: read from nothing, the same figure")
        let restarted = ClaudeTranscripts(root: root, cacheURL: cache)
        let started = Date()
        check(total(read(restarted)) == 150, "claude: after a restart, the same figure")
        print(String(format: "      restart's read: %.1f ms", Date().timeIntervalSince(started) * 1000))

        // Told to stop on the way: gives up, and nothing's counted twice afterwards.
        let other = root.deletingLastPathComponent().appendingPathComponent("claude-stop")
        write(usageLine(id: "s1", output: 5, input: 0, at: now), to: other.appendingPathComponent("a.jsonl"))
        let stopping = ClaudeTranscripts(root: other, cacheURL: nil)
        check(stopping.read(cancelled: { true }).tokens == nil, "claude: stopped, it says nothing")
        check(total(read(stopping)) == 5, "claude: carried on, it's all there")

        // A format of the future: lines that look like usage, none readable.
        let future = root.deletingLastPathComponent().appendingPathComponent("claude-new")
        let odd = (0..<12).map { "{\"timestamp\":\(1000 + $0),\"usage\":{\"input_tokens\":\"many\"}}" }.joined(separator: "\n") + "\n"
        write(odd, to: future.appendingPathComponent("a.jsonl"))
        check(ClaudeTranscripts(root: future, cacheURL: nil).read(cancelled: { false }).state == .unreadable, "claude: a new format says so, rather than looking like no use")

        // Figures no response could have don't bring the app down.
        let huge = root.deletingLastPathComponent().appendingPathComponent("claude-huge")
        write(usageLine(id: "h1", output: Int.max, input: Int.max, at: now) + usageLine(id: "h2", output: -5, at: now) + usageLine(id: "h3", output: 9, input: 0, at: now), to: huge.appendingPathComponent("a.jsonl"))
        check(total(read(ClaudeTranscripts(root: huge, cacheURL: nil))) == 9, "claude: impossible figures are passed over")

        // The format changing while it runs, and a line of the old one later.
        let changing = root.deletingLastPathComponent().appendingPathComponent("claude-changing")
        let running = ClaudeTranscripts(root: changing, cacheURL: nil)
        write(usageLine(id: "c1", output: 5, input: 0, at: now), to: changing.appendingPathComponent("a.jsonl"))
        check(read(running).state == .read, "claude: read before the format changes")
        write(odd, to: changing.appendingPathComponent("b.jsonl"))
        check(read(running).state == .unreadable, "claude: a format that changes while it runs says so")
        write(usageLine(id: "c2", output: 5, input: 0, at: now), to: changing.appendingPathComponent("c.jsonl"))
        check(read(running).state == .read, "claude: back to read with a line it can read")
    }

    /// The transcript scanner against Foundation's decoder, on lines shaped
    /// as Claude Code writes them and on the ways a line can go wrong.
    private static func scanner() {
        func scan(_ text: String) -> TranscriptLine.Fields? {
            Array(text.utf8).withUnsafeBufferPointer { TranscriptLine.scan($0) }
        }
        let real = #"{"parentUuid":"p","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"model":"sonnet","id":"fake","usage":{"input_tokens":999},"prompt":"say \"hi\" {not json"}}],"stop_reason":null,"usage":{"input_tokens":12,"cache_creation_input_tokens":300,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_5m_input_tokens":300},"output_tokens":45,"service_tier":"standard"}},"requestId":"req_1","timestamp":"2033-05-18T03:00:00.000Z"}"#
        let fields = scan(real)
        check(fields == TranscriptLine.Fields(timestamp: "2033-05-18T03:00:00.000Z", requestId: "req_1", id: "msg_1", model: "claude-opus-5-5", input: 12, output: 45, cacheCreation: 300),
              "scanner: a response's own figures, not those in a tool's input")
        check(fields?.tokens == 357, "scanner: input, output and cache writes, without cache reads")
        check(scan(#"{"type":"user","message":{"role":"user","content":"what does \"usage\" mean?"}}"#).map { $0.id == nil && $0.output == nil } == true, "scanner: a question about usage has none")
        check(scan(#"{"message":{"id":"m","usage":{"input_tokens":"many"}}}"#) == nil, "scanner: a figure that isn't a number is a format it can't read")
        check(scan(#"{"message":{"id":"m","usage":{"input_tokens":1.5}}}"#) == nil, "scanner: nor is a fraction")
        check(scan(#"{"message":{"id":"m","usage":{"input_tokens":99999999999999999999}}}"#) == nil, "scanner: nor a figure too large to hold")
        check(scan(#"{"message":{"id":"m","usage""#) == nil, "scanner: half a line")
        check(scan(#"{"message":{"id":"m","usage":{"output_tokens":7}},"timestamp":"t"}"#)?.output == 7, "scanner: keys in any order")
        check(scan(#"{ "message" : { "id" : "m" , "usage" : { "output_tokens" : 7 } } }"#)?.output == 7, "scanner: spaces between the parts")

        // The same figures as decoding the line whole, the way it was done before.
        struct Line: Decodable {
            struct Message: Decodable {
                struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int?; let cache_creation_input_tokens: Int? }
                let id: String?; let model: String?; let usage: Usage?
            }
            let timestamp: String?; let requestId: String?; let message: Message?
        }
        let decoded = try? JSONDecoder().decode(Line.self, from: Data(real.utf8))
        check(decoded?.message?.id == fields?.id && decoded?.message?.model == fields?.model && decoded?.message?.usage?.output_tokens == fields?.output
              && decoded?.message?.usage?.input_tokens == fields?.input && decoded?.requestId == fields?.requestId, "scanner: what the decoder reads")
    }
}
#endif
