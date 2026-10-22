import AppKit
import CoreGraphics

/// Rewrites events from mice: wheel direction, distance and smoothing, the
/// side buttons, and autoscroll on the wheel button. Trackpad and Magic Mouse
/// scrolling (continuous events) is never touched.
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

    // Smooth scrolling: distance still to be delivered, in pixels.
    private var remainingX = 0.0
    private var remainingY = 0.0
    private var carryX = 0.0
    private var carryY = 0.0
    private var flags: CGEventFlags = []
    private var timer: Timer?
    private var lastTick = 0.0
    /// The first few events are logged to help diagnose devices that scroll oddly.
    private var loggedEvents = 0

    var isRunning: Bool { tap != nil }

    /// Installs the event tap. Fails (returns false) until Accessibility is granted.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        tap = EventTap(name: "wheel", events: [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]) { [weak self] type, event in
            // nil means "take the event": `??` here would pass it on after all.
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(type: type, event: event)
        }
        return tap != nil
    }

    /// Takes the tap out, while the mouse tool is off: left in, it kept every
    /// scroll and middle click going through the toolkit for nothing.
    func stop() {
        guard let tap else { return }
        self.tap = nil
        // Wound down on the tap's own thread, where the smoothing and autoscroll live.
        tap.perform { [self] in
            autoscroller.cancel()
            timer?.invalidate()
            timer = nil
            remainingX = 0
            remainingY = 0
            tap.stop()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The wheel button's release may have gone by unseen.
            autoscroller.cancel()
            return pass
        }
        if type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged {
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2,
               event.getIntegerValueField(.eventSourceUserData) != Self.marker {
                return autoscroller.handle(type: type, event: event, profile: profileProvider) ? nil : pass
            }
            if type == .otherMouseDragged { return pass }
            return handleButton(type: type, event: event) ? nil : pass
        }
        if type == .scrollWheel, loggedEvents < 5 {
            loggedEvents += 1
            NSLog("Toolkit: scroll event continuous=\(event.getIntegerValueField(.scrollWheelEventIsContinuous)) lines=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) points=\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) hasProfile=\(profileProvider() != nil)")
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

        var linesY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * signY
        var linesX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * signX
        var fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * signY * speed
        var fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * signX * speed
        var pointY = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * signY * speed
        var pointX = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * signX * speed

        if profile.scrollMode != .macOS {
            // With its curve off, macOS makes a slow notch a tenth of a line,
            // a single point (measured on an MX Anywhere 2S, which reports an
            // ordinary wheel): barely a move. Each notch, one event, goes a set
            // distance instead, as a wheel scrolls on Windows, or one along the
            // graph. Only up and down: a tilt sends events for as long as it's
            // held, not notches, so sideways each is a line.
            if fixedY != 0 {
                let lines = profile.scrollMode == .fixed ? profile.scrollLines : acceleration(profile)
                linesY = Self.notch(fixedY) * lines
            } else {
                linesY = 0
            }
            linesX = Self.notch(fixedX) * Self.sidewaysLines
            fixedY = linesY
            fixedX = linesX
            pointY = fixedY * Self.pointsPerLine
            pointX = fixedX * Self.pointsPerLine
        }

        if profile.smoothScrolling {
            // A reversal should take effect immediately rather than fight the tail.
            if remainingY * pointY < 0 { remainingY = 0; carryY = 0 }
            if remainingX * pointX < 0 { remainingX = 0; carryX = 0 }
            remainingY += pointY
            remainingX += pointX
            flags = event.flags
            startAnimating()
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

    /// Sideways, with a set distance up and down: a line each event.
    static let sidewaysLines = 1.0
    /// What macOS makes of a line, in points (measured: 1.595 lines, 16 points).
    static let pointsPerLine = 10.0

    /// Notches a second, smoothed, and when the last one came: the pace of a
    /// spin, on the tap's thread.
    private var pace = 0.0
    private var lastNotch = 0.0

    /// The lines this notch goes, along the graph: its start at a gentle pace,
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
        return Self.further(start: profile.scrollCurveStart, end: profile.scrollCurveEnd, bend: profile.scrollCurveBend,
                            curved: profile.scrollCurve == .curve, at: fast)
    }

    /// The lines a notch goes at `pace` (0, gentle, to 1, a fast spin), from
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

    // MARK: - Side buttons

    /// Side buttons whose press we swallowed, so the release goes the same way.
    private var swallowedButtons: Set<Int64> = []

    /// Turns the back (3) and forward (4) buttons into navigation swipes for
    /// Apple's apps, which ignore the buttons themselves. Other apps mostly
    /// handle the buttons natively, so they get them unchanged.
    /// Returns true when the event was consumed.
    private func handleButton(type: CGEventType, event: CGEvent) -> Bool {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == 3 || button == 4 else { return false }
        if type == .otherMouseUp {
            return swallowedButtons.remove(button) != nil
        }
        guard profileProvider()?.navigationButtons == true,
              FrontApp.bundleID?.hasPrefix("com.apple.") == true
        else { return false }

        swallowedButtons.insert(button)
        Self.postNavigationSwipe(back: button == 3)
        return true
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

    private func startAnimating() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        // On the tap's thread, with the rest of the smoothing.
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        // Exponential ease-out: each frame delivers a fixed share of what is left.
        let share = 1 - exp(-dt / 0.07)
        let stepY = Self.take(&remainingY, &carryY, share)
        let stepX = Self.take(&remainingX, &carryX, share)

        if stepX != 0 || stepY != 0,
           let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: stepY, wheel2: stepX, wheel3: 0) {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        }
        if remainingX == 0, remainingY == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Removes this frame's whole-pixel step from `remaining`, keeping the
    /// fractional part in `carry` so no distance is lost to rounding.
    private static func take(_ remaining: inout Double, _ carry: inout Double, _ share: Double) -> Int32 {
        guard remaining != 0 else { return 0 }
        var move = remaining * share
        if abs(remaining) < 0.5 { move = remaining }
        remaining -= move
        carry += move
        let whole = carry.rounded(.towardZero)
        carry -= whole
        if abs(remaining) < 0.01 {
            remaining = 0
            carry = 0
        }
        return Int32(whole)
    }
}
