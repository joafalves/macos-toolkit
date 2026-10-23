import AppKit
import ApplicationServices

/// Several windows in one slot, one shown at a time, with tabs to switch.
/// The others wait behind the shown one at the same size, so switching is
/// only bringing one forward. Each member is watched through Accessibility
/// (moved, resized, closed, minimized), and each member's app for which of
/// its windows has focus, so nothing is polled. All of it on the main
/// thread; window moves go to the layout's work queue.
final class WindowTabs {
    struct Member: Equatable {
        let id: CGWindowID
        let pid: pid_t
    }

    final class Stack {
        var unit: CGRect
        var display: LayoutDisplay
        var members: [Member]
        var shown: CGWindowID
        let strip = TabStrip()
        /// Titles and icons, by window, for the tabs.
        var labels: [CGWindowID: TabItem] = [:]

        init(unit: CGRect, display: LayoutDisplay, members: [Member], shown: CGWindowID) {
            self.unit = unit
            self.display = display
            self.members = members
            self.shown = shown
        }

        func contains(_ id: CGWindowID) -> Bool { members.contains { $0.id == id } }
    }

    var style = TabsStyle.strip
    var position = TabsPosition.bottom
    var gap: CGFloat = 8
    /// The window being dragged: its moves are the drag's, not a leaving.
    var dragging: CGWindowID?

    private(set) var stacks: [Stack] = []
    private let work: DispatchQueue
    /// Our own moves, by window, until when: their notifications aren't the user's.
    private var ours: [CGWindowID: Date] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    /// Each watched member's element, and its app.
    private var elements: [CGWindowID: (element: AXUIElement, pid: pid_t)] = [:]
    private var checks: [CGWindowID: DispatchWorkItem] = [:]
    private var activation: NSObjectProtocol?
    private var termination: NSObjectProtocol?
    private var clicks: Any?
    /// Slots given back to a stack's last window a moment ago, still on its
    /// way there: taken, though the window doesn't fill them yet.
    private var restoring: [(frame: CGRect, until: Date)] = []
    private var follows: [DispatchWorkItem] = []
    /// A tab just picked, by stack, until its window has come forward: what's
    /// in front until then is the window it replaces.
    private var picking: [ObjectIdentifier: (id: CGWindowID, until: Date)] = [:]
    /// Raises don't wait behind window moves, which can take a second or two.
    private let raising = DispatchQueue(label: "layout.tabs.raise", qos: .userInteractive)

    private static let windowNotifications = [
        kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
    ]

