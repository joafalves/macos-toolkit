import AppKit
import CoreGraphics
import os

/// Rewrites events from mice: wheel direction, distance and smoothing, and
/// the buttons given an action, autoscroll on the wheel button among them.
/// Trackpad and Magic Mouse scrolling (continuous events) is never touched.
final class WheelEngine {
    /// Stamped on events we post ourselves so the tap lets them through.
    static let marker: Int64 = 0x54494C4C

    /// Returns the profile of the mouse that is scrolling, if it has one.
    /// Called on the tap's thread, so it must be safe there.
    var profileProvider: () -> Profile? = { nil }
    /// On the tap's thread, like the smoothing.
    let autoscroller = Autoscroller()

    /// Everything below, the smoothing included, lives on the tap's thread.
    private var tap: EventTap?

    /// Smooth scrolling, a frame at a time of the display under the pointer.
    /// Made with the engine, not lazily: the tap's thread and the main one both reach it.
    private var glide: Glide!
    /// What the display links call, holding the glide weakly; and the
    /// watch for displays coming and going, which gives them new links.
    private let linkTarget = Glide.LinkTarget()
    private var screens: NSObjectProtocol?
    /// What a distance in points has left over, and the points not yet
    /// counted as a line, each way: see `setDistance`.
    private var pointsLeft = (x: 0.0, y: 0.0)
    private var linesLeft = (x: 0.0, y: 0.0)
    private var flags: CGEventFlags = []
    /// The first few events are logged to help diagnose devices that scroll oddly.
    private var loggedEvents = 0

    var isRunning: Bool { tap != nil }

    init() {
        glide = Glide { [weak self] x, y in self?.postGlide(x: x, y: y) }
        linkTarget.glide = glide
    }

    /// While a mouse's buttons are shown for pressing: presses over the
    /// toolkit's own windows go to them as they are, so a button with an
    /// action can still be found by pressing it.
    let identifying = Locked(false)
    private static let ownPID = getpid()

