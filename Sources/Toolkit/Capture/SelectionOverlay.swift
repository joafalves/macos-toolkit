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
    fileprivate var hovered: Candidate? {
        didSet { if hovered?.id != oldValue?.id { highlight.show(hovered) } }
    }
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
    private var moveMonitors: [Any] = []
    private var candidates: [Candidate] = []
    private let highlight = WindowHighlight()

    var isVisible: Bool { !windows.isEmpty }
    var windowNumbers: Set<CGWindowID> { Set(windows.compactMap(\.windowID)) }

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
        // Moves over the toolbar may go to the toolbar or to us, depending on
        // macOS; either way the cursor is decided in one place.
        let follow: (NSEvent) -> Void = { [weak self] _ in self?.cursorUpdate() }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { follow($0); return $0 }) {
            moveMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: follow) {
            moveMonitors.append(global)
        }
    }

    func hide() {
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors.removeAll()
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
            return Candidate(id: id, frame: Coordinates.toAppKit(rect), layer: layer)
        }
    }

    fileprivate func updateHover() {
        hoveredScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
        guard mode == .window else { hovered = nil; return }
        // Front to back, so the first hit is the one on top.
        let hit = candidates.first { $0.frame.contains(mouse) }
        if hit?.id != hovered?.id { hovered = hit }
    }

    fileprivate func redraw() {
        windows.forEach { ($0.contentView as? OverlayView)?.update() }
    }

    /// The crosshair (or camera) over the overlay, the arrow over anything
    /// above it, like the toolbar or a menu.
    fileprivate func cursorUpdate() {
        guard !windows.isEmpty else { return }
        let top = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard windows.contains(where: { $0.windowNumber == top }) else { return NSCursor.arrow.set() }
        areaCursor().set()
    }

    /// Over an area kept on screen: a resize cursor on its knobs, a hand
    /// inside it (closed while moving it), the crosshair elsewhere.
    private func areaCursor() -> NSCursor {
        guard mode == .area else { return mode == .window ? CaptureCursor.camera : .crosshair }
        switch drag {
        case .resize(let handle, _): return handle.cursor
        case .move: return .closedHand
        case .create: return .crosshair
        case nil: break
        }
        guard !quick, let selection else { return .crosshair }
        // Where the pointer is now: some cursor updates come before the move
        // that caused them has been recorded, and a stale point picked the
        // old cursor until the next move or click.
        let point = NSEvent.mouseLocation
        if let handle = Handle.hit(point, in: selection) { return handle.cursor }
        return selection.contains(point) ? .openHand : .crosshair
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
        // Pressing on a knob or inside the area changes the cursor at once.
        defer { cursorUpdate() }
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
        defer { cursorUpdate() }
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

struct Candidate {
    let id: CGWindowID
    /// In AppKit global coordinates.
    let frame: NSRect
    let layer: Int
}

/// The tint over the window under the mouse. The overlay sits above every
/// window, so a tint drawn there would cover the windows in front of this one
/// too. As a window of its own, ordered just above the one it marks, the
/// windows in front cover it the way they cover that window.
final class WindowHighlight {
    private var panel: CapturePanel?

    func show(_ candidate: Candidate?) {
        guard let candidate else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? make()
        self.panel = panel
        panel.level = NSWindow.Level(rawValue: candidate.layer)
        panel.setFrame(candidate.frame, display: true)
        panel.order(.above, relativeTo: Int(candidate.id))
    }

    private func make() -> CapturePanel {
        let panel = CapturePanel(frame: .zero, level: .normal)
        panel.ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        view.layer?.cornerRadius = 10
        panel.contentView = view
        return panel
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

    /// macOS's own cursor for resizing from this side or corner.
    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch self {
        case .bottomLeft: position = .bottomLeft
        case .bottom: position = .bottom
        case .bottomRight: position = .bottomRight
        case .right: position = .right
        case .topRight: position = .topRight
        case .top: position = .top
        case .topLeft: position = .topLeft
        case .left: position = .left
        }
        return .frameResize(position: position, directions: .all)
    }

    static func hit(_ p: NSPoint, in r: NSRect) -> Handle? {
        allCases.first { hypot($0.point(in: r).x - p.x, $0.point(in: r).y - p.y) <= 10 }
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
        // Layers, not drawing: a layer that's only colour and border needs no
        // picture behind it. Drawn, each display's overlay held a picture of
        // the whole display, close to 100 MB across two. Set before asking for
        // layers, so the view hosts this one and never draws.
        layer = CALayer()
        wantsLayer = true
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

    /// Not quite clear, so the window server hands every click to us.
    static let base = NSColor.black.withAlphaComponent(0.01)

    func update() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.sublayers = nil
        root.backgroundColor = Self.base.cgColor
        let dim = NSColor.black.withAlphaComponent(0.42)
        switch overlay.mode {
        case .area:
            guard let selection = overlay.selection, selection.intersects(screen.frame) else {
                // Nothing picked yet: the toolbar's kind dims everything, the
                // quick kind shows only the crosshair, like macOS.
                if !overlay.quick { box(bounds, fill: dim) }
                coordinates()
                return
            }
            let hole = local(selection)
            // The dim around the area, as four pieces: one piece with a hole
            // in it would need a picture of its own.
            let open = hole.intersection(bounds)
            box(NSRect(x: 0, y: open.maxY, width: bounds.width, height: bounds.maxY - open.maxY), fill: dim)
            box(NSRect(x: 0, y: 0, width: bounds.width, height: open.minY), fill: dim)
            box(NSRect(x: 0, y: open.minY, width: open.minX, height: open.height), fill: dim)
            box(NSRect(x: open.maxX, y: open.minY, width: bounds.maxX - open.maxX, height: open.height), fill: dim)
            // A crisp white edge, with a faint dark one outside it so it shows
            // on light and dark content alike.
            box(hole.insetBy(dx: -2, dy: -2), stroke: NSColor.black.withAlphaComponent(0.25))
            box(hole.insetBy(dx: -1, dy: -1), stroke: NSColor.white.withAlphaComponent(0.95))
            if !overlay.quick {
                for handle in Handle.allCases { knob(handle, at: handle.point(in: hole)) }
            }
            size("\(Int(selection.width)) × \(Int(selection.height))", under: hole)
        case .window:
            // The highlight is a window of its own, in among the others.
            break
        case .screen:
            if overlay.hoveredScreen == screen {
                box(bounds, fill: NSColor.controlAccentColor.withAlphaComponent(0.18))
                label(String(localized: "Click to capture this display"), at: NSPoint(x: bounds.midX, y: bounds.midY), below: false, centered: true)
            }
        }
    }

    /// A white dot at a corner, a short pill along an edge, lifted by a soft shadow.
    private func knob(_ handle: Handle, at p: NSPoint) {
        let size: NSSize
        switch handle {
        case .top, .bottom: size = NSSize(width: 22, height: 6)
        case .left, .right: size = NSSize(width: 6, height: 22)
        default: size = NSSize(width: 10, height: 10)
        }
        let rect = NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        guard let knob = box(rect, fill: .white, stroke: NSColor.black.withAlphaComponent(0.15), width: 0.5, radius: min(size.width, size.height) / 2)
        else { return }
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.35
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        // Given, so the shadow isn't worked out from the layer's pixels each frame.
        knob.shadowPath = CGPath(roundedRect: knob.bounds, cornerWidth: knob.cornerRadius, cornerHeight: knob.cornerRadius, transform: nil)
    }

    /// The area's size in a pill just under its bottom right corner, or inside
    /// it when there's no room below.
    private func size(_ text: String, under hole: NSRect) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        var frame = NSRect(x: hole.maxX - size.width - 20, y: hole.minY - size.height - 16, width: size.width + 20, height: size.height + 8)
        if frame.minY < 4 { frame.origin.y = hole.minY + 10 }
        frame.origin.x = min(max(frame.minX, 4), bounds.maxX - frame.width - 4)
        box(frame, fill: NSColor.black.withAlphaComponent(0.7), stroke: NSColor.white.withAlphaComponent(0.15), radius: frame.height / 2)
        self.text(string, at: NSPoint(x: frame.minX + 10, y: frame.minY + 4), size: size)
    }

    private func text(_ string: NSAttributedString, at origin: NSPoint, size: NSSize) {
        let text = CATextLayer()
        text.string = string
        text.contentsScale = screen.backingScaleFactor
        text.frame = NSRect(origin: origin, size: size)
        layer?.addSublayer(text)
    }

    @discardableResult
    private func box(_ rect: NSRect, fill: NSColor? = nil, stroke: NSColor? = nil, width: CGFloat = 1, radius: CGFloat = 0) -> CALayer? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let box = CALayer()
        box.frame = rect
        box.backgroundColor = fill?.cgColor
        box.borderColor = stroke?.cgColor
        box.borderWidth = stroke == nil ? 0 : width
        box.cornerRadius = radius
        layer?.addSublayer(box)
        return box
    }

    private func coordinates() {
        guard overlay.drag == nil, screen.frame.contains(overlay.mouse) else { return }
        let p = NSPoint(x: overlay.mouse.x - screen.frame.minX, y: overlay.mouse.y - screen.frame.minY)
        // Points from the top left of this display.
        label("\(Int(p.x)), \(Int(bounds.height - p.y))", at: NSPoint(x: p.x + 14, y: p.y - 14), below: true)
    }

    private func label(_ text: String, at point: NSPoint, below: Bool, centered: Bool = false) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        var frame = NSRect(x: point.x - (centered ? size.width / 2 + 6 : size.width + 12), y: below ? point.y - size.height - 10 : point.y,
                           width: size.width + 12, height: size.height + 4)
        // Kept on the display.
        frame.origin.x = min(max(frame.minX, 4), bounds.maxX - frame.width - 4)
        frame.origin.y = min(max(frame.minY, 4), bounds.maxY - frame.height - 4)
        box(frame, fill: NSColor.black.withAlphaComponent(0.6), radius: 5)
        self.text(string, at: NSPoint(x: frame.minX + 6, y: frame.minY + 2), size: size)
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
