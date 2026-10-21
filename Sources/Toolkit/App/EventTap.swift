import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// An event tap on a thread of its own. A tap in the path of the events holds
/// up every key or click it sees until its callback returns, so on the main
/// thread anything slow there (drawing, a slow app over Accessibility) held
/// up typing and scrolling everywhere. Here the callback only ever waits for
/// itself; it must not touch main-thread state, and hands anything else to
/// the main queue.
///
/// macOS turns a tap off when it's too slow, or while the user is entering a
/// password; it is turned back on, and the handler still gets that event so
/// it can drop whatever it was in the middle of.
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private let handler: Handler
    private var port: CFMachPort?
    private var thread: Thread?
    /// The tap thread's run loop, for timers that belong with the tap.
    private(set) var runLoop: CFRunLoop?

    /// Nil when macOS refuses the tap, which it does without Accessibility.
    init?(name: String, events: [CGEventType], place: CGEventTapPlacement = .headInsertEventTap,
          listenOnly: Bool = false, handler: @escaping Handler) {
        self.handler = handler
        let mask = events.reduce(CGEventMask(0)) { $0 | 1 << CGEventMask($1.rawValue) }
        // Retained by the tap's thread, which outlives every callback.
        let box = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: place, options: listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            },
            userInfo: box
        ) else { return nil }
        self.port = port
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            // Not left behind: it would call back into a tap that's gone.
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            return nil
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            self.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            // Until stop(): the source keeps the loop from returning at once.
            CFRunLoopRun()
        }
        thread.name = "dev.jalves.macos-toolkit.\(name)"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return handler(type, event)
    }

    /// Runs `work` on the tap's thread, in order with the events.
    func perform(_ work: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// Takes the tap out and ends its thread.
    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        self.port = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
        thread = nil
    }

    deinit { stop() }
}

/// The app in front, for taps: NSWorkspace is the main thread's, so it keeps
/// this current there and taps read it from theirs.
enum FrontApp {
    private static let current = Locked<(id: String?, pid: pid_t)?>(nil)
    private static var observer: NSObjectProtocol?

    /// On the main thread, before any tap that reads it.
    static func start() {
        guard observer == nil else { return }
        let read = { (app: NSRunningApplication?) in current.value = app.map { ($0.bundleIdentifier, $0.processIdentifier) } }
        read(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            read(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    static var bundleID: String? { current.value?.id }
    static var pid: pid_t? { current.value?.pid }
}

/// A value the main thread sets and a tap's thread reads, or the other way round.
final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    /// Changes it in one go, for read-then-write.
    @discardableResult
    func update<T>(_ change: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return change(&stored)
    }
}

extension EventTap {
    /// `--test-taps`: a tap keeps up while the main thread is stuck. It posts
    /// scroll events of zero distance (harmless wherever they land) while
    /// the main thread sleeps, and reports how soon the tap saw them.
    static func selfTest() {
        guard AXIsProcessTrusted() else { return print("Accessibility is not granted to the process running this.") }
        let marker: Int64 = 0x5445_5354  // "TEST"
        let seen = Locked<[(TimeInterval, Bool)]>([])
        guard let tap = EventTap(name: "test", events: [.scrollWheel], handler: { _, event in
            if event.getIntegerValueField(.eventSourceUserData) == marker {
                seen.update { $0.append((ProcessInfo.processInfo.systemUptime, Thread.isMainThread)) }
            }
            return Unmanaged.passUnretained(event)
        }) else { return print("the tap could not be made") }
        var posted: [TimeInterval] = []
        let lock = NSLock()
        DispatchQueue.global().async {
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.2)
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else { continue }
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                lock.lock(); posted.append(ProcessInfo.processInfo.systemUptime); lock.unlock()
                event.post(tap: .cgSessionEventTap)
            }
        }
        // The main thread stuck, as on a slow draw or a hung app.
        Thread.sleep(forTimeInterval: 1.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        tap.stop()
        let got = seen.value
        lock.lock(); let sent = posted; lock.unlock()
        let delays = zip(sent, got.map(\.0)).map { ($1 - $0) * 1000 }
        print("posted \(sent.count), seen \(got.count), on the main thread: \(got.contains { $0.1 })")
        print("delays: " + delays.map { String(format: "%.1f ms", $0) }.joined(separator: ", "))
        let ok = got.count == sent.count && !got.contains { $0.1 } && (delays.max() ?? .infinity) < 100
        print(ok ? "ok: the tap kept up while the main thread was stuck" : "FAIL")
    }
}
