import AppKit
import ApplicationServices

/// Turns a two-finger horizontal swipe on the trackpad into back and forward
/// in Finder and System Settings, the way browsers do it: fingers to the right
/// go back, to the left go forward. Scrolling is never changed: the events
/// pass through, and the app is told to go back or forward.
final class SwipeNavigator {
    /// Kept by the main thread, read on the tap's.
    let isOn = Locked(false)

    /// The apps the swipe works in; `AppNavigation` says how each is told.
    private static let apps: Set<String> = ["com.apple.finder", "com.apple.systempreferences"]
    private typealias Method = AppNavigation.Method

    /// How far the fingers travel, in points, before it counts as a swipe.
    private static let threshold = 80.0

    private enum Axis { case undecided, horizontal, vertical }

    // The gesture in progress; only touched on the tap's thread.
    private var active = false
    private var axis = Axis.undecided
    private var dx = 0.0
    private var dy = 0.0
    private var natural = true

    /// The window list and Accessibility are slow next to the event tap, and
    /// the app may be busy, so they're read here.
    private let queue = DispatchQueue(label: "dev.jalves.macos-toolkit.swipe")
    /// What was under the cursor when the gesture began; only touched on `queue`.
    private var target = Target.none

    private struct Target {
        var pid: pid_t?
        var method = Method.swipe
        /// A scroll area under the cursor that can still move that way, so the
        /// swipe scrolls it instead, as in a browser.
        var canScrollLeft = false
        var canScrollRight = false
        static let none = Target()
    }

    // kCGScrollPhase and kCGMomentumScrollPhase values.
    private static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4, cancelled: Int64 = 8

    /// Called on the tap's thread with every continuous (trackpad or Magic
    /// Mouse) scroll event.
    func handle(_ event: CGEvent) {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        if phase == Self.began {
            active = isOn.value
            guard active else { return }
            axis = .undecided
            dx = 0
            dy = 0
            // With natural scrolling the content follows the fingers.
            natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
            // The tap sees the event before the app does, so this reads the
            // scroll position from before the gesture moved anything.
            let point = event.location
            queue.async { [self] in target = Self.target(at: point) }
        }
        guard active, event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
        if phase == Self.ended || phase == Self.cancelled {
            active = false
            return
        }
        guard phase == Self.began || phase == Self.changed else { return }

        dx += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        dy += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        if axis == .undecided, hypot(dx, dy) >= 6 {
            axis = abs(dx) > abs(dy) * 1.5 ? .horizontal : .vertical
        }
        guard axis == .horizontal, abs(dx) >= Self.threshold, abs(dx) > abs(dy) * 2 else { return }

        // One navigation per gesture.
        active = false
        // A positive delta moves the content right, toward its left edge.
        let towardLeft = dx > 0
        let fingersRight = natural ? dx > 0 : dx < 0
        queue.async { [self] in
            guard let pid = target.pid, !(towardLeft ? target.canScrollLeft : target.canScrollRight) else { return }
            AppNavigation.go(back: fingersRight, method: target.method, pid: pid)
        }
    }

    private static func target(at point: CGPoint) -> Target {
        guard let (pid, method) = windowOwner(at: point) else { return .none }
        var target = Target(pid: pid, method: method)
        // Only Finder has things that scroll sideways (the column view, wide
        // lists), so only Finder is asked what's under the cursor.
        guard method == .swipe else { return target }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit
        else { return .none }

        // Walk out through every enclosing scroll area: the column view
        // scrolls sideways around columns that each scroll up and down.
        var element: AXUIElement? = hit
        for _ in 0..<16 {
            guard let current = element else { break }
            if attribute(current, kAXRoleAttribute) as String? == kAXScrollAreaRole as String,
               let bar: AXUIElement = attribute(current, kAXHorizontalScrollBarAttribute),
               attribute(bar, kAXEnabledAttribute) as Bool? != false,
               let position: NSNumber = attribute(bar, kAXValueAttribute) {
                if position.doubleValue > 0.005 { target.canScrollLeft = true }
                if position.doubleValue < 0.995 { target.canScrollRight = true }
            }
            element = attribute(current, kAXParentAttribute)
        }
        return target
    }

    /// The app under the cursor, when it's one of `apps`.
    private static func windowOwner(at point: CGPoint) -> (pid_t, Method)? {
        guard let app = NSRunningApplication.owningWindow(at: point),
              let id = app.bundleIdentifier, apps.contains(id)
        else { return nil }
        return (app.processIdentifier, AppNavigation.method(for: id))
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? { AppNavigation.attribute(element, name) }
}
