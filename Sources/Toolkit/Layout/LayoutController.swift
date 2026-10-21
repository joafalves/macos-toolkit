import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Places windows: Rectangle-style shortcuts, a grid picked with the keyboard
/// (or the mouse), and snapping when a window is dragged to an edge or, with
/// a modifier held, onto the grid.
final class LayoutController: ObservableObject {
    @Published var config: LayoutConfig {
        didSet {
            guard config != oldValue, !isPreview else { return }
            config.save()
            // Switched off by hand (not at launch, nor by a quit): macOS's
            // own tiling takes over.
            if oldValue.enabled && oldValue.watchesDrags, !(config.enabled && config.watchesDrags) { handBack = true }
            apply()
        }
    }

    /// Accessibility is granted but macOS still refused the event tap; this
    /// happens when the grant predates the running process.
    @Published private(set) var tapFailed = false
    /// Shortcuts macOS refused, usually because another app has them.
    @Published private(set) var failedShortcuts: [String] = []
    /// Rectangle has the same default shortcuts and its own snapping.
    @Published private(set) var rectangleRunning = false
    /// Left to right. Made-up ones in a preview.
    @Published private(set) var displays: [LayoutDisplay] = []

    private let keys = LayoutKeys()
    private let drags = DragWatcher()
    private let gridOverlay = LayoutOverlay()
    private let dragOverlay = LayoutOverlay()
    /// Accessibility calls wait for the other app, so they all happen here,
    /// one at a time and in order.
    private let work = DispatchQueue(label: "dev.jalves.macos-toolkit.layout", qos: .userInitiated)
    /// What we did to each window, for cycling and Restore. Only touched on `work`.
    private var placements: [CGWindowID: Placement] = [:]
    private var accessTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var grid: GridSession?
    /// The next `apply` turns macOS's tiling on rather than putting back
    /// what it was.
    private var handBack = false
    private var drag: DragSession?

    private(set) var isPreview = false

    private struct Placement {
        /// Before the first snap, for Restore and for dragging out.
        var original: CGRect
        /// Where the window ended up, which may not be where it was sent: a
        /// terminal rounds to whole characters. A window found anywhere else
        /// was moved by hand since.
        var applied: CGRect
        var action: LayoutAction?
        /// The fraction of its display, so a move to another display keeps it.
        var unit: CGRect?
    }

    enum Target: Equatable {
        /// A shortcut: halves cycle when pressed again.
        case action(LayoutAction)
        /// Dropped against an edge: the same as the action, without cycling.
        case snap(LayoutAction, LayoutDisplay)
        /// Grid cells.
        case unit(CGRect, LayoutDisplay)
    }

    private struct GridSession {
        let window: LayoutWindow
        let title: String
        var display: LayoutDisplay
        var size: GridSize
        var range: CellRange
        var pending = false
        var labels: [Int: String]
    }

    private struct DragSession {
        let grab: DragWatcher.Grab
        /// Unknown until the window has been looked up, false for one that
        /// can't be placed (a panel, a dialog).
        var eligible: Bool?
        var target: Target?
        var anchor: (display: String, cell: CellRange.Cell)?
        /// Stays where it appeared until the key is let go.
        var picker: SlotPicker?
        /// Esc was pressed: this drag snaps nowhere.
        var cancelled = false
    }

    /// Esc while a window is dragged, from other apps and from ours.
    private var escMonitors: [Any] = []

    init() {
        config = LayoutConfig.load()
        keys.onCommand = { [weak self] command in self?.handle(command) }
        gridOverlay.onKey = { [weak self] event in self?.gridKey(event) ?? false }
        gridOverlay.onCells = { [weak self] range, done in self?.gridCells(range, done: done) }
        gridOverlay.onCancel = { [weak self] in self?.closeGrid() }
        drags.onStart = { [weak self] grab in self?.dragStarted(grab) }
        drags.onMove = { [weak self] point, flags in self?.dragMoved(point, flags) }
        drags.onDrop = { [weak self] point, flags in self?.dropped(point, flags) }
        drags.onCancel = { [weak self] in self?.dragCancelled() }
        drags.holdDisplays = { [weak self] in
            guard let self, self.config.holdAtEdges, let session = self.drag, session.eligible != false, !session.cancelled else { return nil }
            return self.displays
        }
    }

