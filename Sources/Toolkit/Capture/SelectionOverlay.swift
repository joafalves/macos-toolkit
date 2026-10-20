import AppKit

/// Lets a window of ours take keys and clicks without making the toolkit the
/// active app, so the app being captured keeps its active look.
class CapturePanel: NSPanel {
    /// Returns true when the key was handled.
    var onKey: ((NSEvent) -> Bool)?
    var onFlags: ((NSEvent) -> Void)?

    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        onFlags?(event)
        super.flagsChanged(with: event)
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// Picks what to capture: an area dragged out, a window clicked, or a whole
/// display clicked. One window per display, all sharing this state.
final class SelectionOverlay {
    enum Mode { case area, window, screen }

    /// The quick ⇧⌘4 kind captures as soon as the drag ends. The toolbar kind
    /// keeps the area on screen to adjust, until Capture is pressed.
    private(set) var quick = true
    private(set) var mode = Mode.area
    /// In AppKit global coordinates.
    var selection: NSRect? {
        didSet { redraw() }
    }
    fileprivate var hovered: (id: CGWindowID, frame: NSRect)?
    fileprivate var hoveredScreen: NSScreen?
    fileprivate var mouse = NSPoint.zero
    fileprivate var drag: Drag?

    /// The target, and whether ⌃ was held as it was picked.
    var onPick: ((CaptureTarget, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onModeChange: ((Mode) -> Void)?
    var onAreaChange: ((NSRect) -> Void)?
    /// Enter, from the toolbar's kind of overlay.
    var onConfirm: ((NSEvent) -> Void)?

    private var windows: [CapturePanel] = []
    private var candidates: [(id: CGWindowID, frame: NSRect)] = []

    var isVisible: Bool { !windows.isEmpty }
    var windowNumbers: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    func show(mode: Mode, quick: Bool, area: NSRect? = nil) {
        hide()
        self.quick = quick
        self.mode = mode
        selection = quick ? nil : area
        mouse = NSEvent.mouseLocation
        loadCandidates()
        for screen in NSScreen.screens {
            let panel = CapturePanel(frame: screen.frame, level: .screenSaver)
            let view = OverlayView(overlay: self, screen: screen)
            panel.contentView = view
            panel.onKey = { [weak self] event in self?.key(event) ?? false }
            panel.acceptsMouseMovedEvents = true
            // Clicks on see-through pixels would go to the window below: the
            // quick kind draws nothing until a drag starts, and the area is a hole.
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        CaptureCursor.allowInBackground()
        // The display under the mouse takes the keys.
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        updateHover()
        redraw()
        cursorUpdate()
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        drag = nil
        hovered = nil
        NSCursor.arrow.set()
    }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        drag = nil
        if mode == .window { loadCandidates() }
        updateHover()
        redraw()
        cursorUpdate()
    }

    /// The target for the toolbar's Capture button.
    func currentTarget(toolbarScreen: NSScreen?) -> CaptureTarget? {
        switch mode {
        case .area:
            guard let selection, selection.width >= 4, selection.height >= 4 else { return nil }
            return .area(Coordinates.toCG(selection))
        case .window:
            return hovered.map { .window($0.id) }
        case .screen:
            return (toolbarScreen ?? hoveredScreen ?? NSScreen.main).map { .display($0.displayID) }
        }
    }

    // MARK: - Windows under the mouse

    private func loadCandidates() {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        candidates = list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let layer = info[kCGWindowLayer as String] as? Int, (0..<20).contains(layer),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 40, rect.height >= 40
            else { return nil }
            return (id, Coordinates.toAppKit(rect))
        }
    }

    fileprivate func updateHover() {
        hoveredScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
        guard mode == .window else { hovered = nil; return }
        // Front to back, so the first hit is the one on top.
        let hit = candidates.first { $0.frame.contains(mouse) }
        if hit?.id != hovered?.id {
            hovered = hit
            redraw()
        }
    }

    fileprivate func redraw() {
        windows.forEach { $0.contentView?.needsDisplay = true }
    }

    fileprivate func cursorUpdate() {
        (mode == .window ? CaptureCursor.camera : NSCursor.crosshair).set()
    }

    // MARK: - Input

    private func key(_ event: NSEvent) -> Bool {
        lastEvent = event
        switch event.keyCode {
        case 53:  // Esc
            onCancel?()
            return true
        case 49 where drag == nil && quick:  // Space
            setMode(mode == .window ? .area : .window)
            onModeChange?(mode)
            return true
        case 36, 76:  // Return, Enter
            onConfirm?(event)
            return true
        default:
            return false
        }
    }

    /// Whether ⌃ is down: from the event itself, or from the window server's
    /// keyboard state. `NSEvent.modifierFlags` isn't kept up to date for an
    /// app in the background, which is what the toolkit is while capturing.
    static func controlDown(_ event: NSEvent? = nil) -> Bool {
        event?.modifierFlags.contains(.control) == true
            || CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
    }

    fileprivate func mouseDown(at point: NSPoint, on screen: NSScreen) {
        mouse = point
        switch mode {
        case .window, .screen:
            break
        case .area:
            if !quick, let selection, let handle = Handle.hit(point, in: selection) {
                drag = .resize(handle, selection)
            } else if !quick, let selection, selection.contains(point) {
                drag = .move(from: point, original: selection)
            } else {
                drag = .create(anchor: point, screen: screen.frame)
                selection = NSRect(origin: point, size: .zero)
            }
        }
    }

    fileprivate func mouseDragged(to point: NSPoint) {
        mouse = point
        guard let drag else { return }
        switch drag {
        case .create(let anchor, let bounds):
            // One display at a time: that's what a capture can cover.
            let p = NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
            selection = NSRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y)).integral
        case .move(let from, let original):
            var moved = original.offsetBy(dx: point.x - from.x, dy: point.y - from.y)
            if let bounds = NSScreen.screens.first(where: { $0.frame.intersects(original) })?.frame {
                moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
            }
            selection = moved.integral
        case .resize(let handle, let original):
            selection = handle.resize(original, to: point).integral
        }
    }

