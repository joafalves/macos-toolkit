import AppKit
import ApplicationServices

/// A window to move: another app's, through Accessibility, or one of the
/// toolkit's own. Accessibility calls to our own process run on the calling
/// thread, where AppKit refuses them, so ours go through AppKit instead.
///
/// Every method blocks until the app answers, so they are only called on the
/// layout's work queue, never on the main thread.
enum LayoutWindow {
    case other(window: AXUIElement, app: AXUIElement, id: CGWindowID, pid: pid_t)
    case own(NSWindow, id: CGWindowID)

    var id: CGWindowID {
        switch self {
        case .other(_, _, let id, _), .own(_, let id): return id
        }
    }

    // MARK: - Finding windows

    /// The window with the keyboard in the frontmost app, if it's one that
    /// can be placed: a standard window, not minimized or in full screen.
    static func focused(pid: pid_t) -> LayoutWindow? {
        if pid == ProcessInfo.processInfo.processIdentifier {
            return DispatchQueue.main.sync {
                let window = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first(where: ownCandidate)
                    ?? NSApp.windows.first(where: ownCandidate)
                return window.flatMap { w in w.windowID.map { .own(w, id: $0) } }
            }
        }
        let app = AXUIElementCreateApplication(pid)
        guard let element: AXUIElement = attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXMainWindowAttribute) else { return nil }
        return make(element, app: app, pid: pid)
    }

    /// The window with this window server ID, from the app that owns it.
    static func find(id: CGWindowID, pid: pid_t) -> LayoutWindow? {
        if pid == ProcessInfo.processInfo.processIdentifier {
            return DispatchQueue.main.sync {
                NSApp.windows.first { $0.windowID == id && ownCandidate($0) }.map { .own($0, id: id) }
            }
        }
        let app = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        for element in windows {
            var found: CGWindowID = 0
            if _AXUIElementGetWindow(element, &found) == .success, found == id { return make(element, app: app, pid: pid) }
        }
        return nil
    }

    private static func make(_ element: AXUIElement, app: AXUIElement, pid: pid_t) -> LayoutWindow? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0,
              let subrole: String = attribute(element, kAXSubroleAttribute), subrole == kAXStandardWindowSubrole,
              !(attribute(element, kAXMinimizedAttribute) ?? false),
              !(attribute(element, "AXFullScreen") ?? false)
        else { return nil }
        return .other(window: element, app: app, id: id, pid: pid)
    }

    /// Our own titled windows, not the overlays and panels.
    private static func ownCandidate(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.styleMask.contains(.titled)
            && !(window is NSPanel) && !window.styleMask.contains(.fullScreen)
    }

    // MARK: - Reading and moving

    var title: String {
        switch self {
        case .other(let window, let app, _, _):
            let title: String = Self.attribute(window, kAXTitleAttribute) ?? ""
            let name: String = Self.attribute(app, kAXTitleAttribute) ?? ""
            return [name, title].filter { !$0.isEmpty }.joined(separator: " — ")
        case .own(let window, _):
            return DispatchQueue.main.sync { window.title }
        }
    }

    /// In Core Graphics coordinates.
    var frame: CGRect? {
        switch self {
        case .other(let window, _, _, _):
            var position = CGPoint.zero, size = CGSize.zero
            guard let p: AXValue = Self.attribute(window, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &position),
                  let s: AXValue = Self.attribute(window, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size)
            else { return nil }
            return CGRect(origin: position, size: size)
        case .own(let window, _):
            return DispatchQueue.main.sync { Coordinates.toCG(window.frame) }
        }
    }

    /// Moves and resizes the window, and returns where it ended up. A window
    /// that won't take the size (it has a minimum, or can't be resized) gets
    /// as close as it goes, centred on the target and kept within `area`.
    @discardableResult
    func setFrame(_ target: CGRect, within area: CGRect) -> CGRect? {
        switch self {
        case .other(let window, let app, _, _):
            // With this on (VoiceOver, some window managers, Chrome and
            // Electron apps once asked), apps animate every change, slowly and
            // sometimes to the wrong place.
            let enhanced: Bool = Self.attribute(app, "AXEnhancedUserInterface") ?? false
            if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
            // Size first, so a move to a smaller display isn't refused, and
            // again after, in case the old display had held it back.
            func send() {
                set(size: target.size, of: window)
                set(position: target.origin, of: window)
                set(size: target.size, of: window)
            }
            send()
            guard var actual = frame else { return nil }
            // A window that just changed display may still be fitted to it
            // by its app a moment later, undoing part of the move.
            for _ in 0..<2 where !Self.close(actual, target) {
                usleep(50_000)
                send()
                actual = frame ?? actual
            }
            guard !Self.close(actual.size, target.size) else { return actual }
            set(position: Self.centred(actual.size, on: target, within: area), of: window)
            return frame ?? actual
        case .own(let window, _):
            return DispatchQueue.main.sync {
                let min = window.minSize
                var size = target.size
                size.width = max(size.width, min.width)
                size.height = max(size.height, min.height)
                let origin = Self.close(size, target.size) ? target.origin : Self.centred(size, on: target, within: area)
                window.setFrame(Coordinates.toAppKit(CGRect(origin: origin, size: size)), display: true)
                return Coordinates.toCG(window.frame)
            }
        }
    }

    /// Only the size, keeping the top left corner: for a window that's being
    /// dragged, where the window server owns the position.
    func setSize(_ size: CGSize, origin: CGPoint) {
        switch self {
        case .other(let window, _, _, _):
            set(size: size, of: window)
            set(position: origin, of: window)
        case .own(let window, _):
            DispatchQueue.main.sync {
                window.setFrame(Coordinates.toAppKit(CGRect(origin: origin, size: size)), display: true)
            }
        }
    }

    func setPosition(_ origin: CGPoint) {
        switch self {
        case .other(let window, _, _, _):
            set(position: origin, of: window)
        case .own(let window, _):
            DispatchQueue.main.sync {
                window.setFrameOrigin(Coordinates.toAppKit(CGRect(origin: origin, size: window.frame.size)).origin)
            }
        }
    }

    private func set(size: CGSize, of window: AXUIElement) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    private func set(position: CGPoint, of window: AXUIElement) {
        var position = position
        if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
    }

    static func close(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        close(a.size, b.size) && abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
    }

    /// Every edge within a line of text or so: a terminal rounds its size
    /// to whole characters, and other apps keep their own margins.
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 20 && abs(a.minY - b.minY) <= 20 && abs(a.maxX - b.maxX) <= 20 && abs(a.maxY - b.maxY) <= 20
    }

    private static func centred(_ size: CGSize, on target: CGRect, within area: CGRect) -> CGPoint {
        var origin = CGPoint(x: (target.midX - size.width / 2).rounded(), y: (target.midY - size.height / 2).rounded())
        origin.x = min(max(origin.x, area.minX), max(area.maxX - size.width, area.minX))
        origin.y = min(max(origin.y, area.minY), max(area.maxY - size.height, area.minY))
        return origin
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        // Casts to these always succeed in Swift, whatever the app sent back.
        if T.self == AXUIElement.self, CFGetTypeID(value) != AXUIElementGetTypeID() { return nil }
        if T.self == AXValue.self, CFGetTypeID(value) != AXValueGetTypeID() { return nil }
        return value as? T
    }
}
