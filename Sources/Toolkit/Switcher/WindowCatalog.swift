import AppKit
import ApplicationServices

/// A row in the switcher: one window, or an app that has no window to show.
struct SwitcherItem: Identifiable {
    enum State {
        case window, minimized, hiddenApp, noWindows
    }

    let id: String
    /// Nil for the rows that stand for a whole app.
    let window: CGWindowID?
    let pid: pid_t
    var title: String
    var appName: String
    var icon: NSImage?
    var state: State
    var dimmed: Bool { state != .window }
}

/// Keeps an up-to-date list of every window of every app, in most recently
/// used order, so the switcher can open without asking anyone anything.
///
/// Accessibility calls block until the other app answers, so they are only
/// ever made on `work`; the results come back to the main thread.
final class WindowCatalog {
    private struct Entry {
        let id: CGWindowID
        let element: AXUIElement
        let pid: pid_t
        var title: String
        var minimized: Bool
        /// Position on `clock` when the window last had focus; 0 if never seen focused.
        var lastUsed: UInt64 = 0
    }

    private final class Watch {
        let app: NSRunningApplication
        let element: AXUIElement
        let observer: AXObserver
        lazy var icon = app.icon

        init(app: NSRunningApplication, observer: AXObserver) {
            self.app = app
            self.element = AXUIElementCreateApplication(app.processIdentifier)
            self.observer = observer
        }
    }

    /// Called on the main thread when a window appears, goes away or changes.
    var onChange: () -> Void = {}

    private var entries: [CGWindowID: Entry] = [:]
    private var watches: [pid_t: Watch] = [:]
    private var clock: UInt64 = 0
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// `lastUsed` for the toolkit's own window, which has no entry.
    private var ownLastUsed: UInt64 = 0
    private var tokens: [NSObjectProtocol] = []
    private var trustTimer: Timer?
    private let work = DispatchQueue(label: "dev.jalves.macos-toolkit.windows", qos: .userInitiated, attributes: .concurrent)

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification, kAXTitleChangedNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    // MARK: - Lifecycle

    /// One list for every tool that needs it (the switcher, Window Layout's
    /// suggestions), watched while any of them does.
    static let shared = WindowCatalog()
    private var users = Set<ObjectIdentifier>()

    func use(_ user: AnyObject, _ on: Bool) {
        let id = ObjectIdentifier(user)
        if on {
            guard users.insert(id).inserted else { return }
            if users.count == 1 { start() }
        } else {
            guard users.remove(id) != nil else { return }
            if users.isEmpty { stop() }
        }
    }