    /// The event being handled, for its modifier keys.
    fileprivate var lastEvent: NSEvent?

    fileprivate func mouseUp(at point: NSPoint) {
        mouse = point
        let copy = Self.controlDown(lastEvent)
        switch mode {
        case .area:
            guard drag != nil else { return }
            drag = nil
            guard let selection, selection.width >= 4, selection.height >= 4 else {
                if !quick { self.selection = nil }
                return
            }
            if quick {
                onPick?(.area(Coordinates.toCG(selection)), copy)
            } else {
                onAreaChange?(selection)
            }
        case .window:
            if let hovered { onPick?(.window(hovered.id), copy) }
        case .screen:
            if let hoveredScreen { onPick?(.display(hoveredScreen.displayID), copy) }
        }
    }

    fileprivate func mouseMoved(to point: NSPoint) {
        mouse = point
        updateHover()
        if mode == .area { redraw() }
    }
}

fileprivate enum Drag {
    case create(anchor: NSPoint, screen: NSRect)
    case move(from: NSPoint, original: NSRect)
    case resize(Handle, NSRect)
}

/// The grab points around an area the toolbar keeps on screen.
fileprivate enum Handle: CaseIterable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

    func point(in r: NSRect) -> NSPoint {
        switch self {
        case .bottomLeft: return NSPoint(x: r.minX, y: r.minY)
        case .bottom: return NSPoint(x: r.midX, y: r.minY)
        case .bottomRight: return NSPoint(x: r.maxX, y: r.minY)
        case .right: return NSPoint(x: r.maxX, y: r.midY)
        case .topRight: return NSPoint(x: r.maxX, y: r.maxY)
        case .top: return NSPoint(x: r.midX, y: r.maxY)
        case .topLeft: return NSPoint(x: r.minX, y: r.maxY)
        case .left: return NSPoint(x: r.minX, y: r.midY)
        }
    }

    static func hit(_ p: NSPoint, in r: NSRect) -> Handle? {
        allCases.first { hypot($0.point(in: r).x - p.x, $0.point(in: r).y - p.y) <= 8 }
    }

    func resize(_ r: NSRect, to p: NSPoint) -> NSRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch self {
        case .bottomLeft: minX = p.x; minY = p.y
        case .bottom: minY = p.y
        case .bottomRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .topRight: maxX = p.x; maxY = p.y
        case .top: maxY = p.y
        case .topLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }
}

private final class OverlayView: NSView {
    unowned let overlay: SelectionOverlay
    let screen: NSScreen

