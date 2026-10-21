import AppKit
import ApplicationServices

/// Turns a two-finger horizontal swipe on the trackpad into back and forward
/// in Finder and System Settings, the way browsers do it: fingers to the right
/// go back, to the left go forward. Scrolling is never changed: the events
/// pass through, and the app is told to go back or forward.
final class SwipeNavigator {
    /// Kept by the main thread, read on the tap's.
    let isOn = Locked(false)

    /// How each app is told. Finder takes the navigation swipe a three-finger
    /// swipe makes; System Settings ignores it, so its Back or Forward menu
    /// item is pressed.
    private enum Method { case swipe, menu }
    private static let apps: [String: Method] = ["com.apple.finder": .swipe, "com.apple.systempreferences": .menu]

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
            switch target.method {
            case .swipe: WheelEngine.postNavigationSwipe(back: fingersRight)
            case .menu: Self.pressMenuItem(in: pid, back: fingersRight)
            }
        }
    }

    /// Presses Back or Forward. The items are looked up on every swipe: a
    /// kept one can be replaced as the app navigates, and pressing the old one
    /// does nothing. Their enabled state isn't checked: a menu that isn't open
    /// doesn't keep it up to date, and the app ignores a press with nowhere to go.
    private static func pressMenuItem(in pid: pid_t, back: Bool) {
        guard let items = backAndForward(in: pid) else { return }
        AXUIElementPerformAction(back ? items.back : items.forward, kAXPressAction as CFString)
    }

    /// The Back and Forward menu items, found by title. Not by shortcut:
    /// macOS adapts shortcuts to the keyboard layout, so ⌘[ shows as ⌘Ç on a
    /// Portuguese keyboard.
    private static func backAndForward(in pid: pid_t) -> (back: AXUIElement, forward: AXUIElement)? {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return nil }
        let titles = titlesByApp[url] ?? menuTitles(url)
        titlesByApp[url] = titles
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return nil }
        // Not the Apple menu or Help, which never hold them.
        for menu in children(bar).dropFirst().dropLast().flatMap(children) {
            var back: AXUIElement?
            var forward: AXUIElement?
            for item in children(menu) {
                let title: String? = attribute(item, kAXTitleAttribute)
                if title == titles.back { back = item }
                if title == titles.forward { forward = item }
            }
            if let back, let forward { return (back, forward) }
        }
        return nil
    }

    /// Read once per app, as the app's language doesn't change while it runs;
    /// only touched on `queue`.
    private static var titlesByApp: [URL: (back: String, forward: String)] = [:]

    /// The titles of Back and Forward in the language the app runs in, from
    /// the app's own translations of its menu. English is in its base nib,
    /// so the English names find the keys of the translated ones.
    private static func menuTitles(_ bundleURL: URL) -> (back: String, forward: String) {
        guard let bundle = Bundle(url: bundleURL) else { return ("Back", "Forward") }
        let language = Bundle.preferredLocalizations(from: bundle.localizations).first ?? "en"
        guard let url = bundle.url(forResource: "MainMenu", withExtension: "loctable"),
              let tables = NSDictionary(contentsOf: url) as? [String: Any],
              let english = (tables["en_GB"] ?? tables["en_AU"]) as? [String: String],
              let translated = tables[language] as? [String: String]
        else { return ("Back", "Forward") }
        func translate(_ name: String) -> String {
            english.first { $0.value == name }.flatMap { translated[$0.key] } ?? name
        }
        return (translate("Back"), translate("Forward"))
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
              let id = app.bundleIdentifier, let method = apps[id]
        else { return nil }
        return (app.processIdentifier, method)
    }

    /// Type-checked, as in `LayoutWindow`: an app can answer with anything.
    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        // Casts to these always succeed in Swift, whatever the app sent back.
        if T.self == AXUIElement.self, CFGetTypeID(value) != AXUIElementGetTypeID() { return nil }
        return value as? T
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let list: NSArray = attribute(element, kAXChildrenAttribute) else { return [] }
        return list.compactMap { item in
            let value = item as CFTypeRef
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
        }
    }
}