    /// Installs the event tap. Fails (returns false) until Accessibility is granted.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        tap = EventTap(name: "wheel", events: [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]) { [weak self] type, event in
            // nil means "take the event": `??` here would pass it on after all.
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(type: type, event: event)
        }
        guard tap != nil else { return false }
        installLinks()
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                         queue: .main) { [weak self] _ in self?.installLinks() }
        return true
    }

    /// On the main thread, where they're made: a display link for each
    /// display, run on the tap's thread with the rest of the glide.
    private func installLinks() {
        guard let tap else { return }
        let links = Glide.makeLinks(target: linkTarget)
        tap.perform { [glide] in glide.install(links) }
    }

    /// Takes the tap out, while the mouse tool is off: left in, it kept every
    /// scroll and middle click going through the toolkit for nothing.
    func stop() {
        guard let tap else { return }
        self.tap = nil
        if let screens { NotificationCenter.default.removeObserver(screens) }
        screens = nil
        // Wound down on the tap's own thread, where the smoothing and autoscroll live.
        tap.perform { [self] in
            releaseHeld()
            autoscroller.cancel()
            glide.install([])
            tap.stop()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The wheel button's release may have gone by unseen, and a side button's.
            autoscroller.cancel()
            releaseHeld()
            return pass
        }
        if type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged {
            // Our own clicks: autoscroll's middle click, Back's button.
            guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return pass }
            if identifying.value, FrontApp.pid == Self.ownPID, held.isEmpty, !autoscroller.isActive { return pass }
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                let taken = autoscroller.handle(type: type, event: event) { [profileProvider] in
                    guard let profile = profileProvider(), profile.assignment(for: .number(2))?.action == .autoscroll else { return nil }
                    return profile.autoscrollPace
                }
                if let taken { return taken ? nil : pass }
            }
            return handleAssigned(type: type, event: event) ? nil : pass
        }
        if type == .scrollWheel, loggedEvents < 5 {
            loggedEvents += 1
            Log.mouse.debug("scroll event continuous=\(event.getIntegerValueField(.scrollWheelEventIsContinuous)) lines=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) points=\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) hasProfile=\(self.profileProvider() != nil)")
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              let profile = profileProvider(), profile.rewritesWheelEvents
        else { return pass }

        let signY = profile.verticalInverted ? -1.0 : 1.0
        let signX = profile.horizontalInverted ? -1.0 : 1.0
        // A multiplier only on macOS's own distances; the others set their own.
        let speed = profile.scrollMode == .macOS ? profile.scrollSpeed : 1.0

        let linesY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * signY
        let linesX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * signX
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * signY * speed
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * signX * speed
        var pointY = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * signY * speed
        var pointX = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * signX * speed

        if profile.scrollMode != .macOS {
            // With its curve off, macOS makes a slow notch a tenth of a line,
            // a single point (measured on an MX Anywhere 2S, which reports an
            // ordinary wheel): barely a move. Each notch, one event, goes a set
            // distance instead, or one along the graph. Only up and down: a
            // tilt sends events for as long as it's held, not notches, so
            // sideways each is a step.
            pointY = fixedY == 0 ? 0 : Self.notch(fixedY) * (profile.scrollMode == .fixed ? profile.scrollDistance : acceleration(profile))
            pointX = Self.notch(fixedX) * Self.sidewaysPoints
            if !profile.smoothScrolling {
                // In points, as a trackpad reports, not lines: each app makes
                // a line its own size, from 10 px to 50, and some read only
                // that the wheel moved, but most scroll a distance as given.
                setDistance(event, x: pointX, y: pointY)
                return pass
            }
        }

        if profile.smoothScrolling {
            flags = event.flags
            glide.add(x: pointX, y: pointY, length: profile.glide.duration, at: event.location)
            return nil
        }

        // The whole-line delta must be written first: setting it resets the others.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Self.scaledLines(linesY, speed))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Self.scaledLines(linesX, speed))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedX)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pointY.rounded()))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(pointX.rounded()))
        return pass
    }

    /// Sideways, with a set distance up and down: about a line of text each event.
    static let sidewaysPoints = 20.0
    /// A line in a scroll event that gives a distance: what macOS puts in
    /// one it makes itself, 3 for 30 points.
    static let pointsPerLine = 10.0

    /// Makes `event` a distance on screen, in points, as a trackpad's events
    /// are. The points are whole, as apps read them; what's left over goes
    /// with the next. The lines are whole too, and only as many as the
    /// distance has gone: macOS's own pixel events say a line for every one,
    /// however small, and an app that counts lines scrolled one each.
    func setDistance(_ event: CGEvent, x: Double, y: Double) {
        func take(_ points: Double, _ left: inout Double, _ uncounted: inout Double) -> (lines: Int64, fixed: Double, points: Int64) {
            // A turn the other way starts afresh.
            if left * points < 0 { left = 0 }
            if uncounted * points < 0 { uncounted = 0 }
            let total = points + left
            let whole = total.rounded(.towardZero)
            left = total - whole
            // Kept in whole points, so the count never drifts with rounding.
            uncounted += whole
            let lines = (uncounted / Self.pointsPerLine).rounded(.towardZero)
            uncounted -= lines * Self.pointsPerLine
            return (Int64(lines), whole / Self.pointsPerLine, Int64(whole))
        }
        let vertical = take(y, &pointsLeft.y, &linesLeft.y)
        let sideways = take(x, &pointsLeft.x, &linesLeft.x)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // The whole-line delta must be written first: setting it resets the others.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: vertical.lines)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: sideways.lines)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: vertical.fixed)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: sideways.fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: vertical.points)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: sideways.points)
    }

    /// Notches a second, smoothed, and when the last one came: the pace of a
    /// spin, on the tap's thread.
    private var pace = 0.0
    private var lastNotch = 0.0

    /// The points this notch goes, along the graph: its start at a gentle pace,
    /// so a single notch is always the same, up to its end for a fast spin.
    /// One event is one notch: the mouse reports up to 125 times a second
    /// (its 8 ms report interval), more than a ratchet wheel turns.
    private func acceleration(_ profile: Profile) -> Double {
        let now = CACurrentMediaTime()
        let gap = now - lastNotch
        lastNotch = now
        // A pause starts a new spin from rest.
        pace = gap > 0.25 ? 0 : 0.6 * pace + 0.4 / max(gap, 0.004)
        // Six notches a second or fewer: none; forty or more: all of it.
        let fast = min(max((pace - 6) / 34, 0), 1)
        return Self.further(start: profile.scrollCurveFrom, end: profile.scrollCurveTo, bend: profile.scrollCurveBend,
                            curved: profile.scrollCurve == .curve, at: fast)
    }

    /// The points a notch goes at `pace` (0, gentle, to 1, a fast spin), from
    /// `start` to `end`, as the settings' graph draws it.
    static func further(start: Double, end: Double, bend: Double, curved: Bool, at pace: Double) -> Double {
        start + (end - start) * (curved ? pow(pace, bend) : pace)
    }

    /// The direction of a notch: one event, whatever distance macOS gave it.
    private static func notch(_ delta: Double) -> Double {
        delta > 0 ? 1 : delta < 0 ? -1 : 0
    }

    /// Scales a line count, never rounding a real notch down to nothing.
    private static func scaledLines(_ lines: Double, _ speed: Double) -> Int64 {
        guard lines != 0 else { return 0 }
        let scaled = (lines * speed).rounded()
        return scaled == 0 ? (lines > 0 ? 1 : -1) : Int64(scaled)
    }

    // MARK: - Buttons with an action

    /// Buttons held down whose press went to their action: the drags and the
    /// release go there too, never to the app under the pointer.
    private var held: [Int64: ButtonAssignment] = [:]
    /// Buttons whose press was let through to the app, as Back and Forward
    /// are where the app knows them: the release goes the same way.
    private var passed: Set<Int64> = []

    /// A button given an action of its own: true when taken.
    private func handleAssigned(type: CGEventType, event: CGEvent) -> Bool {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if type == .otherMouseDown {
            // A press, so a release still waited for went by unseen.
            if let stale = held.removeValue(forKey: button) { Self.main(stale, down: false) }
            passed.remove(button)
            guard let assignment = profileProvider()?.assignment(for: .number(Int(button))) else { return false }
            if ButtonActions.passesThrough(assignment.action, button: button, frontApp: FrontApp.bundleID) {
                passed.insert(button)
                return false
            }
            held[button] = assignment
            Self.main(assignment, down: true)
            return true
        }
        if passed.contains(button) {
            if type == .otherMouseUp { passed.remove(button) }
            return false
        }
        guard let assignment = held[button] else { return false }
        // The Floating Dock follows the mouse by its drags: let them on to its tap,
        // which keeps them from the apps.
        if type == .otherMouseDragged, assignment.action == .floatingDock { return false }
        if type == .otherMouseUp {
            held[button] = nil
            Self.main(assignment, down: false)
        }
        return true
    }

    private func releaseHeld() {
        for assignment in held.values { Self.main(assignment, down: false) }
        held.removeAll()
        passed.removeAll()
    }

    private static func main(_ assignment: ButtonAssignment, down: Bool) {
        DispatchQueue.main.async { ButtonActions.perform(assignment, down: down) }
    }

    /// Posts the same event a three-finger trackpad swipe produces. Apps read
    /// it as "go back / forward", whatever the keyboard layout.
    static func postNavigationSwipe(back: Bool) {
        // Undocumented gesture fields: HID event type, swipe direction, phase.
        guard let event = CGEvent(source: nil),
              let gestureType = CGEventType(rawValue: 29),
              let hidType = CGEventField(rawValue: 110),
              let swipeValue = CGEventField(rawValue: 115),
              let phase = CGEventField(rawValue: 132)
        else { return }
        event.type = gestureType
        event.setIntegerValueField(hidType, value: 16)             // navigation swipe
        event.setIntegerValueField(swipeValue, value: back ? 4 : 8) // left : right
        event.setIntegerValueField(phase, value: 1)                // began
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: - Smooth scrolling

    /// A frame's step of the glide, as a distance in points like a notch's.
    private func postGlide(x: Int32, y: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        // Made again with the lines carried from one frame to the next: as
        // macOS makes it, each frame says a line, and an app that counts
        // lines went one a frame.
        setDistance(event, x: Double(x), y: Double(y))
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }
}