    init(overlay: SelectionOverlay, screen: NSScreen) {
        self.overlay = overlay
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func global(_ event: NSEvent) -> NSPoint {
        NSPoint(x: event.locationInWindow.x + screen.frame.minX, y: event.locationInWindow.y + screen.frame.minY)
    }

    private func local(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    override func mouseDown(with event: NSEvent) { overlay.mouseDown(at: global(event), on: screen) }
    override func mouseDragged(with event: NSEvent) { overlay.mouseDragged(to: global(event)) }
    override func mouseUp(with event: NSEvent) {
        overlay.lastEvent = event
        overlay.mouseUp(at: global(event))
    }
    // ⌃-click can arrive as a right click; here it's a click with ⌃ held.
    override func rightMouseDown(with event: NSEvent) { overlay.mouseDown(at: global(event), on: screen) }
    override func rightMouseDragged(with event: NSEvent) { overlay.mouseDragged(to: global(event)) }
    override func rightMouseUp(with event: NSEvent) {
        overlay.lastEvent = event
        overlay.mouseUp(at: global(event))
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func mouseMoved(with event: NSEvent) {
        overlay.mouseMoved(to: global(event))
        overlay.cursorUpdate()
    }
    override func cursorUpdate(with event: NSEvent) { overlay.cursorUpdate() }
    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        overlay.cursorUpdate()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Not quite clear, so the window server hands every click to us.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        let dim = NSColor.black.withAlphaComponent(0.42)
        switch overlay.mode {
        case .area:
            guard let selection = overlay.selection, selection.intersects(screen.frame) else {
                // Nothing picked yet: the toolbar's kind dims everything, the
                // quick kind shows only the crosshair, like macOS.
                if !overlay.quick {
                    dim.setFill()
                    bounds.fill()
                }
                drawCoordinates()
                return
            }
            let hole = local(selection)
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: hole.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            if !overlay.quick {
                for handle in Handle.allCases {
                    let p = handle.point(in: hole)
                    let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
                    NSColor.white.setFill()
                    dot.fill()
                    NSColor.black.withAlphaComponent(0.35).setStroke()
                    dot.lineWidth = 0.5
                    dot.stroke()
                }
            }
            drawLabel("\(Int(selection.width)) × \(Int(selection.height))",
                      at: NSPoint(x: hole.maxX, y: hole.minY), below: true)
        case .window:
            if let hovered = overlay.hovered, hovered.frame.intersects(screen.frame) {
                let rect = local(hovered.frame)
                NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            }
        case .screen:
            if overlay.hoveredScreen == screen {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                bounds.fill()
                drawLabel("Click to capture this display", at: NSPoint(x: bounds.midX, y: bounds.midY), below: false, centered: true)
            }
        }
    }

    private func drawCoordinates() {
        guard overlay.drag == nil, screen.frame.contains(overlay.mouse) else { return }
        let p = NSPoint(x: overlay.mouse.x - screen.frame.minX, y: overlay.mouse.y - screen.frame.minY)
        // Points from the top left of this display.
        drawLabel("\(Int(p.x)), \(Int(bounds.height - p.y))", at: NSPoint(x: p.x + 14, y: p.y - 14), below: true)
    }

    private func drawLabel(_ text: String, at point: NSPoint, below: Bool, centered: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var box = NSRect(x: point.x - (centered ? size.width / 2 + 6 : size.width + 12), y: below ? point.y - size.height - 10 : point.y,
                         width: size.width + 12, height: size.height + 4)
        // Kept on the display.
        box.origin.x = min(max(box.minX, 4), bounds.maxX - box.width - 4)
        box.origin.y = min(max(box.minY, 4), bounds.maxY - box.height - 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2))
    }
}

/// Cursors for the overlay, and permission to set them while the toolkit is
/// not the active app.
enum CaptureCursor {
    static let camera: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular).applying(.init(paletteColors: [.white]))
        let image = NSImage(size: NSSize(width: 28, height: 24), flipped: false) { rect in
            guard let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return false }
            let r = NSRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                           width: symbol.size.width, height: symbol.size.height)
            // A dark outline so it shows on light and dark windows.
            NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 2, color: NSColor.black.cgColor)
            symbol.draw(in: r)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 14, y: 12))
    }()

    static func allowInBackground() {
        let connection = CGSMainConnectionID()
        CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

/// Lets a background app set the cursor, which overlays need since they
/// don't take the active app away from the window being captured.
@_silgen_name("CGSSetConnectionProperty") @discardableResult
func CGSSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> CGError
