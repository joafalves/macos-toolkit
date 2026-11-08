import AppKit
import CoreGraphics

/// What a mouse button given an action of its own does, on the main thread:
/// from the wheel tap for buttons macOS numbers, from the HID++ channel for
/// the ones the mouse keeps to itself.
enum ButtonActions {
    /// Stamped on the keys a Shortcut action posts, so no tap of ours takes them for typing.
    static let marker: Int64 = 0x42544E53

    static func perform(_ assignment: ButtonAssignment, down: Bool) {
        // Held for as long as the button is: open while down, the pick on release.
        if assignment.action == .floatingDock {
            FloatingDockController.shared?.trigger(down: down, source: .mouse)
            return
        }
        guard down else { return }
        switch assignment.action {
        // Autoscroll is the wheel tap's, on its own thread.
        case .nothing, .floatingDock, .autoscroll: break
        case .back, .forward: navigate(back: assignment.action == .back)
        case .missionControl: ShowDesktop.missionControl()
        case .showDesktop: ShowDesktop.toggle()
        case .shortcut: press(assignment.shortcut)
        case .openApp:
            guard let path = assignment.appPath else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The buttons apps take for back and forward, as macOS numbers them: the
    /// fourth and fifth.
    static let backButton: Int64 = 3
    static let forwardButton: Int64 = 4

    /// Whether a press of `button` is let through to the app as it is: Back
    /// on the button apps already take for back, and Forward on theirs, unless
    /// the app is one of Apple's, which ignore the buttons. On the tap's thread.
    static func passesThrough(_ action: ButtonAction, button: Int64, frontApp: String?) -> Bool {
        guard (action == .back && button == backButton) || (action == .forward && button == forwardButton) else { return false }
        return !isApple(frontApp)
    }

    private static func isApple(_ bundleID: String?) -> Bool {
        bundleID?.hasPrefix("com.apple.") == true
    }

    /// Back or forward in the front app: as `AppNavigation` says in Apple's
    /// apps, which ignore the mouse's buttons; elsewhere a click of the button
    /// apps take for it, which browsers and editors already handle.
    private static func navigate(back: Bool) {
        guard let pid = FrontApp.pid else { return }
        let app = FrontApp.bundleID
        if isApple(app) {
            AppNavigation.go(back: back, method: AppNavigation.method(for: app ?? ""), pid: pid)
            return
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center) else { continue }
            event.setIntegerValueField(.mouseEventButtonNumber, value: back ? backButton : forwardButton)
            // Through the wheel tap untouched, as autoscroll's clicks are.
            event.setIntegerValueField(.eventSourceUserData, value: WheelEngine.marker)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// The shortcut's key down and up, with its modifiers, as if typed.
    static func press(_ shortcut: Shortcut) {
        guard !shortcut.isNone else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: down) else { continue }
            event.flags = shortcut.cgFlags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }
}