    static func preview() -> LayoutController {
        let layout = LayoutController()
        layout.isPreview = true
        layout.config = LayoutConfig()
        layout.displays = [
            LayoutDisplay(id: 1, uuid: "preview-1", name: "Built-in Display",
                          frame: CGRect(x: 0, y: 0, width: 1512, height: 982), usable: CGRect(x: 0, y: 33, width: 1512, height: 949)),
            LayoutDisplay(id: 2, uuid: "preview-2", name: "Wide Display",
                          frame: CGRect(x: 1512, y: 0, width: 3440, height: 1440), usable: CGRect(x: 1512, y: 25, width: 3440, height: 1415)),
        ]
        return layout
    }

    /// For `--test-layout`: the real displays and default settings, with
    /// nothing read, written or registered.
    static func testing() -> LayoutController {
        let layout = LayoutController()
        layout.isPreview = true
        layout.config = LayoutConfig()
        layout.refreshDisplays()
        return layout
    }

    // MARK: - Lifecycle

    func start() {
        refreshDisplays()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplays()
        })
        observers.append(center.addObserver(forName: ShortcutRecording.changed, object: nil, queue: .main) { [weak self] _ in
            self?.keys.suspend(ShortcutRecording.active)
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshRectangle()
            })
        }
        refreshRectangle()
        apply()
    }

    /// Hands everything back to macOS.
    func stop() {
        accessTimer?.invalidate()
        accessTimer = nil
        keys.stop()
        drags.stop()
        closeGrid()
        dragOverlay.hide()
        SystemTiling.restore()
    }

    private func apply() {
        guard !isPreview else { return }
        if config.enabled {
            var bindings: [(Shortcut, LayoutKeys.Command)] = LayoutAction.allCases.compactMap { action in
                config.shortcut(action).active.map { ($0, .action(action)) }
            }
            if let grid = config.gridShortcut.active { bindings.append((grid, .grid)) }
            keys.start(bindings)
            let failed = keys.failed.map(title)
            if failed != failedShortcuts { failedShortcuts = failed }
        } else {
            keys.stop()
            closeGrid()
            if !failedShortcuts.isEmpty { failedShortcuts = [] }
        }
        if config.enabled, config.watchesDrags {
            SystemTiling.disable()
            startDrags()
        } else {
            drags.stop()
            dragOverlay.hide()
            drag = nil
            accessTimer?.invalidate()
            accessTimer = nil
            if handBack {
                SystemTiling.enable()
            } else {
                // Also what puts it back after a crash left it off.
                SystemTiling.restore()
            }
            handBack = false
        }
    }

    /// The drag tap needs Accessibility, which may be granted after launch;
    /// until it's running, this checks again every few seconds.
    private func startDrags() {
        if (!drags.isRunning || drags.active != config.holdAtEdges), AXIsProcessTrusted() {
            let started = drags.start(active: config.holdAtEdges)
            NSLog("Toolkit: layout drag tap started = \(started)")
            if tapFailed == started { tapFailed = !started }
        }
        if drags.isRunning || tapFailed {
            accessTimer?.invalidate()
            accessTimer = nil
        } else if accessTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.startDrags() }
            RunLoop.main.add(timer, forMode: .common)
            accessTimer = timer
        }
    }

    private func refreshDisplays() {
        let fresh = LayoutDisplay.all()
        if fresh != displays { displays = fresh }
        // A grid on a display that went away has nothing left to stand on.
        if let grid, !fresh.contains(grid.display) { closeGrid() }
    }

    private static let rectangleIDs = ["com.knollsoft.Rectangle", "com.knollsoft.Hookshot"]

    private func refreshRectangle() {
        let running = NSWorkspace.shared.runningApplications.contains { Self.rectangleIDs.contains($0.bundleIdentifier ?? "") }
        if running != rectangleRunning { rectangleRunning = running }
    }

    /// Registers the shortcuts afresh, for after another app let go of them.
    func retryShortcuts() {
        keys.stop()
        apply()
    }

    func quitRectangle() {
        for app in NSWorkspace.shared.runningApplications where Self.rectangleIDs.contains(app.bundleIdentifier ?? "") {
            app.terminate()
        }
    }

    private func title(_ command: LayoutKeys.Command) -> String {
        switch command {
        case .action(let action): return "\(action.title) (\(config.shortcut(action).display))"
        case .grid: return "Grid (\(config.gridShortcut.display))"
        }
    }

    /// The grid this display uses: its own, or one that suits its shape.
    func gridSize(for display: LayoutDisplay) -> GridSize {
        config.grids[display.uuid] ?? GridSize.suggested(for: display.frame.size)
    }

    // MARK: - Shortcuts

    private func handle(_ command: LayoutKeys.Command) {
        switch command {
        case .action(let action):
            closeGrid()
            run(action)
        case .grid:
            if grid != nil { closeGrid() } else { openGrid() }
        }
    }

    private func run(_ action: LayoutAction) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let displays = self.displays, gap = CGFloat(config.gap), cycle = config.cycleAtEdge
        work.async {
            guard let window = LayoutWindow.focused(pid: pid) else { return Self.beep() }
            self.place(window, .action(action), displays: displays, gap: gap, cycle: cycle)
        }
    }

    private static func beep() {
        DispatchQueue.main.async { NSSound.beep() }
    }

    // MARK: - Placing (on `work`, or the main thread in the self-test)

    /// `cycle`: at the outer edge, left and right go on through ⅔ and ⅓.
    func place(_ window: LayoutWindow, _ target: Target, displays: [LayoutDisplay], gap: CGFloat, cycle: Bool) {
        guard let frame = window.frame, let current = LayoutGeometry.display(of: frame, in: displays) else { return Self.beep() }
        if placements.count > 500 { placements.removeAll() }
        // Only counts if the window is still where we put it.
        let record = placements[window.id].flatMap { LayoutWindow.close($0.applied, frame) ? $0 : nil }
        var placement = Placement(original: record?.original ?? frame, applied: frame)
        var display = current
        let rect: CGRect

        func fill(_ unit: CGRect, on target: LayoutDisplay) -> CGRect {
            placement.unit = unit
            display = target
            return LayoutGeometry.place(unit, in: target.usable, gap: gap)
        }
        /// Whether the window is at this part of its display now: put there by
        /// us (a window with a minimum size may only be near it), or close
        /// enough by its frame, which also catches one placed by hand or by
        /// another app.
        func at(_ unit: CGRect) -> Bool {
            if let record, record.unit == unit { return true }
            return LayoutWindow.near(frame, LayoutGeometry.place(unit, in: current.usable, gap: gap))
        }
        /// The usable area less the outer gap: as far as a window may reach.
        func inner(_ d: LayoutDisplay) -> CGRect { d.usable.insetBy(dx: gap, dy: gap) }

        switch target {
        case .unit(let unit, let target):
            rect = fill(unit, on: target)
        case .snap(let action, let target):
            placement.action = action
            rect = fill(LayoutGeometry.unit(for: action, portrait: target.portrait) ?? CGRect(x: 0, y: 0, width: 1, height: 1), on: target)
        case .action(let action):
            placement.action = action
            switch action {
            case .restore:
                guard let record else { return Self.beep() }
                window.setFrame(record.original, within: current.usable)
                placements[window.id] = nil
                return
            case .center:
                let area = inner(current)
                let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
                rect = CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
            case .larger, .smaller:
                let d = action == .larger ? -LayoutGeometry.step : LayoutGeometry.step
                var grown = frame.insetBy(dx: d, dy: d)
                if action == .smaller, grown.width < 200 || grown.height < 120 { return Self.beep() }
                grown = grown.intersection(inner(current))
                rect = grown.isNull ? frame : grown
            case .maximizeHeight:
                let area = inner(current)
                rect = CGRect(x: frame.minX, y: area.minY, width: frame.width, height: area.height)
            case .previousDisplay, .nextDisplay:
                guard displays.count > 1, let index = displays.firstIndex(of: current) else { return Self.beep() }
                let next = displays[(index + (action == .nextDisplay ? 1 : -1) + displays.count) % displays.count]
                if let record, let unit = record.unit {
                    // A snapped window stays snapped the same way.
                    placement.action = record.action
                    rect = fill(unit, on: next)
                } else {
                    // Otherwise the same place, relative to the display, at the same size if it fits.
                    let from = current.usable, area = inner(next)
                    let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
                    let x = area.minX + (frame.midX - from.minX) / from.width * area.width - size.width / 2
                    let y = area.minY + (frame.midY - from.minY) / from.height * area.height - size.height / 2
                    rect = CGRect(x: min(max(x, area.minX), area.maxX - size.width).rounded(),
                                  y: min(max(y, area.minY), area.maxY - size.height).rounded(),
                                  width: size.width, height: size.height)
                    display = next
                }
            case .topHalf, .bottomHalf:
                // Goes by where the window is, however it got there. Up:
                // top half, then the whole display, then the display above,
                // still maximized. Down: bottom half, then the top half of the
                // display below. Maximizing only ever happens going up.
                let full = CGRect(x: 0, y: 0, width: 1, height: 1)
                let top = LayoutGeometry.unit(for: .topHalf)!, bottom = LayoutGeometry.unit(for: .bottomHalf)!
                if action == .topHalf {
                    if at(full) {
                        guard let above = LayoutGeometry.neighbour(of: current, .up, in: displays) else { return Self.beep() }
                        placement.action = .maximize
                        rect = fill(full, on: above)
                    } else if at(top) {
                        placement.action = .maximize
                        rect = fill(full, on: current)
                    } else {
                        rect = fill(top, on: current)
                    }
                } else if at(bottom) {
                    guard let below = LayoutGeometry.neighbour(of: current, .down, in: displays) else { return Self.beep() }
                    placement.action = .topHalf
                    rect = fill(top, on: below)
                } else {
                    rect = fill(bottom, on: current)
                }
            case .leftHalf, .rightHalf:
                // A trip across the displays: to this side's half, then on
                // to the display that way as its near half. At the outer edge
                // it stops, or with `cycle` goes on through ⅔ and ⅓. A window
                // at any of those sizes against the edge counts as there.
                let sizes = (0..<3).compactMap { LayoutGeometry.unit(for: action, step: $0) }
                if let index = sizes.firstIndex(where: { at($0) }) {
                    if let (direction, opposite) = LayoutGeometry.hop(for: action),
                       let next = LayoutGeometry.neighbour(of: current, direction, in: displays),
                       let unit = LayoutGeometry.unit(for: opposite) {
                        placement.action = opposite
                        rect = fill(unit, on: next)
                    } else if cycle {
                        rect = fill(sizes[(index + 1) % sizes.count], on: current)
                    } else {
                        return Self.beep()
                    }
                } else {
                    rect = fill(sizes[0], on: current)
                }
            default:
                guard let unit = LayoutGeometry.unit(for: action, portrait: current.portrait) else { return }
                rect = fill(unit, on: current)
            }
        }
        guard let actual = window.setFrame(rect, within: display.usable) else { return Self.beep() }
        placement.applied = actual
        placements[window.id] = placement
    }

    // MARK: - Grid

    private func openGrid() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        work.async {
            guard let window = LayoutWindow.focused(pid: pid), let frame = window.frame else { return Self.beep() }
            let title = window.title
            DispatchQueue.main.async { self.beginGrid(window, title: title, frame: frame) }
        }
    }

    /// Starts on the cell under the middle of the window.
    func beginGrid(_ window: LayoutWindow, title: String, frame: CGRect) {
        guard let display = LayoutGeometry.display(of: frame, in: displays) else { return }
        let size = gridSize(for: display)
        let cell = Self.cell(at: CGPoint(x: frame.midX, y: frame.midY), on: display, in: size)
        grid = GridSession(window: window, title: title, display: display, size: size, range: CellRange(cell),
                           labels: GridKeys.labels(for: size))
        showGrid()
    }

    var gridIsOpen: Bool { grid != nil }

    private static func cell(at point: CGPoint, on display: LayoutDisplay, in size: GridSize) -> CellRange.Cell {
        let u = display.usable
        let unit = CGPoint(x: min(max((point.x - u.minX) / u.width, 0), 0.999), y: min(max((point.y - u.minY) / u.height, 0), 0.999))
        return CellRange.cell(at: unit, in: size)
    }

    private func showGrid() {
        guard let grid else { return }
        var hint = ["Type two corners", "←↑↓→ move", "⇧ extends", "↩ place"]
        if displays.count > 1 { hint.append("⇥ next display") }
        hint.append("esc cancel")
        let unit = grid.range.unit(in: grid.size)
        gridOverlay.content = LayoutOverlayContent(
            grid: grid.size, selection: grid.range, pending: grid.pending,
            highlight: LayoutGeometry.place(unit, in: grid.display.usable, gap: CGFloat(config.gap)),
            labels: grid.labels, dim: 0.45, title: grid.title, hint: hint.joined(separator: "  ·  "), gap: CGFloat(config.gap))
        gridOverlay.show(on: grid.display, interactive: true)
    }

    private func closeGrid() {
        grid = nil
        if gridOverlay.isVisible { gridOverlay.hide() }
    }

    func gridKey(_ event: NSEvent) -> Bool {
        guard var session = grid else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let code = Int(event.keyCode)
        let arrows: [Int: (Int, Int)] = [kVK_LeftArrow: (-1, 0), kVK_RightArrow: (1, 0), kVK_UpArrow: (0, -1), kVK_DownArrow: (0, 1)]
        switch code {
        case kVK_Escape:
            closeGrid()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            placeGrid()
            return true
        case kVK_Tab:
            guard displays.count > 1, let index = displays.firstIndex(of: session.display) else { return true }
            let next = displays[(index + (shift ? -1 : 1) + displays.count) % displays.count]
            // The same part of the screen, in the other display's grid.
            let unit = session.range.unit(in: session.size)
            let size = gridSize(for: next)
            let center = CGPoint(x: next.usable.minX + unit.midX * next.usable.width, y: next.usable.minY + unit.midY * next.usable.height)
            session.display = next
            session.size = size
            session.range = CellRange(Self.cell(at: center, on: next, in: size))
            session.labels = GridKeys.labels(for: size)
            session.pending = false
        case kVK_Delete:
            session.range = CellRange(session.range.cursor)
            session.pending = false
        default:
            if let (dx, dy) = arrows[code] {
                session.range.cursor = CellRange.Cell(column: session.range.cursor.column + dx, row: session.range.cursor.row + dy).clamped(to: session.size)
                // Plain arrows move a single cell; with ⇧, or after a first
                // corner was typed, they move the far corner.
                if !shift, !session.pending { session.range.anchor = session.range.cursor }
            } else if let cell = GridKeys.cell(for: code, in: session.size) {
                if session.pending {
                    session.range.cursor = cell
                    grid = session
                    placeGrid()
                    return true
                }
                session.range = CellRange(cell)
                session.pending = true
            } else {
                NSSound.beep()
                return true
            }
        }
        grid = session
        showGrid()
        return true
    }

    private func gridCells(_ range: CellRange, done: Bool) {
        guard var session = grid else { return }
        session.range = range
        session.pending = false
        grid = session
        if done { placeGrid() } else { showGrid() }
    }

    private func placeGrid() {
        guard let session = grid else { return }
        closeGrid()
        let unit = session.range.unit(in: session.size)
        let displays = self.displays, gap = CGFloat(config.gap)
        work.async {
            self.place(session.window, .unit(unit, session.display), displays: displays, gap: gap, cycle: false)
        }
    }

    // MARK: - Dragging

    func dragStarted(_ grab: DragWatcher.Grab) {
        drag = DragSession(grab: grab)
        watchEscape()
        let restore = config.restoreOnDragOut
        work.async {
            guard let window = LayoutWindow.find(id: grab.id, pid: grab.pid) else {
                DispatchQueue.main.async {
                    guard self.drag?.grab.id == grab.id else { return }
                    self.drag?.eligible = false
                    self.dragOverlay.hide()
                }
                return
            }
            DispatchQueue.main.async {
                if self.drag?.grab.id == grab.id { self.drag?.eligible = true }
            }
            // A snapped window dragged away gets its old size back, with the
            // pointer at the same place across it, as Rectangle does.
            guard restore, let record = self.placements[grab.id], LayoutWindow.close(record.applied.size, grab.frame.size),
                  let frame = window.frame, let pointer = CGEvent(source: nil)?.location
            else { return }
            self.placements[grab.id] = nil
            self.restoreUnderPointer(window, size: record.original.size, grab: grab, frame: frame, pointer: pointer)
        }
    }

    /// Back to `size` with the same spot of the window under the pointer:
    /// as far down from its top, and as far across, as when the drag was
    /// noticed. The pointer keeps moving while the app resizes, and some
    /// apps round the size, so it goes by the pointer and the size as they
    /// are afterwards, and checks again until the window is where it should
    /// be. On `work`.
    func restoreUnderPointer(_ window: LayoutWindow, size: CGSize, grab: DragWatcher.Grab, frame: CGRect, pointer: CGPoint,
                             current: () -> CGPoint? = { CGEvent(source: nil)?.location }) {
        let grabbed = grab.pointer ?? pointer
        let grabFrame = grab.pointer == nil ? frame : grab.frame
        let across = grabFrame.width > 0 ? min(max((grabbed.x - grabFrame.minX) / grabFrame.width, 0), 1) : 0.5
        let down = max(min(grabbed.y - grabFrame.minY, size.height - 1), 0)
        func wanted(_ width: CGFloat, _ pointer: CGPoint) -> CGPoint {
            CGPoint(x: (pointer.x - across * width).rounded(), y: (pointer.y - down).rounded())
        }
        window.setSize(size, origin: wanted(size.width, current() ?? pointer))
        for _ in 0..<4 {
            guard let now = window.frame, let pointer = current() else { return }
            let target = wanted(now.width, pointer)
            if abs(now.minX - target.x) <= 2, abs(now.minY - target.y) <= 2 { return }
            window.setPosition(target)
            usleep(8_000)
        }
    }

    func dragMoved(_ point: CGPoint, _ flags: CGEventFlags) {
        guard var session = drag, session.eligible != false, !session.cancelled else { return }
        let gap = CGFloat(config.gap)
        var content = LayoutOverlayContent(gap: gap)
        var shownOn: LayoutDisplay?
        func edge() {
            if config.edgeSnapping, let (display, action) = LayoutGeometry.edgeZone(at: point, in: displays),
               let unit = LayoutGeometry.unit(for: action, portrait: display.portrait) {
                session.target = .snap(action, display)
                content.highlight = LayoutGeometry.place(unit, in: display.usable, gap: gap)
                shownOn = display
            } else {
                session.target = nil
            }
        }
        let escape = "esc: don't snap"
        if config.dragSlots != .none, flags.contains(config.dragSlots.flag),
           let display = LayoutGeometry.display(at: point, in: displays) {
            session.anchor = nil
            // Where the pointer is when the key goes down; on another display, it starts again there.
            if session.picker?.display != display.id { session.picker = SlotPicker(display: display, pointer: point) }
            var picker = session.picker!
            picker.hovered = picker.hit(point)
            if let hit = picker.hovered {
                let unit = picker.unit(of: hit)
                session.target = .unit(unit, display)
                content.highlight = LayoutGeometry.place(unit, in: display.usable, gap: gap)
            } else {
                edge()
                // The edge's preview only if it's on the picker's display.
                if shownOn != display { content.highlight = nil }
            }
            session.picker = picker
            content.picker = picker
            content.hint = "Let go over a layout  ·  \(escape)"
            shownOn = display
        } else if config.dragGrid != .none, flags.contains(config.dragGrid.flag),
           let display = LayoutGeometry.display(at: point, in: displays) {
            session.picker = nil
            let size = gridSize(for: display)
            let cell = Self.cell(at: point, on: display, in: size)
            // Where the pointer was when the key went down is one corner.
            if session.anchor?.display != display.uuid { session.anchor = (display.uuid, cell) }
            var range = CellRange(session.anchor?.cell ?? cell)
            range.cursor = cell
            let unit = range.unit(in: size)
            session.target = .unit(unit, display)
            content.grid = size
            content.selection = range
            content.dim = 0.15
            content.highlight = LayoutGeometry.place(unit, in: display.usable, gap: gap)
            content.hint = "Let go of \(config.dragGrid.title) to start again  ·  \(escape)"
            shownOn = display
        } else {
            session.anchor = nil
            session.picker = nil
            edge()
        }
        drag = session
        guard let shownOn else { return dragOverlay.hide() }
        dragOverlay.content = content
        dragOverlay.show(on: shownOn, interactive: false)
    }

    func dropped(_ point: CGPoint, _ flags: CGEventFlags) {
        dragMoved(point, flags)
        dragOverlay.hide()
        stopWatchingEscape()
        guard let session = drag else { return }
        drag = nil
        guard session.eligible != false, !session.cancelled, let target = session.target else { return }
        let displays = self.displays, gap = CGFloat(config.gap), grab = session.grab
        // A moment for the app to finish with the drag, or it may put the
        // window back where the mouse left it.
        work.asyncAfter(deadline: .now() + 0.03) {
            guard let window = LayoutWindow.find(id: grab.id, pid: grab.pid) else { return }
            self.place(window, target, displays: displays, gap: gap, cycle: false)
        }
    }

    private func dragCancelled() {
        drag = nil
        dragOverlay.hide()
        stopWatchingEscape()
    }

    /// Only for as long as a window is moving, so no key is seen otherwise.
    private func watchEscape() {
        guard escMonitors.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape), let self, self.drag != nil else { return }
            self.drag?.cancelled = true
            self.drag?.target = nil
            self.drags.release()
            self.dragOverlay.hide()
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handle) { escMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handle($0); return $0 }) { escMonitors.append(monitor) }
    }

    private func stopWatchingEscape() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors.removeAll()
    }
}

extension LayoutDisplay {
    var portrait: Bool { frame.height > frame.width }
}
