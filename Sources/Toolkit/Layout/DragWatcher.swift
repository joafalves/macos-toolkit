import AppKit

/// Notices when a window is being dragged by the mouse, on a thread of its
/// own. It only listens unless the edge hold is on, and it costs nothing
/// while the mouse is still: the window under the pointer is looked up once a
/// drag starts, and its position checked a few times until it moves, is
/// resized, or the drag ends. What it notices is handed to the main thread.
final class DragWatcher {
    struct Grab {
        let id: CGWindowID
        let pid: pid_t
        /// Where it was when the drag was noticed, in Core Graphics coordinates.
        let frame: CGRect
        /// Where the pointer was at that same moment, so it can be kept at the
        /// same place on the window.
        var pointer: CGPoint?
        /// Where it was when it was pressed on, before it moved at all.
        var start: CGRect?
    }

    // Called on the main thread.
    /// A window started moving with the mouse.
    var onStart: ((Grab) -> Void)?
    /// The pointer moved or a modifier changed while it moves. Core Graphics coordinates.
    var onMove: ((CGPoint, CGEventFlags) -> Void)?
    /// The mouse was let go: where, and with which modifiers.
    var onDrop: ((CGPoint, CGEventFlags) -> Void)?
    /// The drag was lost track of.
    var onCancel: (() -> Void)?

    /// The displays to hold the pointer at the edges of while a window
    /// moves, or nil not to. Set by the main thread; only an `active`
    /// watcher acts on it.
    let holdDisplays = Locked<[LayoutDisplay]?>(nil)

    // The rest belongs to the tap's thread.
    private var hold = EdgeHold()
    /// macOS has been told to stop moving the cursor. Never left so: every
    /// click, release, restart and quiet second puts it back.
    private var frozen = false
    private var heldAt: CGPoint?
    private var thaw: Timer?

    private enum State {
        case idle
        case pressed(CGPoint)
        case watching(Grab, lastCheck: TimeInterval)
        case moving
        /// A drag that isn't a window being moved: text being selected, a resize.
        case ignored
    }

    private var state = State.idle
    private var tap: EventTap?

    var isRunning: Bool { tap != nil }
    /// In the path of the events rather than beside it, so it can hold the
    /// pointer back. Only while that setting is on.
    private(set) var active = false

    func start(active: Bool) -> Bool {
        if tap != nil, active == self.active { return true }
        stop()
        self.active = active
        tap = EventTap(name: "drags", events: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged],
                       place: .tailAppendEventTap, listenOnly: !active) { [weak self] type, event in
            self?.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        return tap != nil
    }

