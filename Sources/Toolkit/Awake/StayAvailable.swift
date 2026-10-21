import AppKit
import CoreGraphics

/// Keeps chat apps from marking you away. Slack, Teams and the like go by
/// how long it's been since the last input, so after a quiet spell this
/// posts one: a mouse move to where the pointer already is, or a short
/// drift to a spot nearby. Only once the whole interval has gone by without
/// real input, so it never acts while you're there. Needs Accessibility,
/// without which macOS drops posted events.
final class StayAvailable {
    private var method = StayAvailableMethod.signal
    private var every: TimeInterval = 120
    private var timer: Timer?
    private var drift: Timer?

    var running: Bool { timer != nil }

    func start(method: StayAvailableMethod, every: TimeInterval) {
        self.method = method
        self.every = max(30, every)
        schedule(after: max(1, self.every - Self.idle()))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        drift?.invalidate()
        drift = nil
    }

    /// Since the last input of any kind, posted ones included: what chat apps read.
    private static func idle() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Since the last key, click or scroll, which posted moves don't touch.
    private static func sinceHands() -> TimeInterval {
        [CGEventType.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }

    /// Woken only when something could be due: one timer for the rest of the
    /// interval, not a poll.
    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.check() }
        timer.tolerance = min(5, delay / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        let idle = Self.idle()
        guard idle >= every - 1 else { return schedule(after: every - idle) }
        if AXIsProcessTrusted(), !Self.buttonHeld(), !Self.screenOff() {
            switch method {
            case .signal: Self.post(to: Self.pointer())
            case .mouseMove: startDrift()
            }
        }
        schedule(after: every)
    }

    /// A posted move wakes a display that's asleep, and one put to sleep by hand
    /// (or by closing the lid) should stay so; a locked Mac shows as away anyway.
    private static func screenOff() -> Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    private static func buttonHeld() -> Bool {
        [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
    }

    /// Where the pointer is, in the top-left-origin coordinates events use.
    static func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func post(to point: CGPoint, from: CGPoint? = nil) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        if let from {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - from.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - from.y).rounded()))
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse move

    /// To a spot 80 to 200 points away on the same display, kept clear of its
    /// edges, the menu bar and the Dock: a hot corner could lock the screen,
    /// and the Dock or a menu could open on hover.
    static func target(from start: CGPoint) -> CGPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        let flip = { (p: CGPoint) in CGPoint(x: p.x, y: primary.frame.maxY - p.y) }
        let cocoa = flip(start)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cocoa, $0.frame, false) }) else { return nil }
        let safe = screen.visibleFrame.insetBy(dx: 60, dy: 60)
        guard safe.width > 0, safe.height > 0 else { return nil }
        for _ in 0..<12 {
            let angle = Double.random(in: 0..<(2 * .pi)), distance = Double.random(in: 80...200)
            let point = CGPoint(x: cocoa.x + cos(angle) * distance, y: cocoa.y + sin(angle) * distance)
            if safe.contains(point) { return flip(point) }
        }
        // Near an edge already: into the safe part, if that's close.
        let inside = CGPoint(x: min(max(cocoa.x, safe.minX), safe.maxX), y: min(max(cocoa.y, safe.minY), safe.maxY))
        return hypot(inside.x - cocoa.x, inside.y - cocoa.y) <= 300 ? flip(inside) : nil
    }

    /// Under a second, eased, at 60 steps a second. Any real input on the way
    /// stops it where it is: the pointer is yours again.
    func startDrift() {
        let start = Self.pointer()
        guard drift == nil, let end = Self.target(from: start) else { return }
        let began = Date(), duration = 0.8
        var last = start
        let drift = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let elapsed = Date().timeIntervalSince(began)
            let now = Self.pointer()
            // Moved by hand, or a key, click or scroll since it began. Off the
            // path by more than a step, as the pointer may lag a step behind.
            if hypot(now.x - last.x, now.y - last.y) > 16 || Self.sinceHands() < elapsed || Self.buttonHeld() {
                timer.invalidate()
                self?.drift = nil
                return
            }
            let t = min(1, elapsed / duration)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let point = CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
            Self.post(to: point, from: last)
            last = point
            if t >= 1 {
                timer.invalidate()
                self?.drift = nil
            }
        }
        RunLoop.main.add(drift, forMode: .common)
        self.drift = drift
    }
}