    init(work: DispatchQueue) {
        self.work = work
        // An app that quits doesn't always say its windows closed.
        termination = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for member in self.stacks.flatMap(\.members) where member.pid == app.processIdentifier {
                self.remove(member.id, raiseNext: true)
            }
        }
        // A click in a stack's window brings it to the front, over a pill
        // (which sits on the window) and with no notification to say so.
        clicks = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self, !self.stacks.isEmpty else { return }
            self.reorderSoon()
        }
        // For a pill: keys can bring a window over it too (⌘`, a new window).
        // clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { [weak self] event in
        //     guard let self, !self.stacks.isEmpty, event.type == .leftMouseUp || self.style == .pill else { return }
        //     self.reorderSoon()
        // }
        // An app coming forward raises its windows over the tabs.
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.appCameForward(app.processIdentifier)
        }
    }

    // MARK: - Finding

    func stack(containing id: CGWindowID) -> Stack? {
        stacks.first { $0.contains(id) }
    }

    func stack(at unit: CGRect, on display: LayoutDisplay) -> Stack? {
        stacks.first { $0.display.id == display.id && Self.same($0.unit, unit) }
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001 && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    func slot(of stack: Stack) -> CGRect {
        LayoutGeometry.place(stack.unit, in: stack.display.usable, gap: gap)
    }

    func memberFrame(of stack: Stack) -> CGRect {
        TabGeometry.member(in: slot(of: stack), style: style, position: position)
    }

    /// Whether a stack has this slot, or its last window is on its way into it.
    func occupies(_ slot: CGRect) -> Bool {
        restoring.removeAll { $0.until < Date() }
        return stacks.contains { LayoutWindow.near(self.slot(of: $0), slot) } || restoring.contains { LayoutWindow.near($0.frame, slot) }
    }

    // MARK: - Joining and leaving

    /// Puts `new` in the slot with `occupant`, the window there now, alone
    /// or the shown one of a stack. `new` is shown.
    func join(_ new: Member, unit: CGRect, display: LayoutDisplay, with occupant: Member) {
        guard new.id != occupant.id else { return }
        if let old = stack(containing: new.id), !old.contains(occupant.id) { remove(new.id, raiseNext: false) }
        let target: Stack
        if let existing = stack(containing: occupant.id) {
            target = existing
            if !target.contains(new.id) { target.members.append(new) }
        } else {
            target = Stack(unit: unit, display: display, members: [occupant, new], shown: new.id)
            target.strip.onSelect = { [weak self, weak target] id in
                guard let self, let target else { return }
                self.select(id, in: target)
            }
            target.strip.onTakeOut = { [weak self] id in self?.remove(id, raiseNext: true) }
            target.strip.onClose = { [weak self] id in self?.close(id) }
            stacks.append(target)
        }
        target.shown = new.id
        for member in target.members { watch(member) }
        layout(target, raising: new)
    }

    /// Takes a window out; it stays where it is. If that leaves one window,
    /// the tabs go and that one gets the whole slot back.
    func remove(_ id: CGWindowID, raiseNext: Bool) {
        guard let stack = stack(containing: id) else { return }
        stack.members.removeAll { $0.id == id }
        unwatch(id)
        if stack.members.count <= 1 {
            dissolve(stack, restore: true)
            return
        }
        if stack.shown == id, let next = stack.members.first {
            stack.shown = next.id
            if raiseNext { raise(next) }
        }
        refresh(stack)
    }

    /// The tabs go away; every window left in it gets the whole slot.
    /// `waiting`: done before this returns, for a quit.
    private func dissolve(_ stack: Stack, restore: Bool, waiting: Bool = false) {
        stack.strip.hide()
        stacks.removeAll { $0 === stack }
        for member in stack.members { unwatch(member.id) }
        guard restore, !stack.members.isEmpty else { return }
        let frame = slot(of: stack), area = stack.display.usable, members = stack.members
        restoring.append((frame, Date().addingTimeInterval(2)))
        for member in members { ours[member.id] = Date().addingTimeInterval(1.5) }
        let grow = {
            for member in members { LayoutWindow.find(id: member.id, pid: member.pid)?.setFrame(frame, within: area) }
        }
        if waiting { work.sync(execute: grow) } else { work.async(execute: grow) }
    }

    func dissolveAll(restore: Bool, waiting: Bool = false) {
        for stack in stacks { dissolve(stack, restore: restore, waiting: waiting) }
    }

    /// Shows one of the stack's windows.
    func select(_ id: CGWindowID, in stack: Stack) {
        guard let member = stack.members.first(where: { $0.id == id }) else { return }
        stack.shown = id
        picking[ObjectIdentifier(stack)] = (id, Date().addingTimeInterval(1))
        refresh(stack)
        raise(member) { [weak self] in
            guard let self else { return }
            self.picking[ObjectIdentifier(stack)] = nil
            self.refresh(stack)
            self.followFront()
        }
    }

    /// The tab after (or before) the shown one, or the one at `index`.
    func step(_ stack: Stack, by delta: Int) {
        guard let index = stack.members.firstIndex(where: { $0.id == stack.shown }) else { return }
        let count = stack.members.count
        select(stack.members[(index + delta + count) % count].id, in: stack)
    }

    func select(at index: Int, in stack: Stack) {
        guard stack.members.indices.contains(index) else { return NSSound.beep() }
        select(stack.members[index].id, in: stack)
    }

    /// A window dragged out and dropped back on its slot: back in its place.
    func putBack(_ id: CGWindowID) {
        guard let stack = stack(containing: id), let member = stack.members.first(where: { $0.id == id }) else { return }
        stack.shown = id
        layout(stack, raising: member)
    }

    private func close(_ id: CGWindowID) {
        guard let stack = stack(containing: id), let member = stack.members.first(where: { $0.id == id }) else { return }
        work.async {
            guard case .other(let window, _, _, _) = LayoutWindow.find(id: member.id, pid: member.pid),
                  let button: AXUIElement = LayoutWindow.attribute(window, kAXCloseButtonAttribute) else { return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    // MARK: - Laying out

    /// Every window to the slot's window frame, then the tabs above the shown
    /// one. `raising` comes forward: the window just dropped in.
    func layout(_ stack: Stack, raising: Member?) {
        let frame = memberFrame(of: stack), area = stack.display.usable
        let until = Date().addingTimeInterval(3)
        for member in stack.members { ours[member.id] = until }
        if let raising { picking[ObjectIdentifier(stack)] = (raising.id, until) }
        // The one coming in first, and patiently: macOS may still be finishing
        // its drag. The others are in the slot already and only change size.
        let members = (raising.map { [$0] } ?? []) + stack.members.filter { $0 != raising }
        work.async {
            var labels: [CGWindowID: TabItem] = [:]
            for member in members {
                guard let window = LayoutWindow.find(id: member.id, pid: member.pid) else { continue }
                window.setFrame(frame, within: area, afterDrag: member == raising)
                labels[member.id] = Self.label(member, window)
            }
            DispatchQueue.main.async {
                // Done moving them: a move from here on is someone else's,
                // after the notifications of the last of ours have come in.
                let settled = Date().addingTimeInterval(0.5)
                for member in members where (self.ours[member.id] ?? .distantPast) > settled { self.ours[member.id] = settled }
                stack.labels.merge(labels) { _, new in new }
                self.refresh(stack)
                guard let raising else { return }
                self.raise(raising) { [weak self] in
                    guard let self else { return }
                    self.picking[ObjectIdentifier(stack)] = nil
                    self.refresh(stack)
                    self.followFront()
                }
            }
        }
    }

    /// All of them again, for a new gap, style or place of the tabs.
    func layoutAll() {
        for stack in stacks { layout(stack, raising: nil) }
    }

    /// The tabs as they are now, right above the shown window.
    func refresh(_ stack: Stack) {
        guard stacks.contains(where: { $0 === stack }) else { return }
        let model = stack.strip.model
        let items = stack.members.map { stack.labels[$0.id] ?? TabItem(id: $0.id, title: "", appName: "", icon: Self.icon($0.pid)) }
        // Only what changed: each change draws the tabs again.
        if model.style != style { model.style = style }
        if model.tabs != items { model.tabs = items }
        if model.shown != stack.shown { model.shown = stack.shown }
        place(stack)
        // The app brings the window forward a moment later; the tabs follow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak stack] in
            guard let self, let stack, self.stacks.contains(where: { $0 === stack }) else { return }
            self.place(stack)
        }
    }

    /// The tabs where they go now. `onScreen`: the windows front to back, if already known.
    private func place(_ stack: Stack, onScreen: [WindowSuggestions.OnScreen]? = nil) {
        let frame = TabGeometry.tabs(in: slot(of: stack), style: style, position: position, count: stack.members.count)
        stack.strip.show(at: frame, above: stack.shown)
        // For a pill (see TabsStyle):
        // let pill = style == .pill
        // let inSight = pill && Self.inSight(stack, at: frame, onScreen: onScreen ?? WindowSuggestions.onScreen(),
        //                                    strips: Set(stacks.map { CGWindowID($0.strip.windowNumber) }))
        // stack.strip.show(at: frame, above: stack.shown, floating: pill, inSight: inSight)
    }

    /// Whether the stack's window shows at `frame`: it's on screen (not on
    /// another Space, not hidden), and no other window is in front of it
    /// there. Its own stack's windows don't count: one of them may still be
    /// in front for a moment while the one picked comes forward.
    private static func inSight(_ stack: Stack, at frame: CGRect, onScreen: [WindowSuggestions.OnScreen], strips: Set<CGWindowID>) -> Bool {
        guard let index = onScreen.firstIndex(where: { $0.id == stack.shown }) else { return false }
        return !onScreen[..<index].contains { !strips.contains($0.id) && !stack.contains($0.id) && $0.frame.intersects(frame) }
    }

    func displaysChanged(_ displays: [LayoutDisplay]) {
        for stack in stacks {
            guard let display = displays.first(where: { $0.id == stack.display.id }) else {
                dissolve(stack, restore: false)
                continue
            }
            if display != stack.display {
                stack.display = display
                layout(stack, raising: nil)
            }
        }
    }

    private func raise(_ member: Member, then done: (() -> Void)? = nil) {
        raising.async {
            LayoutWindow.find(id: member.id, pid: member.pid)?.raise()
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    /// Each stack's tabs placed again for the windows as they are now.
    private func reorder() {
        guard !stacks.isEmpty else { return }
        let onScreen = WindowSuggestions.onScreen()
        for stack in stacks { place(stack, onScreen: onScreen) }
    }

    private var reordering: DispatchWorkItem?

    /// After the window server has the click's or key's result; once for a burst of keys.
    private func reorderSoon() {
        reordering?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reorder() }
        reordering = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private static func label(_ member: Member, _ window: LayoutWindow) -> TabItem {
        let app = NSRunningApplication(processIdentifier: member.pid)
        var title = ""
        if case .other(let element, _, _, _) = window { title = LayoutWindow.attribute(element, kAXTitleAttribute) ?? "" }
        return TabItem(id: member.id, title: title, appName: app?.localizedName ?? "", icon: app?.icon)
    }

    private static func icon(_ pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    // MARK: - Watching

    private func watch(_ member: Member) {
        guard elements[member.id] == nil else { return }
        let observer: AXObserver
        if let existing = observers[member.pid] {
            observer = existing
        } else {
            var created: AXObserver?
            let callback: AXObserverCallback = { _, element, notification, context in
                guard let context else { return }
                Unmanaged<WindowTabs>.fromOpaque(context).takeUnretainedValue().notified(element, notification as String)
            }
            guard AXObserverCreate(member.pid, callback, &created) == .success, let created else { return }
            observer = created
            observers[member.pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            let context = Unmanaged.passUnretained(self).toOpaque()
            work.async {
                AXObserverAddNotification(observer, AXUIElementCreateApplication(member.pid), kAXFocusedWindowChangedNotification as CFString, context)
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        work.async {
            guard case .other(let element, _, _, _) = LayoutWindow.find(id: member.id, pid: member.pid) else { return }
            for name in Self.windowNotifications { AXObserverAddNotification(observer, element, name as CFString, context) }
            DispatchQueue.main.async { self.elements[member.id] = (element, member.pid) }
        }
    }

    private func unwatch(_ id: CGWindowID) {
        checks[id]?.cancel()
        checks[id] = nil
        guard let (element, pid) = elements.removeValue(forKey: id) else { return }
        if let observer = observers[pid] {
            work.async {
                for name in Self.windowNotifications { AXObserverRemoveNotification(observer, element, name as CFString) }
            }
        }
        // An app with no member left needs no watching.
        let pids = Set(stacks.flatMap(\.members).map(\.pid))
        for (pid, observer) in observers where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = nil
        }
    }

    private func notified(_ element: AXUIElement, _ notification: String) {
        if notification == kAXFocusedWindowChangedNotification {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            focusChanged(in: pid)
            return
        }
        // A closed window no longer knows its ID, so match the element.
        guard let id = elements.first(where: { CFEqual($0.value.element, element) })?.key else { return }
        switch notification {
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            remove(id, raiseNext: true)
        default:
            // Moved or resized. Ours, or the drag's, are expected; anything
            // else is checked once it has settled.
            if dragging == id { return }
            if let until = ours[id], until > Date() { return }
            checks[id]?.cancel()
            let check = DispatchWorkItem { [weak self] in self?.checkStillThere(id) }
            checks[id] = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: check)
        }
    }

    /// After a drag that was lost track of: still where it belongs?
    func recheck(_ id: CGWindowID) {
        checkStillThere(id)
    }

    /// Resized or moved by hand, so it no longer fits: out of the tabs.
    private func checkStillThere(_ id: CGWindowID) {
        checks[id] = nil
        guard let stack = stack(containing: id), let member = stack.members.first(where: { $0.id == id }), dragging != id else { return }
        let expected = memberFrame(of: stack)
        work.async {
            let frame = LayoutWindow.find(id: member.id, pid: member.pid)?.frame
            DispatchQueue.main.async {
                guard let frame, !LayoutWindow.near(frame, expected) else { return }
                // Snapped into its own slot again (or put back there by
                // macOS): still in the stack, at the stack's size.
                if self.stacks.contains(where: { $0 === stack }), LayoutWindow.near(frame, self.slot(of: stack)) {
                    return self.layout(stack, raising: nil)
                }
                self.remove(id, raiseNext: false)
            }
        }
    }

    /// One of the app's windows got focus: it may be a member, now in front.
    private func focusChanged(in pid: pid_t) {
        guard stacks.contains(where: { $0.members.contains { $0.pid == pid } }) else { return }
        followFront()
    }

    private func appCameForward(_ pid: pid_t) {
        for stack in stacks where stack.members.contains(where: { $0.pid == pid }) {
            refresh(stack)
        }
        focusChanged(in: pid)
    }

    /// The shown tab is the member in front, whatever put it there. Not the
    /// app's focused window: that can lag behind a raise, and an app brought
    /// forward (⌘Tab, the Dock) raises all its windows, the hidden members
    /// too, while its focused one may be elsewhere. Looked at once the
    /// window server has the new order, and again a little later.
    private func followFront() {
        follows.forEach { $0.cancel() }
        follows = [0.25, 0.7].map { delay in
            let item = DispatchWorkItem { [weak self] in self?.showFront() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func showFront() {
        guard !stacks.isEmpty else { return }
        let order = WindowSuggestions.onScreen().map(\.id)
        // A member being dragged out is in front for now; its stack waits for the drop.
        picking = picking.filter { $0.value.until > Date() }
        for stack in stacks where !(dragging.map(stack.contains) ?? false) && picking[ObjectIdentifier(stack)] == nil {
            guard let front = order.first(where: stack.contains), front != stack.shown else { continue }
            stack.shown = front
            refresh(stack)
        }
        // Raised without a change of tab, it may be over the strip's spot now.
        reorder()
    }
}
