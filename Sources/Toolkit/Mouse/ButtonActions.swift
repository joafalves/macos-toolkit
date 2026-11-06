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
        case .nothing, .floatingDock: break
        case .back, .forward:
            guard let pid = FrontApp.pid else { return }
            AppNavigation.go(back: assignment.action == .back, method: AppNavigation.method(for: FrontApp.bundleID ?? ""), pid: pid)
        case .missionControl: ShowDesktop.missionControl()
        case .showDesktop: ShowDesktop.toggle()
        case .shortcut: press(assignment.shortcut)
        case .openApp:
            guard let path = assignment.appPath else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
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
