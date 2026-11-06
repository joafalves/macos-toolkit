import CoreServices
import Foundation

/// Reads the sources off the main thread: at the start, when something in
/// their folders changes (at most every ten seconds, while an agent writes
/// constantly; what's read then is only what's new), and every ten minutes
/// for a folder that has only just appeared. Hands over what's read only
/// when it has changed.
final class AIUsageReader {
    private static let latency: CFTimeInterval = 10
    private static let rereadEvery = 600

    /// One for every reader: a new one starts after the last has finished with
    /// the saved figures, so they have one owner at a time.
    private static let sharedQueue = DispatchQueue(label: "dev.jalves.macos-toolkit.ai-usage", qos: .utility)
    private var queue: DispatchQueue { Self.sharedQueue }
    private let sources: [AIUsageSource]
    private let deliver: ([ProviderUsage]) -> Void
    private let stopped = Locked(false)
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var last: [ProviderUsage]?

    init(sources: [AIUsageSource], deliver: @escaping ([ProviderUsage]) -> Void) {
        self.sources = sources
        self.deliver = deliver
    }

    func start() {
        queue.async { [self] in
            // Watching first: what changes during a long first read is read after it.
            watch()
            read()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(Self.rereadEvery), repeating: .seconds(Self.rereadEvery), leeway: .seconds(60))
            timer.setEventHandler { [unowned self] in read() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Doesn't wait for a read under way, which gives up soon after. The queue
    /// holds on to the reader until it has let go of the stream, which calls
    /// back with an unretained pointer to it.
    func stop(afterwards: (() -> Void)? = nil) {
        stopped.value = true
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            afterwards?()
        }
    }

    private func read() {
        guard !stopped.value else { return }
        let usage = sources.map { $0.read(cancelled: { self.stopped.value }) }
        guard !stopped.value, usage != last else { return }
        last = usage
        let deliver = deliver
        DispatchQueue.main.async { deliver(usage) }
    }

    private func watch() {
        guard !stopped.value else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AIUsageReader>.fromOpaque(info).takeUnretainedValue().read()
        }
        let roots = sources.flatMap(\.roots).map(\.path)
        guard !roots.isEmpty else { return }
        let paths = roots as CFArray
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            Log.aiUsage.error("Couldn't watch the usage folders")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
