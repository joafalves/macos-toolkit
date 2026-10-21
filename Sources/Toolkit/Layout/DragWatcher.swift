import AppKit

/// Notices when a window is being dragged by the mouse. It only listens, so
/// it never holds up a click, and it costs nothing while the mouse is still:
/// the window under the pointer is looked up once a drag starts, and its
/// position checked a few times until it moves, is resized, or the drag ends.
final class DragWatcher {
    struct Grab {
        let id: CGWindowID
        let pid: pid_t
        /// Where it was when the drag was noticed, in Core Graphics coordinates.
        let frame: CGRect
        /// Where the pointer was at that same moment, so it can be kept at the
        /// same place on the window.
        var pointer: CGPoint?
    }

    /// A window started moving with the mouse.
    var onStart: ((Grab) -> Void)?
    /// The pointer moved or a modifier changed while it moves. Core Graphics coordinates.
    var onMove: ((CGPoint, CGEventFlags) -> Void)?
    /// The mouse was let go: where, and with which modifiers.
    var onDrop: ((CGPoint, CGEventFlags) -> Void)?
    /// The drag was lost track of.
    var onCancel: (() -> Void)?
    /// While a window moves: the displays to hold the pointer at the edges
    /// of, or nil not to. Only asked by an `active` watcher.
    var holdDisplays: (() -> [LayoutDisplay]?)?
    private var hold = EdgeHold()
    /// macOS has been told to stop moving the cursor. Never left so: every
    /// click, release, restart and quiet second puts it back.
    private var frozen = false
    private var heldAt: CGPoint?
    private var thaw: DispatchWorkItem?

    private enum State {
        case idle
        case pressed(CGPoint)
        case watching(Grab, lastCheck: TimeInterval)
        case moving
        /// A drag that isn't a window being moved: text being selected, a resize.
        case ignored
    }

    private var state = State.idle
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }
    /// In the path of the events rather than beside it, so it can hold the
    /// pointer back. Only while that setting is on: every click then waits
    /// for this, briefly.
    private(set) var active = false

    func start(active: Bool) -> Bool {
        if tap != nil, active == self.active { return true }
        stop()
        self.active = active
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << CGEventMask($1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: active ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<DragWatcher>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        release()
        guard let tap else { return }
        if case .moving = state { onCancel?() }
        state = .idle
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            release()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if case .moving = state { onCancel?() }
            state = .idle
        case .leftMouseDown:
            release()
            hold = EdgeHold()
            state = .pressed(event.location)
        case .leftMouseDragged:
            dragged(event)
        case .leftMouseUp:
            release()
            if case .moving = state { onDrop?(event.location, event.flags) }
            state = .idle
        case .flagsChanged:
            if case .moving = state, let location = CGEvent(source: nil)?.location { onMove?(location, event.flags) }
        default:
            break
        }
    }

    private func dragged(_ event: CGEvent) {
        switch state {
        case .pressed(let point):
            guard let grab = Self.window(at: point) else {
                state = .ignored
                return
            }
            state = .watching(grab, lastCheck: ProcessInfo.processInfo.systemUptime)
        case .watching(let grab, let lastCheck):
            // A window server lookup per check: a few a second is plenty to
            // see the window move.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastCheck >= 0.03 else { return }
            guard let frame = Self.bounds(of: grab.id) else {
                state = .ignored
                return
            }
            if !LayoutWindow.close(frame.size, grab.frame.size) {
                state = .ignored
            } else if abs(frame.minX - grab.frame.minX) > 2 || abs(frame.minY - grab.frame.minY) > 2 {
                state = .moving
                onStart?(Grab(id: grab.id, pid: grab.pid, frame: frame, pointer: event.location))
                onMove?(event.location, event.flags)
            } else {
                state = .watching(grab, lastCheck: now)
            }
        case .moving:
            var location = event.location
            if active, let displays = holdDisplays?() {
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
                    release()
                }
            } else {
                release()
            }
            onMove?(location, event.flags)
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
        thaw?.cancel()
        let thaw = DispatchWorkItem { [weak self] in self?.release() }
        self.thaw = thaw
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: thaw)
    }

    /// Lets the cursor move again, if it was stopped. Also for Esc.
    func release() {
        thaw?.cancel()
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
            else { return nil }
            return Grab(id: id, pid: pid, frame: rect)
        }
        return nil
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
