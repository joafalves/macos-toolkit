import AppKit
import ApplicationServices

/// How each app is told to go back or forward, for Mouse's back and forward
/// buttons and the Finder tool's swipes alike: one table, so an app fixed for
/// one is fixed for both.
enum AppNavigation {
    enum Method { case swipe, menu }

    /// Apple's apps take the navigation swipe a three-finger swipe makes,
    /// except these, which ignore it: their Back and Forward menu items are
    /// pressed instead.
    private static let byMenu: Set<String> = ["com.apple.systempreferences"]

    static func method(for bundleID: String) -> Method {
        byMenu.contains(bundleID) ? .menu : .swipe
    }

    /// Accessibility can wait on a busy app, so never on an event tap's thread.
    private static let queue = DispatchQueue(label: "dev.jalves.macos-toolkit.navigation")

    static func go(back: Bool, method: Method, pid: pid_t) {
        switch method {
        case .swipe: WheelEngine.postNavigationSwipe(back: back)
        case .menu: queue.async { pressMenuItem(in: pid, back: back) }
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
    static func backAndForward(in pid: pid_t) -> (back: AXUIElement, forward: AXUIElement)? {
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

    /// Type-checked, as in `LayoutWindow`: an app can answer with anything.
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        // Casts to these always succeed in Swift, whatever the app sent back.
        if T.self == AXUIElement.self, CFGetTypeID(value) != AXUIElementGetTypeID() { return nil }
        return value as? T
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let list: NSArray = attribute(element, kAXChildrenAttribute) else { return [] }
        return list.compactMap { item in
            let value = item as CFTypeRef
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
        }
    }
}