    func start() {
        guard tokens.isEmpty else { return }
        // Without Accessibility no app answers, and one given up on isn't
        // tried again: Window Layout's suggestions start this at launch, so
        // a grant made later left the switcher with an empty list.
        guard AXIsProcessTrusted() else { return waitForAccess() }
        // An app that has hung should cost us a moment, not the default six seconds.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping (NSRunningApplication?) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                handler(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            if let app { self?.watch(app) }
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            if let app { self?.unwatch(app.processIdentifier) }
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            // Also the moment apps that started out without a Dock icon get picked up.
            guard let self, let app else { return }
            if app.processIdentifier == self.ownPID { self.touchOwn() }
            self.watch(app)
            if let watch = self.watches[app.processIdentifier] { self.scan(watch, deep: false) }
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] _ in self?.onChange() }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] _ in self?.onChange() }
        // Windows that could not be found from another Space are found once we are on theirs.
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            for watch in self.watches.values { self.scan(watch, deep: false) }
        }

        for app in NSWorkspace.shared.runningApplications { watch(app) }
        // Started late (Accessibility granted with our window in front): its
        // activation came before anything was listening.
        if NSApp.isActive { touchOwn() }
    }

    /// Checks every couple of seconds, only while nothing can be listed.
    private func waitForAccess() {
        guard trustTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted() else { return }
            timer.invalidate()
            self.trustTimer = nil
            if !self.users.isEmpty { self.start() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens = []
        for pid in Array(watches.keys) { unwatch(pid) }
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, pid != ownPID, app.activationPolicy == .regular, watches[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue().handle(element, notification as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let watch = Watch(app: app, observer: observer)
        watches[pid] = watch
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        attach(watch, attempt: 0)
        onChange()
    }

    private func unwatch(_ pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes)
        entries = entries.filter { $0.value.pid != pid }
        onChange()
    }

    /// Subscribes to the app's window events, then lists its windows. An app
    /// that is still launching does not answer yet, so this keeps trying.
    private func attach(_ watch: Watch, attempt: Int) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        work.async {
            let results = Self.appNotifications.map {
                AXObserverAddNotification(watch.observer, watch.element, $0 as CFString, context)
            }
            let ready = results.contains { $0 == .success || $0 == .notificationAlreadyRegistered }
            DispatchQueue.main.asyncAfter(deadline: .now() + (ready ? 0 : 1)) {
                guard self.watches[watch.app.processIdentifier] === watch else { return }
                if ready {
                    self.scan(watch, deep: true)
                } else if attempt < 10 {
                    self.attach(watch, attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Discovery

    /// Lists an app's windows. `deep` also digs out the ones on other Spaces,
    /// which is slow and only needed once per app.
    private func scan(_ watch: Watch, deep: Bool) {
        let pid = watch.app.processIdentifier
        let known = Set(entries.keys)
        work.async {
            // Doubles as the check that the app is answering at all.
            guard var elements: [AXUIElement] = Self.attribute(watch.element, kAXWindowsAttribute) else { return }
            if deep {
                // Only what the window server says is missing: most apps have
                // nothing on other Spaces, and the search stops once it's found.
                let here = Set(elements.compactMap { element -> CGWindowID? in
                    var id: CGWindowID = 0
                    return _AXUIElementGetWindow(element, &id) == .success ? id : nil
                })
                let missing = Self.windowIDs(of: pid).subtracting(here)
                if !missing.isEmpty { elements += Self.windowsOnOtherSpaces(of: pid, looking: missing) }
            }
            var seen = Set<CGWindowID>()
            let found = elements.compactMap { Self.read($0, pid: pid) }.filter { seen.insert($0.id).inserted }
            for entry in found where !known.contains(entry.id) { self.observe(entry.element, with: watch) }
            let focused = Self.focusedWindow(of: watch.element)
            DispatchQueue.main.async {
                guard self.watches[pid] === watch else { return }
                found.forEach(self.upsert)
                if let focused, watch.app.isActive { self.touch(focused) }
            }
        }
    }

    private func handle(_ element: AXUIElement, _ notification: String) {
        if notification == kAXUIElementDestroyedNotification {
            // A dead element no longer knows its window ID, so match the element itself.
            guard let id = entries.first(where: { CFEqual($0.value.element, element) })?.key else { return }
            entries[id] = nil
            onChange()
            return
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let watch = watches[pid] else { return }
        let focus = notification == kAXFocusedWindowChangedNotification || notification == kAXMainWindowChangedNotification
        let known = Set(entries.keys)
        work.async {
            guard let entry = Self.read(element, pid: pid) else { return }
            if !known.contains(entry.id) { self.observe(entry.element, with: watch) }
            DispatchQueue.main.async {
                guard self.watches[pid] === watch else { return }
                self.upsert(entry)
                if focus, watch.app.isActive { self.touch(entry.id) }
            }
        }
    }

    private func observe(_ window: AXUIElement, with watch: Watch) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(watch.observer, window, name as CFString, context)
        }
    }

    private func upsert(_ fresh: Entry) {
        if var entry = entries[fresh.id] {
            guard entry.title != fresh.title || entry.minimized != fresh.minimized else { return }
            entry.title = fresh.title
            entry.minimized = fresh.minimized
            entries[fresh.id] = entry
        } else {
            entries[fresh.id] = fresh
        }
        onChange()
    }

    private func touch(_ id: CGWindowID) {
        clock += 1
        entries[id]?.lastUsed = clock
    }

    private func touchOwn() {
        clock += 1
        ownLastUsed = clock
    }

    // MARK: - Reading windows (off the main thread)

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        // Casts to these always succeed in Swift, whatever the app sent back.
        if T.self == AXUIElement.self, CFGetTypeID(value) != AXUIElementGetTypeID() { return nil }
        if T.self == AXValue.self, CFGetTypeID(value) != AXValueGetTypeID() { return nil }
        return value as? T
    }

    /// Nil for anything that is not a real window: sheets, popovers, tooltips, menus.
    private static func read(_ element: AXUIElement, pid: pid_t) -> Entry? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0,
              let subrole: String = attribute(element, kAXSubroleAttribute),
              subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        else { return nil }
        return Entry(id: id, element: element, pid: pid,
                     title: attribute(element, kAXTitleAttribute) ?? "",
                     minimized: attribute(element, kAXMinimizedAttribute) ?? false)
    }

    private static func focusedWindow(of app: AXUIElement) -> CGWindowID? {
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    /// An app only lists the windows on the current Space. Its other windows
    /// can still be addressed directly by element ID, so try the low IDs,
    /// which is where windows live.
    /// How many elements have been tried in the search for windows on other
    /// Spaces, for `--list-windows`.
    static let probes = Tally()

    /// The app's windows on any Space, as the window server knows them. At any
    /// level: some apps' floating panels are windows the switcher lists too.
    private static func windowIDs(of pid: pid_t) -> Set<CGWindowID> {
        let all = windowsOnAllSpaces()
        guard !all.isEmpty else { return [] }
        // An array of the IDs themselves, not of objects.
        var values = all.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return [] }
        return Set(list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }

    /// Windows of the app that only these IDs, on other Spaces, are missing.
    /// Some of them may not be windows Accessibility knows (a helper the app
    /// keeps off screen), in which case the search goes the whole way.
    private static func windowsOnOtherSpaces(of pid: pid_t, looking missing: Set<CGWindowID>) -> [AXUIElement] {
        var missing = missing
        // Token layout: pid (4 bytes), zero (4), 'coco' (4), element ID (8).
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        var found: [AXUIElement] = []
        for id in UInt64(0)..<1000 {
            probes.add(1)
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue(),
                  let subrole: String = attribute(element, kAXSubroleAttribute),
                  subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            else { continue }
            found.append(element)
            var window: CGWindowID = 0
            if _AXUIElementGetWindow(element, &window) == .success { missing.remove(window) }
            if missing.isEmpty { break }
        }
        return found
    }

    // MARK: - The list

    /// Where these windows are, as the window server has them: on any Space,
    /// and where a minimized one was.
    static func frames(of ids: [CGWindowID]) -> [CGWindowID: CGRect] {
        guard !ids.isEmpty else { return [:] }
        var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return [:] }
        var frames: [CGWindowID: CGRect] = [:]
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            frames[id] = rect
        }
        return frames
    }

    /// Every row for the switcher: windows in most recently used order, then
    /// minimized windows, then apps that are hidden or have no window.
    /// `currentFirst` says whether the first row is the window being used now.
    func snapshot() -> (items: [SwitcherItem], currentFirst: Bool) {
        func listed(_ app: NSRunningApplication) -> Bool {
            !app.isTerminated && app.activationPolicy == .regular
        }
        // Background tabs are windows too, but belong to no Space.
        let onSpaces = Self.windowsOnAllSpaces()
        var windows = entries.values.filter { entry in
            guard let app = watches[entry.pid]?.app, listed(app), !app.isHidden else { return false }
            return onSpaces.isEmpty || onSpaces.contains(entry.id)
        }
        let unseen = Self.invisible(windows.filter { !$0.minimized }.map(\.id))
        windows.removeAll { unseen.contains($0.id) }
        // Until a window has been seen in use, its place in the stack is the best guess.
        let stack = windows.contains { $0.lastUsed == 0 } || ownLastUsed == 0 ? Self.stackingOrder() : [:]
        windows.sort { a, b in
            if a.minimized != b.minimized { return b.minimized }
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            let (za, zb) = (stack[a.id] ?? .max, stack[b.id] ?? .max)
            return za != zb ? za < zb : a.id < b.id
        }

        var items = windows.map { entry in
            let watch = watches[entry.pid]
            let name = watch?.app.localizedName ?? ""
            return SwitcherItem(id: "w\(entry.id)", window: entry.id, pid: entry.pid,
                                title: entry.title.isEmpty ? name : entry.title, appName: name,
                                icon: watch?.icon, state: entry.minimized ? .minimized : .window)
        }
        let withWindows = Set(windows.map(\.pid))
        for app in NSWorkspace.shared.runningApplications {
            guard let watch = watches[app.processIdentifier], listed(app), app.isHidden || !withWindows.contains(app.processIdentifier)
            else { continue }
            let name = app.localizedName ?? ""
            items.append(SwitcherItem(id: "a\(app.processIdentifier)", window: nil, pid: app.processIdentifier,
                                      title: name, appName: name, icon: watch.icon,
                                      state: app.isHidden ? .hiddenApp : .noWindows))
        }

        if let own = ownItem() {
            if own.state == .window {
                let index: Int
                if ownLastUsed > 0 {
                    index = windows.firstIndex { $0.minimized || $0.lastUsed < ownLastUsed } ?? windows.count
                } else {
                    // Not seen in use since the list started: by its place in
                    // the stack, as the others not seen yet, rather than last.
                    let z = own.window.flatMap { stack[$0] } ?? .max
                    index = windows.firstIndex { $0.minimized || ($0.lastUsed == 0 && (stack[$0.id] ?? .max) > z) } ?? windows.count
                }
                items.insert(own, at: index)
            } else {
                items.append(own)
            }
        }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentFirst = items.first.map { $0.state == .window && $0.pid == front } ?? false
        return (items, currentFirst)
    }

    /// The toolkit's own window. Accessibility calls to our own process run on
    /// the calling thread, where AppKit refuses them, so it is listed and
    /// focused without them, as a row for the whole app. It carries its window
    /// ID only so the grid can show a picture of it: having no entry here, it
    /// is still switched to as an app.
    private func ownItem() -> SwitcherItem? {
        guard NSApp.activationPolicy() == .regular,
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized || NSApp.isHidden) })
        else { return nil }
        let app = NSRunningApplication.current
        return SwitcherItem(id: "a\(ownPID)", window: window.windowID, pid: ownPID, title: window.title,
                            appName: app.localizedName ?? "", icon: app.icon,
                            state: NSApp.isHidden ? .hiddenApp : window.isMiniaturized ? .minimized : .window)
    }

    private func app(_ pid: pid_t) -> NSRunningApplication? {
        pid == ownPID ? .current : watches[pid]?.app
    }

    /// IDs of the windows on any Space, including minimized ones. Empty if
    /// the lookup stops working, in which case nothing is filtered.
    private static func windowsOnAllSpaces() -> Set<CGWindowID> {
        let connection = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] ?? []
        let spaces = displays.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }.compactMap { $0["id64"] as? Int }
        guard !spaces.isEmpty else { return [] }
        var setTags = 0, clearTags = 0
        // 7: also windows that are minimized or belong to all Spaces.
        let ids = CGSCopyWindowsWithOptionsAndTags(connection, 0, spaces as CFArray, 7, &setTags, &clearTags)
        return Set(ids as? [CGWindowID] ?? [])
    }

    /// Windows an app reports that nobody can see: fully transparent, a few
    /// points across, or hidden without being minimized. Some apps (Electron
    /// and Java ones among them) keep such windows for themselves, and listed
    /// they're rows that switch to nothing. Pass only windows that aren't minimized.
    private static func invisible(_ ids: [CGWindowID]) -> Set<CGWindowID> {
        guard !ids.isEmpty else { return [] }
        let pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = pointers.withUnsafeBufferPointer { CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), $0.count, nil) }
        let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []

        // Hidden: on a Space shown now, yet not drawn. A window on another
        // Space isn't on a current one, so it stays. Stage Manager keeps the
        // windows of other stages out of sight in its own way, so not there.
        var hiddenOnCurrent: Set<CGWindowID> = []
        if !(UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false) {
            let connection = CGSMainConnectionID()
            let displays = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] ?? []
            let current = displays.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? Int }
            if !current.isEmpty {
                var setTags = 0, clearTags = 0
                // 1: minimized and hidden windows too; 0: only those drawn.
                let all = CGSCopyWindowsWithOptionsAndTags(connection, 0, current as CFArray, 1, &setTags, &clearTags) as? [CGWindowID] ?? []
                let drawn = CGSCopyWindowsWithOptionsAndTags(connection, 0, current as CFArray, 0, &setTags, &clearTags) as? [CGWindowID] ?? []
                if !drawn.isEmpty { hiddenOnCurrent = Set(all).subtracting(drawn) }
            }
        }

        var unseen: Set<CGWindowID> = []
        for description in descriptions {
            guard let id = description[kCGWindowNumber as String] as? CGWindowID else { continue }
            let alpha = description[kCGWindowAlpha as String] as? Double ?? 1
            let bounds = description[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let tiny = (bounds["Width"] ?? 100) < 24 || (bounds["Height"] ?? 100) < 24
            if alpha == 0 || tiny || hiddenOnCurrent.contains(id) { unseen.insert(id) }
        }
        return unseen
    }

    /// Front-to-back position of the windows on screen.
    private static func stackingOrder() -> [CGWindowID: Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, info) in list.enumerated() {
            if let id = info[kCGWindowNumber as String] as? CGWindowID { order[id] = index }
        }
        return order
    }

    // MARK: - Acting on a row

    func activate(_ item: SwitcherItem) {
        guard let id = item.window, let entry = entries[id] else {
            activateApp(item.pid)
            return
        }
        // Counts as used right away, so a second switch does not wait for the notification.
        touch(id)
        work.async {
            if entry.minimized {
                AXUIElementSetAttributeValue(entry.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            var psn = ProcessSerialNumber()
            GetProcessForPID(entry.pid, &psn)
            // 0x200: as if the user had clicked the window.
            _SLPSSetFrontProcessWithOptions(&psn, id, 0x200)
            Self.makeKey(id, &psn)
            AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString)
        }
    }

    /// The same as clicking the app in the Dock: unhides it, and most apps
    /// open a window if they have none.
    private func activateApp(_ pid: pid_t) {
        if pid == ownPID {
            touchOwn()
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard let app = watches[pid]?.app else { return }
        if let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            app.unhide()
            app.activate()
        }
    }

    /// Tells the window server the window is key by replaying the two event
    /// records a click on it would produce.
    static func makeKey(_ window: CGWindowID, _ psn: inout ProcessSerialNumber) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
        withUnsafeBytes(of: window) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(&psn, &bytes)
    }

    func close(_ item: SwitcherItem) {
        guard let id = item.window, let entry = entries[id] else { return }
        work.async {
            guard let button: AXUIElement = Self.attribute(entry.element, kAXCloseButtonAttribute) else { return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    /// Minimizes the window, or brings it back if it already is.
    func toggleMinimized(_ item: SwitcherItem) {
        guard let id = item.window, let entry = entries[id] else { return }
        work.async {
            let value: CFBoolean = entry.minimized ? kCFBooleanFalse : kCFBooleanTrue
            AXUIElementSetAttributeValue(entry.element, kAXMinimizedAttribute as CFString, value)
        }
    }

    func quit(_ item: SwitcherItem) {
        app(item.pid)?.terminate()
    }

    /// Quits every app that only has dimmed rows: hidden, without windows, or
    /// with every window minimized. Finder and the toolkit are spared.
    func quitIdle(_ items: [SwitcherItem]) {
        let inUse = Set(items.filter { !$0.dimmed }.map(\.pid))
        for pid in Set(items.map(\.pid)).subtracting(inUse) where pid != ownPID {
            guard let app = app(pid), app.bundleIdentifier != "com.apple.finder" else { continue }
            app.terminate()
        }
    }

    /// Hides the app, or shows it again if it already is.
    func toggleHidden(_ item: SwitcherItem) {
        guard let app = app(item.pid) else { return }
        if app.isHidden { app.unhide() } else { app.hide() }
    }
}

/// A count that several threads add to.
final class Tally {
    private let lock = NSLock()
    private var count = 0

    func add(_ n: Int) {
        lock.lock()
        count += n
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
