import AppKit
import CoreGraphics

/// Rewrites events from mice: wheel direction, distance and smoothing, and
/// the side buttons. Trackpad and Magic Mouse scrolling (continuous events)
/// is never touched.
final class WheelEngine {
    /// Stamped on events we post ourselves so the tap lets them through.
    private static let marker: Int64 = 0x54494C4C

    /// Returns the profile of the mouse that is scrolling, if it has one.
    /// Called on the tap's thread, so it must be safe there.
    var profileProvider: () -> Profile? = { nil }

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
        tap = EventTap(name: "wheel", events: [.scrollWheel, .otherMouseDown, .otherMouseUp]) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
        }
        return tap != nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return pass }
        if type == .otherMouseDown || type == .otherMouseUp {
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
        let speed = profile.scrollSpeedMode == .custom ? profile.scrollSpeed : 1.0

        let linesY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * signY
        let linesX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * signX
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * signY * speed
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * signX * speed
        let pointY = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * signY * speed
        let pointX = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * signX * speed

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
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.apple.") == true
        else { return false }

        swallowedButtons.insert(button)
        Self.postNavigationSwipe(back: button == 3)
        return true
    }

    /// Posts the same event a three-finger trackpad swipe produces. Apps read
    /// it as "go back / forward", whatever the keyboard layout.
    private static func postNavigationSwipe(back: Bool) {
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
