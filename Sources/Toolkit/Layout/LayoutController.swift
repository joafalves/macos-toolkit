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
            if config.gap != oldValue.gap { scheduleGap() }
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
    private let assist = SnapAssist()
    /// Windows sharing a slot as tabs.
    private(set) lazy var tabs = WindowTabs(work: work)
    /// Accessibility calls wait for the other app, so they all happen here,
    /// one at a time and in order.
    private let work = DispatchQueue(label: "dev.jalves.macos-toolkit.layout", qos: .userInitiated)
    /// What we did to each window, for cycling and Restore. Only touched on `work`.
    private var placements: [CGWindowID: Placement] = [:] {
        didSet { savePlacementsSoon() }
    }
    private var placementsSave: DispatchWorkItem?
    private var accessTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var grid: GridSession?
    /// The next `apply` turns macOS's tiling on rather than putting back
    /// what it was.
    private var handBack = false
    private var drag: DragSession?

    private(set) var isPreview = false
    /// For `--snapshot … layout tabs|keyboard`: the page's tab to show.
    static var previewPage: LayoutPage?

    private struct Placement: Codable {
        /// Before the first snap, for Restore and for dragging out.
        var original: CGRect
        /// Where the window ended up, which may not be where it was sent: a
        /// terminal rounds to whole characters. A window found anywhere else
        /// was moved by hand since.
        var applied: CGRect
        var action: LayoutAction?
        /// The fraction of its display, so a move to another display keeps it.
        var unit: CGRect?
        /// Filled by macOS itself, which then also puts it back when it's
        /// dragged away.
        var tiledByMacOS = false
        /// To find the window again, and where its `unit` is, when the gap changes.
        var pid: pid_t = 0
        var display: CGDirectDisplayID?
        /// The same display for good: its number can change when it's
        /// plugged in again, or into another port.
        var displayUUID: String?
        /// Where it was snapped on a display that has gone since, to go back
        /// to when that display comes back.
        var home: Home?

        struct Home: Codable {
            let uuid: String
            let unit: CGRect
        }
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
        /// A window dragged out of its tabs: back in if it's dropped on its slot.
        var leaving: CGWindowID?
        /// Where it was before the drag, or before the snap it was dragged
        /// out of: what Restore goes back to after the drop, not where it
        /// was let go.
        var original: CGRect?
        /// The window it would join as a tab if dropped now.
        var joining: WindowTabs.Member?
        /// The windows it can be stacked with, while the key is held, and the
        /// display they were found on: looked up once per display.
        var stackTargets: [StackTarget] = []
        var stackTargetsOn: CGDirectDisplayID?
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
        assist.onPick = { [weak self] item, slot in self?.suggested(item, into: slot) }
        assist.taken = { [weak self] slot in self?.tabs.occupies(slot) ?? false }

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
        var config = LayoutConfig()
        // The checks measure against frames with no gap, and use stacks.
        config.gap = 0
        config.tabsJoin = .key
        layout.config = config
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
        // Before the first shortcut or drag can act on them.
        let displays = self.displays
        work.async { self.restorePlacements(displays: displays) }
        apply()
    }

    // MARK: - Kept across launches

    /// What's snapped where, in a file, so a restart, an update or a crash
    /// doesn't lose it: Restore, a drag out and a new gap go on working for
    /// windows snapped before.
    private struct SavedPlacements: Codable {
        /// When the Mac started up: a window's number means nothing after a restart.
        let boot: TimeInterval
        let placements: [String: Placement]
    }

    private static var placementsURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("layout-placements.json")
    }

    private static var bootTime: TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(boot.tv_sec)
    }

    /// A second after the last change, on `work`, where `placements` changes.
    private func savePlacementsSoon() {
        guard !isPreview else { return }
        placementsSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Windows closed since have nothing left to keep.
            let open = Self.windows(Array(self.placements.keys))
            let closed = self.placements.keys.filter { open[$0]?.pid != self.placements[$0]?.pid }
            if !closed.isEmpty { closed.forEach { self.placements[$0] = nil } }
            let saved = SavedPlacements(boot: Self.bootTime, placements: Dictionary(uniqueKeysWithValues: self.placements.map { (String($0.key), $0.value) }))
            let url = Self.placementsURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
        placementsSave = save
        work.asyncAfter(deadline: .now() + 1, execute: save)
    }

    /// Those still true: the same window, of the same app, where it was put,
    /// on a display that's still there. One moved meanwhile was moved by
    /// hand, and is left out as it would have been. On `work`.
    private func restorePlacements(displays: [LayoutDisplay]) {
        guard !isPreview, let data = try? Data(contentsOf: Self.placementsURL),
              let saved = try? JSONDecoder().decode(SavedPlacements.self, from: data) else { return }
        guard abs(saved.boot - Self.bootTime) < 2 else {
            LayoutTrace.log("layout: placements from before a restart, left out")
            return
        }
        let found = Self.windows(saved.placements.keys.compactMap { CGWindowID($0) })
        var kept: [CGWindowID: Placement] = [:]
        for (key, var record) in saved.placements {
            guard let id = CGWindowID(key), let window = found[id], window.pid == record.pid, LayoutWindow.close(window.frame, record.applied)
            else { continue }
            // Its display by UUID, in case its number changed; one gone is left out.
            if let uuid = record.displayUUID {
                guard let display = displays.first(where: { $0.uuid == uuid }) else { continue }
                record.display = display.id
            } else if let id = record.display, !displays.contains(where: { $0.id == id }) {
                continue
            }
            kept[id] = record
        }
        // Anything placed since launch is newer.
        placements.merge(kept) { now, _ in now }
        LayoutTrace.log("layout: \(kept.count) of \(saved.placements.count) placements kept from before")
    }

    /// The window server's owner and frame for each of these windows that
    /// still exists.
    private static func windows(_ ids: [CGWindowID]) -> [CGWindowID: (pid: pid_t, frame: CGRect)] {
        guard !ids.isEmpty else { return [:] }
        var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let list = CFArrayCreate(nil, &values, values.count, nil).flatMap { CGWindowListCreateDescriptionFromArray($0) as? [[String: Any]] } ?? []
        var found: [CGWindowID: (pid: pid_t, frame: CGRect)] = [:]
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            found[id] = (pid, frame)
        }
        return found
    }

    /// Displays that went and came. macOS moves a gone display's windows to
    /// the others: the snapped ones are snapped the same way again where
    /// they went, so a left and right pair stays one, and remember where they came
    /// from. When that display is back, they go back to it, if they're still
    /// where they were put (or macOS has put them back there itself). A
    /// display that only got a new number is followed. After a moment, for
    /// macOS to finish moving the windows.
    private func followDisplays(gone: [LayoutDisplay], back: [LayoutDisplay], displays: [LayoutDisplay]) {
        let gap = CGFloat(config.gap)
        let goneUUIDs = Set(gone.map(\.uuid))
        work.asyncAfter(deadline: .now() + 1.5) {
            for (id, record) in self.placements {
                if let uuid = record.displayUUID, let now = displays.first(where: { $0.uuid == uuid }), now.id != record.display {
                    self.placements[id]?.display = now.id
                }
                // Only those with somewhere to go: asking each window costs.
                let leaving = record.displayUUID.map(goneUUIDs.contains) == true && record.unit != nil
                let returning = record.home.map { home in back.contains { $0.uuid == home.uuid } } == true
                guard leaving || returning, let window = LayoutWindow.find(id: id, pid: record.pid), let frame = window.frame else { continue }
                if leaving, let uuid = record.displayUUID, let unit = record.unit,
                   let target = LayoutGeometry.display(of: frame, in: displays) {
                    self.place(window, .unit(unit, target), displays: displays, gap: gap, cycle: false, original: record.original)
                    // The first display it came from, if it has moved on more than once.
                    self.placements[id]?.home = record.home ?? Placement.Home(uuid: uuid, unit: unit)
                    LayoutTrace.log("layout: \(id) followed its display's going, to \(target.name)")
                } else if let home = record.home, let display = back.first(where: { $0.uuid == home.uuid }) {
                    let there = LayoutGeometry.place(home.unit, in: display.usable, gap: gap)
                    guard LayoutWindow.close(frame, record.applied) || LayoutWindow.near(frame, there) else { continue }
                    self.place(window, .unit(home.unit, display), displays: displays, gap: gap, cycle: false, original: record.original)
                    LayoutTrace.log("layout: \(id) back to \(display.name)")
                }
            }
        }
    }

    /// Hands everything back to macOS.
    func stop() {
        // What's waiting to be saved, now: this may be a quit.
        work.sync { placementsSave?.perform() }
        accessTimer?.invalidate()
        accessTimer = nil
        keys.stop()
        drags.stop()
        closeGrid()
        dragOverlay.hide()
        assist.dismiss()
        // Waited for: the app is about to go.
        tabs.dissolveAll(restore: true, waiting: true)
        WindowCatalog.shared.use(self, false)
        SystemTiling.restore()
        SystemTiling.commit()
    }

    private func apply() {
        guard !isPreview else { return }
        let tabbing = config.enabled && config.tabsJoin != .off
        if config.enabled {
            // The tabs' keys only while windows can share a slot.
            var bindings: [(Shortcut, LayoutKeys.Command)] = LayoutAction.allCases.filter { tabbing || !$0.isTabs }.compactMap { action in
                config.shortcut(action).active.map { ($0, .action(action)) }
            }
            if let grid = config.gridShortcut.active { bindings.append((grid, .grid)) }
            if tabbing, let flags = config.tabNumbers.flags {
                let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
                for (index, code) in digits.enumerated() {
                    bindings.append((Shortcut(keyCode: code, flags: flags, key: "\(index + 1)"), .tab(index)))
                }
            }
            keys.start(bindings)
            let failed = keys.failed.map(title)
            if failed != failedShortcuts { failedShortcuts = failed }
        } else {
            keys.stop()
            closeGrid()
            if !failedShortcuts.isEmpty { failedShortcuts = [] }
        }
        let dragTiling = Dictionary(uniqueKeysWithValues: SystemTiling.dragKeys.map { ($0, false) })
        if config.enabled, config.watchesDrags {
            SystemTiling.change(dragTiling)
            startDrags()
        } else {
            drags.stop()
            dragOverlay.hide()
            drag = nil
            accessTimer?.invalidate()
            accessTimer = nil
            if handBack {
                SystemTiling.hand(dragTiling.mapValues { _ in true })
            } else {
                // Also what puts it back after a crash left it off.
                SystemTiling.restore(SystemTiling.dragKeys)
            }
            handBack = false
        }
        // What macOS fills (a double-clicked title bar, ⌃🌐 arrows) gets our
        // gap's worth of margin: none at 0, macOS's own otherwise.
        if config.enabled {
            SystemTiling.change([SystemTiling.marginsKey: config.gap > 0])
        } else {
            SystemTiling.restore([SystemTiling.marginsKey])
        }
        SystemTiling.commit()
        // The suggestions read the switcher's list of windows.
        let suggesting = config.enabled && config.suggest != .off
        WindowCatalog.shared.use(self, suggesting)
        if !suggesting { assist.dismiss() }
        // Turned off: each stack's shown window gets its slot back.
        if !tabbing { tabs.dissolveAll(restore: true) }
        // The gap is applied once the slider stops (`applyGap`), not at every step.
        if tabs.stacks.isEmpty { tabs.gap = CGFloat(config.gap) }
        if tabs.position != config.tabsPosition {
            // tabs.style = config.tabsStyle (only the strip for now: see TabsStyle)
            tabs.position = config.tabsPosition
            tabs.layoutAll()
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
        let old = displays
        if fresh != displays { displays = fresh }
        // By UUID: a display's number can change while it's the same display.
        let gone = old.filter { display in !fresh.contains { $0.uuid == display.uuid } }
        let back = fresh.filter { display in !old.contains { $0.uuid == display.uuid } }
        if !isPreview, !old.isEmpty, !gone.isEmpty || !back.isEmpty || fresh != old {
            followDisplays(gone: gone, back: back, displays: fresh)
        }
        // A grid on a display that went away has nothing left to stand on.
        if let grid, !fresh.contains(grid.display) { closeGrid() }
        tabs.displaysChanged(fresh)
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
        case .grid: return String(localized: "Grid (\(config.gridShortcut.display))")
        case .tab(let index): return String(localized: "Tab \(index + 1)")
        }
    }

    /// The grid this display uses: its own, or one that suits its shape.
    func gridSize(for display: LayoutDisplay) -> GridSize {
        config.grids[display.uuid] ?? GridSize.suggested(for: display.frame.size)
    }

    // MARK: - Shortcuts

    private func handle(_ command: LayoutKeys.Command) {
        switch command {
        case .action(let action) where action.isTabs:
            closeGrid()
            assist.dismiss()
            runTabs(action)
        case .action(.showDesktop):
            closeGrid()
            assist.dismiss()
            if !ShowDesktop.toggle() { Self.beep() }
        case .action(let action):
            closeGrid()
            assist.dismiss()
            run(action)
        case .grid:
            assist.dismiss()
            if grid != nil { closeGrid() } else { openGrid() }
        case .tab(let index):
            closeGrid()
            assist.dismiss()
            withFocusedStack { stack, _ in self.tabs.select(at: index, in: stack) }
        }
    }

    // MARK: - Tabs

    /// The focused window's stack, if it's in one; a beep if not.
    private func withFocusedStack(_ body: @escaping (WindowTabs.Stack, CGWindowID) -> Void) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        work.async {
            guard let window = LayoutWindow.focused(pid: pid) else { return Self.beep() }
            let id = window.id
            DispatchQueue.main.async {
                guard let stack = self.tabs.stack(containing: id) else { return NSSound.beep() }
                body(stack, id)
            }
        }
    }

    private func runTabs(_ action: LayoutAction) {
        switch action {
        case .nextTab: withFocusedStack { stack, _ in self.tabs.step(stack, by: 1) }
        case .previousTab: withFocusedStack { stack, _ in self.tabs.step(stack, by: -1) }
        // It stays where it is, on its own.
        case .takeOutOfTabs: withFocusedStack { _, id in self.tabs.remove(id, raiseNext: false) }
        case .joinTabs: joinUnderFocused()
        default: break
        }
    }

    /// The focused window joins the slot it's over: the first window under
    /// its middle that's in a stack, or that we put in a slot.
    private func joinUnderFocused() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        work.async {
            guard let window = LayoutWindow.focused(pid: pid), let frame = window.frame else { return Self.beep() }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let below = SnapAssist.onScreen().drop { $0.id != window.id }.dropFirst().filter { $0.frame.contains(center) }
            let placed: [CGWindowID: (CGRect, CGDirectDisplayID)] = Dictionary(uniqueKeysWithValues: below.compactMap { other in
                guard let record = self.placements[other.id], let unit = record.unit, let display = record.display,
                      LayoutWindow.close(record.applied, other.frame) else { return nil }
                return (other.id, (unit, display))
            })
            let new = WindowTabs.Member(id: window.id, pid: window.pid)
            DispatchQueue.main.async {
                for other in below {
                    if let stack = self.tabs.stack(containing: other.id), let shown = stack.members.first(where: { $0.id == stack.shown }) {
                        return self.tabs.join(new, unit: stack.unit, display: stack.display, with: shown)
                    }
                    if let (unit, displayID) = placed[other.id], let display = self.displays.first(where: { $0.id == displayID }) {
                        return self.tabs.join(new, unit: unit, display: display, with: WindowTabs.Member(id: other.id, pid: other.pid))
                    }
                }
                NSSound.beep()
            }
        }
    }

    /// The part of a display a target puts a window in, if it's one.
    private static func slot(of target: Target?) -> (CGRect, LayoutDisplay)? {
        switch target {
        case .unit(let unit, let display): return (unit, display)
        case .snap(let action, let display): return LayoutGeometry.unit(for: action, portrait: display.portrait).map { ($0, display) }
        default: return nil
        }
    }

    /// Whether the drag is for stacking: stacks on, and their key held.
    private func wantsTabs(_ flags: CGEventFlags) -> Bool {
        config.tabsJoin == .key && config.tabsKey != .none && flags.contains(config.tabsKey.flag)
    }

    /// A window that can be stacked with: in a stack already, or in sight
    /// filling a part of the display a window can be snapped to.
    struct StackTarget: Equatable {
        let unit: CGRect
        let display: LayoutDisplay
        /// The whole slot, in Core Graphics coordinates.
        let frame: CGRect
        let occupant: WindowTabs.Member
    }

    /// Every window on this display the dragged one could be stacked with.
    func stackTargets(on display: LayoutDisplay, excluding dragged: CGWindowID) -> [StackTarget] {
        let gap = CGFloat(config.gap)
        var targets: [StackTarget] = []
        let own = ProcessInfo.processInfo.processIdentifier
        // Every window counts for covering one, the ones in stacks too.
        let windows = SnapAssist.onScreen().filter { $0.pid != own && $0.id != dragged }
        for stack in tabs.stacks where stack.display.id == display.id {
            // Shown by another of its windows if the shown one is being dragged out.
            guard let occupant = stack.members.first(where: { $0.id == stack.shown && $0.id != dragged }) ?? stack.members.first(where: { $0.id != dragged })
            else { continue }
            // A window snapped over the stack hides it: that window is the one to stack with.
            let slot = tabs.slot(of: stack)
            if let index = windows.firstIndex(where: { $0.id == occupant.id }), windows[..<index].contains(where: { above in
                let overlap = above.frame.intersection(slot)
                return !overlap.isNull && overlap.width * overlap.height > slot.width * slot.height * 0.1
            }) { continue }
            targets.append(StackTarget(unit: stack.unit, display: display, frame: slot, occupant: occupant))
        }
        let stacked = Set(tabs.stacks.flatMap(\.members).map(\.id))
        for unit in Self.slotUnits(on: display, grid: gridSize(for: display)) {
            let slot = LayoutGeometry.place(unit, in: display.usable, gap: gap)
            guard let window = SnapAssist.occupant(of: slot, by: windows, except: []), !stacked.contains(window.id),
                  !targets.contains(where: { $0.occupant.id == window.id }) else { continue }
            targets.append(StackTarget(unit: unit, display: display, frame: slot, occupant: WindowTabs.Member(id: window.id, pid: window.pid)))
        }
        return targets
    }

    /// The parts of a display a window can be snapped to: the shortcuts'
    /// halves, thirds and quarters, the layouts bar's, and the grid's blocks.
    private static func slotUnits(on display: LayoutDisplay, grid: GridSize) -> [CGRect] {
        var units = LayoutAction.allCases.compactMap { LayoutGeometry.unit(for: $0, portrait: display.portrait) }
        for action in [LayoutAction.leftHalf, .rightHalf] {
            units += (1...2).compactMap { LayoutGeometry.unit(for: action, step: $0) }
        }
        units += SlotPicker.layouts(for: display).flatMap { $0 }
        for c0 in 0..<grid.columns {
            for c1 in c0..<grid.columns {
                for r0 in 0..<grid.rows {
                    for r1 in r0..<grid.rows {
                        var range = CellRange(CellRange.Cell(column: c0, row: r0))
                        range.cursor = CellRange.Cell(column: c1, row: r1)
                        units.append(range.unit(in: grid))
                    }
                }
            }
        }
        var unique: [CGRect] = []
        for unit in units where !unique.contains(where: { abs($0.minX - unit.minX) < 0.001 && abs($0.minY - unit.minY) < 0.001 && abs($0.width - unit.width) < 0.001 && abs($0.height - unit.height) < 0.001 }) {
            unique.append(unit)
        }
        return unique
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
    /// `original`: where it was before, when that isn't where it is now:
    /// before the drag that brought it here.
    func place(_ window: LayoutWindow, _ target: Target, displays: [LayoutDisplay], gap: CGFloat, cycle: Bool, afterDrag: Bool = false,
               original: CGRect? = nil) {
        guard let frame = window.frame, let current = LayoutGeometry.display(of: frame, in: displays) else { return Self.beep() }
        // Only counts if the window is still where we put it.
        let record = placements[window.id].flatMap { LayoutWindow.close($0.applied, frame) ? $0 : nil }
        var placement = Placement(original: record?.original ?? original ?? frame, applied: frame, pid: window.pid)
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
                if !(record.tiledByMacOS && window.perform(.untile)) {
                    window.setFrame(record.original, within: current.usable)
                }
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
        // The whole display is our frame too, not macOS's Fill, whatever the
        // gap: Fill only knows macOS's own margin, a window it filled can't be
        // moved to fit ours, and some apps take the command and do nothing.
        // (macOS darkens the menu bar only over a window it filled.)
        guard let actual = window.setFrame(rect, within: display.usable, tiled: record?.tiledByMacOS ?? false, afterDrag: afterDrag) else { return Self.beep() }
        placement.applied = actual
        // Moved by us, it may still be in macOS's tiling, which then puts it
        // back by itself when it's dragged away.
        placement.tiledByMacOS = window.isTiledByMacOS
        placement.display = display.id
        placement.displayUUID = display.uuid
        placements[window.id] = placement
        LayoutTrace.log("layout: placed \(window.id) at \(LayoutTrace.text(rect)): \(LayoutTrace.text(actual)), tiled by macOS \(placement.tiledByMacOS)")
    }

    // MARK: - Gap changes

    private var gapChange: DispatchWorkItem?

    /// Once the slider has stopped: dragging it would move windows at every step.
    private func scheduleGap() {
        gapChange?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyGap() }
        gapChange = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Windows we placed, and that are still there, take the new gap. One
    /// moved since is left alone, and so is one macOS filled: its margins
    /// follow the gap by themselves.
    func applyGap() {
        let displays = self.displays, gap = CGFloat(config.gap)
        if tabs.gap != gap {
            tabs.gap = gap
            tabs.layoutAll()
        }
        work.async {
            // Those in macOS's tiling too, a window it filled among them:
            // sent until macOS lets go of them.
            for (id, record) in self.placements {
                guard let unit = record.unit, let displayID = record.display,
                      let display = displays.first(where: { $0.id == displayID }),
                      let window = LayoutWindow.find(id: id, pid: record.pid), let frame = window.frame,
                      LayoutWindow.close(frame, record.applied),
                      let actual = window.setFrame(LayoutGeometry.place(unit, in: display.usable, gap: gap), within: display.usable,
                                                   tiled: record.tiledByMacOS)
                else { continue }
                self.placements[id]?.applied = actual
            }
        }
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
        var hint = [String(localized: "Type two corners"), String(localized: "←↑↓→ move"), String(localized: "⇧ extends"), String(localized: "↩ place")]
        if displays.count > 1 { hint.append(String(localized: "⇥ next display")) }
        hint.append(String(localized: "esc cancel"))
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
        assist.dismiss()
        drag = DragSession(grab: grab)
        if tabs.stack(containing: grab.id) != nil {
            drag?.leaving = grab.id
            tabs.dragging = grab.id
        }
        // The watcher holds at display edges, on its own thread, from now on.
        drags.holdDisplays.value = config.holdAtEdges ? displays : nil
        watchEscape()
        let restore = config.restoreOnDragOut
        work.async {
            // Snapped when the drag began: where it was when pressed on, before
            // it moved (or macOS, for one it filled, changed its size).
            let before = grab.start ?? grab.frame
            let snappedBefore = self.placements[grab.id].flatMap { LayoutWindow.close($0.applied, before) ? $0.original : nil }
            let original = snappedBefore ?? before
            DispatchQueue.main.async {
                if self.drag?.grab.id == grab.id { self.drag?.original = original }
            }
            guard let window = LayoutWindow.find(id: grab.id, pid: grab.pid) else {
                LayoutTrace.log("layout: window \(grab.id) not one to place")
                DispatchQueue.main.async {
                    guard self.drag?.grab.id == grab.id else { return }
                    self.drag?.eligible = false
                    self.drags.holdDisplays.value = nil
                    self.dragOverlay.hide()
                }
                return
            }
            DispatchQueue.main.async {
                if self.drag?.grab.id == grab.id { self.drag?.eligible = true }
            }
            // A snapped window dragged away gets its old size back, with the
            // pointer at the same place across it, as Rectangle does.
            // A window macOS filled is put back by macOS.
            LayoutTrace.log("layout: drag of \(grab.id), record \(self.placements[grab.id].map { "applied \(LayoutTrace.text($0.applied)), original \(LayoutTrace.text($0.original)), tiled by macOS \($0.tiledByMacOS)" } ?? "none")")
            guard restore, let record = self.placements[grab.id], !record.tiledByMacOS, LayoutWindow.close(record.applied.size, grab.frame.size),
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
        let escape = String(localized: "esc: don't snap")
        if wantsTabs(flags), let display = LayoutGeometry.display(at: point, in: displays) {
            // Stacking: every window it can stack with is outlined; the one
            // under the pointer is where it goes.
            session.anchor = nil
            session.picker = nil
            if session.stackTargetsOn != display.id {
                session.stackTargets = stackTargets(on: display, excluding: session.grab.id)
                session.stackTargetsOn = display.id
            }
            let hit = session.stackTargets.first { $0.frame.contains(point) }
            session.target = hit.map { .unit($0.unit, $0.display) }
            session.joining = hit?.occupant
            content.outlines = session.stackTargets.map(\.frame)
            content.highlight = hit?.frame
            content.joining = hit != nil
            content.hint = session.stackTargets.isEmpty ? String(localized: "No windows here to stack with  ·  \(escape)")
                                                        : String(localized: "Let go over a window to stack with it  ·  \(escape)")
            shownOn = display
        } else if config.dragSlots != .none, flags.contains(config.dragSlots.flag),
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
            content.hint = String(localized: "Let go over a layout  ·  \(escape)")
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
            content.hint = String(localized: "Let go of \(config.dragGrid.title) to start again  ·  \(escape)")
            shownOn = display
        } else {
            session.anchor = nil
            session.picker = nil
            edge()
        }
        if !wantsTabs(flags) {
            session.joining = nil
            session.stackTargetsOn = nil
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
        drags.holdDisplays.value = nil
        LayoutTrace.log("layout: dropped at \(point), session \(drag.map { "eligible \(String(describing: $0.eligible)), cancelled \($0.cancelled), target \(String(describing: $0.target))" } ?? "none")")
        guard let session = drag else { return }
        drag = nil
        tabs.dragging = nil
        let target = session.eligible != false && !session.cancelled ? session.target : nil
        // Out of its tabs, unless it was dropped right back on its slot.
        if let leaving = session.leaving {
            if let stack = tabs.stack(containing: leaving), let (unit, display) = Self.slot(of: target),
               tabs.stack(at: unit, on: display) === stack {
                return tabs.putBack(leaving)
            }
            tabs.remove(leaving, raiseNext: false)
        }
        guard let target else { return }
        let displays = self.displays, gap = CGFloat(config.gap), grab = session.grab
        if let occupant = session.joining, let (unit, display) = Self.slot(of: target) {
            return tabs.join(WindowTabs.Member(id: grab.id, pid: grab.pid), unit: unit, display: display, with: occupant)
        }
        let rest = Self.rest(after: target, picker: session.picker, gap: gap)
        let suggest = config.suggest, from = config.suggestFrom
        // A moment for the app to finish with the drag, or it may put the
        // window back where the mouse left it.
        let original = session.original
        work.asyncAfter(deadline: .now() + 0.03) {
            guard let window = LayoutWindow.find(id: grab.id, pid: grab.pid) else { return }
            self.place(window, target, displays: displays, gap: gap, cycle: false, afterDrag: true, original: original)
        }
        // At once, not after the window has finished moving: the part that's
        // left is known now, and the dropped window isn't offered anyway.
        if suggest != .off, !rest.isEmpty {
            assist.offer(rest, after: grab.id, displays: displays, style: suggest, from: from)
        }
    }

    /// The parts of the display left after a drop, to offer windows for: the
    /// other parts of a layout picked in the ⌥ bar, or what's beside a half
    /// or a third. None for shapes that leave no clean part.
    private static func rest(after target: Target, picker: SlotPicker?, gap: CGFloat) -> [SnapAssist.Slot] {
        func slot(_ unit: CGRect, _ display: LayoutDisplay) -> SnapAssist.Slot {
            SnapAssist.Slot(unit: unit, display: display, frame: LayoutGeometry.place(unit, in: display.usable, gap: gap))
        }
        switch target {
        case .unit(let unit, let display):
            if let picker, let hit = picker.hovered, picker.unit(of: hit) == unit {
                return picker.layouts[hit.layout].enumerated().filter { $0.offset != hit.zone }.map { slot($0.element, display) }
            }
            return LayoutGeometry.complement(of: unit).map { [slot($0, display)] } ?? []
        case .snap(let action, let display):
            guard let unit = LayoutGeometry.unit(for: action, portrait: display.portrait) else { return [] }
            return LayoutGeometry.complement(of: unit).map { [slot($0, display)] } ?? []
        case .action:
            return []
        }
    }

    /// A window picked for the rest of the display: put there, then the next part.
    private func suggested(_ item: SwitcherItem, into slot: SnapAssist.Slot) {
        guard let id = item.window else { return assist.next() }
        let displays = self.displays, gap = CGFloat(config.gap)
        work.async {
            if let window = LayoutWindow.find(id: id, pid: item.pid) {
                self.place(window, .unit(slot.unit, slot.display), displays: displays, gap: gap, cycle: false)
            }
            DispatchQueue.main.async { self.assist.next() }
        }
    }

    private func dragCancelled() {
        if let leaving = drag?.leaving { tabs.recheck(leaving) }
        tabs.dragging = nil
        drag = nil
        drags.holdDisplays.value = nil
        dragOverlay.hide()
        stopWatchingEscape()
    }

    /// Only for as long as a window is moving, so no key is seen otherwise.
    private func watchEscape() {
        guard escMonitors.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape), let self, self.drag != nil else { return }
            self.drag?.cancelled = true
            self.drags.holdDisplays.value = nil
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