    func stop() {
        guard let tap else { return }
        self.tap = nil
        // Finished on the tap's own thread, in order with its events.
        tap.perform { [self] in
            releaseCursor()
            if case .moving = state { main { $0.onCancel?() } }
            state = .idle
            tap.stop()
        }
        // In case the thread is gone before it gets there.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Lets the cursor move again, if it was stopped. For Esc.
    func release() {
        tap?.perform { [weak self] in self?.releaseCursor() }
    }

    private func main(_ work: @escaping (DragWatcher) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { work(self) } }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            releaseCursor()
            if case .moving = state { main { $0.onCancel?() } }
            state = .idle
        case .leftMouseDown:
            releaseCursor()
            hold = EdgeHold()
            state = .pressed(event.location)
        case .leftMouseDragged:
            dragged(event)
        case .leftMouseUp:
            releaseCursor()
            LayoutTrace.log("watcher: up at \(event.location), \(state)")
            if case .moving = state {
                let (location, flags) = (event.location, event.flags)
                main { $0.onDrop?(location, flags) }
            }
            state = .idle
        case .flagsChanged:
            if case .moving = state, let location = CGEvent(source: nil)?.location {
                let flags = event.flags
                main { $0.onMove?(location, flags) }
            }
        default:
            break
        }
    }

    private func dragged(_ event: CGEvent) {
        switch state {
        case .pressed(let point):
            guard let grab = Self.window(at: point) else {
                LayoutTrace.log("watcher: no ordinary window under \(point), ignored")
                state = .ignored
                return
            }
            LayoutTrace.log("watcher: pressed on window \(grab.id) pid \(grab.pid) \(LayoutTrace.text(grab.frame))")
            state = .watching(grab, lastCheck: ProcessInfo.processInfo.systemUptime)
        case .watching(let grab, let lastCheck):
            // A window server lookup per check: a few a second is plenty to
            // see the window move.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastCheck >= 0.03 else { return }
            guard let frame = Self.bounds(of: grab.id) else {
                LayoutTrace.log("watcher: window \(grab.id) gone, ignored")
                state = .ignored
                return
            }
            if Self.resizing(grab.frame, to: frame) {
                LayoutTrace.log("watcher: resizing? \(LayoutTrace.text(grab.frame)) → \(LayoutTrace.text(frame))")
                // Watched on: a resize looks like one until it ends.
                state = .watching(grab, lastCheck: now)
            } else if abs(frame.minX - grab.frame.minX) > 2 || abs(frame.minY - grab.frame.minY) > 2
                        || !LayoutWindow.close(frame.size, grab.frame.size) {
                state = .moving
                LayoutTrace.log("watcher: moving, \(LayoutTrace.text(grab.frame)) → \(LayoutTrace.text(frame))")
                let moved = Grab(id: grab.id, pid: grab.pid, frame: frame, pointer: event.location, start: grab.frame)
                let (location, flags) = (event.location, event.flags)
                main {
                    $0.onStart?(moved)
                    $0.onMove?(location, flags)
                }
            } else {
                state = .watching(grab, lastCheck: now)
            }
        case .moving:
            var location = event.location
            if active, let displays = holdDisplays.value {
                let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
                switch hold.step(location, delta: delta, in: displays) {
                case .free:
                    break
                case .hold(let point):
                    // Only put there when it isn't already: a held cursor is left alone.
                    if !frozen || point != heldAt { place(point) }
                    heldAt = point
                    freeze()
                    event.location = point
                    location = point
                case .release(let point):
                    if let point {
                        place(point)
                        event.location = point
                        location = point
                    }
                    releaseCursor()
                }
            } else {
                releaseCursor()
            }
            let flags = event.flags
            main { $0.onMove?(location, flags) }
        case .idle, .ignored:
            break
        }
    }

    /// Moves the cursor without the pause a warp usually brings.
    private func place(_ point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        frozen = false
    }

    private func freeze() {
        if !frozen {
            CGAssociateMouseAndMouseCursorPosition(0)
            frozen = true
        }
        // A drag whose end was missed must not leave the cursor stopped.
        thaw?.invalidate()
        let thaw = Timer(timeInterval: 1, repeats: false) { [weak self] _ in self?.releaseCursor() }
        RunLoop.current.add(thaw, forMode: .common)
        self.thaw = thaw
    }

    private func releaseCursor() {
        thaw?.invalidate()
        thaw = nil
        heldAt = nil
        guard frozen else { return }
        frozen = false
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The window under the point, if it's an ordinary one: the top one at
    /// the normal level, with no menu or panel above it there.
    static func window(at point: CGPoint) -> Grab? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let displays = activeDisplayBounds()
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            // Above the windows there are overlays that take no clicks: the
            // Dock keeps one over its whole display, and the window server
            // has its own. Those are looked through.
            if layer != 0, info[kCGWindowOwnerName as String] as? String == "Window Server"
                || displays.contains(where: { rect.contains($0) }) { continue }
            // Otherwise the first one under the point is on top; anything but
            // a normal window there (a menu, a palette) means this isn't a window drag.
            guard layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else {
                LayoutTrace.log("watcher: on top at \(point): \(info[kCGWindowOwnerName as String] ?? "?") pid \(info[kCGWindowOwnerPID as String] ?? "?"), layer \(layer), \(LayoutTrace.text(rect)), alpha \(info[kCGWindowAlpha as String] ?? "?"), name \(info[kCGWindowName as String] ?? "")")
                return nil
            }
            return Grab(id: id, pid: pid, frame: rect)
        }
        return nil
    }

    /// Whether a window that changed size is being resized: something stays
    /// put across and down, the edge opposite the one pulled (or the middle,
    /// with ⌥). A window macOS tiled also changes size as a drag starts, as
    /// macOS gives it back the size it had, over a few frames, but it follows
    /// the pointer, so across or down nothing stays.
    static func resizing(_ from: CGRect, to frame: CGRect) -> Bool {
        guard !LayoutWindow.close(frame.size, from.size) else { return false }
        func held(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { zip(a, b).contains { abs($0 - $1) <= 2 } }
        return held([from.minX, from.maxX, from.midX], [frame.minX, frame.maxX, frame.midX])
            && held([from.minY, from.maxY, from.midY], [frame.minY, frame.maxY, frame.midY])
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    static func bounds(of id: CGWindowID) -> CGRect? {
        // The array holds the IDs themselves, not objects.
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        guard let ids = CFArrayCreate(nil, &value, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
}

/// Holds the pointer at an edge between two displays while a window is
/// dragged, so the snap there is easy to hit. The cursor is stopped right at
/// the edge (macOS is told to stop moving it) while the mouse keeps saying
/// how it moves: into the other display is push, and enough of it, for long
/// enough, crosses over. Moving away, or mostly along the edge, lets go and
/// the cursor moves as usual. While held it is never moved, since a cursor
/// moved by the app shows up in the next event's movement and would feed
/// back into itself.
struct EdgeHold {
    /// How far to push, each event counting for a little at most, and for
    /// how long, so a fast flick doesn't get through.
    static let push: CGFloat = 80
    static let time: TimeInterval = 0.2
    static let perEvent: CGFloat = 12
    /// How close to the edge, moving towards it, the cursor is caught.
    static let approach: CGFloat = 3

    enum Step: Equatable {
        /// Nothing to do.
        case free
        /// The cursor stays stopped, here.
        case hold(CGPoint)
        /// Let go: the cursor moves again, from here if given.
        case release(CGPoint?)
    }

    private enum Side { case left, right, top, bottom }

    private var home: CGDirectDisplayID?
    private var held: (side: Side, point: CGPoint)?
    private var pushed: CGFloat = 0
    private var since: TimeInterval?
    /// The event after the cursor was put at the edge carries that move.
    private var settling = false
    /// Pushed through once: the rest of this drag goes freely, both ways.
    private(set) var spent = false

    var isHolding: Bool { held != nil }

    /// `point` is the event's location, `delta` how far the mouse moved for it.
    mutating func step(_ point: CGPoint, delta: CGVector, in displays: [LayoutDisplay],
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Step {
        guard !spent else { return .free }
        guard let homeID = home, let home = displays.first(where: { $0.id == homeID }) else {
            self.home = LayoutGeometry.display(at: point, in: displays)?.id
            return .free
        }
        let f = home.frame
        if let current = held {
            if settling {
                settling = false
                return .hold(current.point)
            }
            let (into, along): (CGFloat, CGFloat)
            switch current.side {
            case .left: (into, along) = (-delta.dx, delta.dy)
            case .right: (into, along) = (delta.dx, delta.dy)
            case .top: (into, along) = (-delta.dy, delta.dx)
            case .bottom: (into, along) = (delta.dy, delta.dx)
            }
            if into < -0.5 || abs(along) > max(2, into) {
                held = nil
                return .release(nil)
            }
            let start = since ?? now
            since = start
            pushed += min(max(into, 0), Self.perEvent)
            if pushed >= Self.push, now - start >= Self.time {
                let across = beyond(current.side, of: current.point, by: 2)
                held = nil
                spent = true
                self.home = LayoutGeometry.display(at: across, in: displays)?.id ?? homeID
                return .release(across)
            }
            return .hold(current.point)
        }
        // Caught on the way: close to a shared edge and moving towards it, or
        // already past it in one jump.
        let sides: [(Side, Bool)] = [
            (.left, point.x - f.minX <= Self.approach && delta.dx < 0 || point.x < f.minX),
            (.right, f.maxX - 1 - point.x <= Self.approach && delta.dx > 0 || point.x > f.maxX - 1),
            (.top, point.y - f.minY <= Self.approach && delta.dy < 0 || point.y < f.minY),
            (.bottom, f.maxY - 1 - point.y <= Self.approach && delta.dy > 0 || point.y > f.maxY - 1),
        ]
        for (side, near) in sides where near {
            let edge = onEdge(side, clamp(point, to: f), of: f)
            guard shared(side, at: edge, of: f, in: displays) else { continue }
            // Caught again straight after letting go (a push with some slide in
            // it): the push carries on from where it was.
            held = (side, edge)
            settling = true
            return .hold(edge)
        }
        // A pause in the push, out on its own: the next push starts afresh.
        pushed = 0
        since = nil
        // On another display without passing an edge we know of: that's home now.
        if !f.contains(point) { self.home = LayoutGeometry.display(at: point, in: displays)?.id ?? homeID }
        return .free
    }

    private func clamp(_ p: CGPoint, to f: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, f.minX), f.maxX - 1), y: min(max(p.y, f.minY), f.maxY - 1))
    }

    private func onEdge(_ side: Side, _ p: CGPoint, of f: CGRect) -> CGPoint {
        switch side {
        case .left: return CGPoint(x: f.minX, y: p.y)
        case .right: return CGPoint(x: f.maxX - 1, y: p.y)
        case .top: return CGPoint(x: p.x, y: f.minY)
        case .bottom: return CGPoint(x: p.x, y: f.maxY - 1)
        }
    }

    private func beyond(_ side: Side, of p: CGPoint, by d: CGFloat) -> CGPoint {
        switch side {
        case .left: return CGPoint(x: p.x - d, y: p.y)
        case .right: return CGPoint(x: p.x + d, y: p.y)
        case .top: return CGPoint(x: p.x, y: p.y - d)
        case .bottom: return CGPoint(x: p.x, y: p.y + d)
        }
    }

    /// Whether another display is right across this point of the edge.
    private func shared(_ side: Side, at p: CGPoint, of f: CGRect, in displays: [LayoutDisplay]) -> Bool {
        let across = beyond(side, of: p, by: 2)
        return displays.contains { $0.frame.contains(across) && !$0.frame.equalTo(f) }
    }
}
