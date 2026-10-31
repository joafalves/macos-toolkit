import AppKit
import ApplicationServices
import os

/// Replaces Cmd-Tab with a list of windows. Holding Cmd keeps the list open;
/// letting go switches to the selected row.
final class SwitcherController: ObservableObject {
    @Published var config: SwitcherConfig {
        didSet {
            shortcut.value = config.shortcut
            appShortcut.value = config.appShortcut
            AppColors.shared.enabled = config.appColors
            SwitcherPanel.previewIcons = config.previewIcons
            guard config != oldValue, !isPreview else { return }
            config.save()
            apply()
        }
    }

    /// Accessibility is granted but macOS still refused the event tap; this
    /// happens when the grant predates the running process.
    @Published private(set) var tapFailed = false

    private enum Key {
        static let tab: Int64 = 48, escape: Int64 = 53, enter: Int64 = 36, delete: Int64 = 51, space: Int64 = 49
        static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
        static let w: Int64 = 13, q: Int64 = 12, m: Int64 = 46, h: Int64 = 4, x: Int64 = 7
        /// Key codes of 1 to 9, in that order.
        static let digits: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    /// A quick Cmd-Tab is over before this, and switches without showing anything.
    private static let revealDelay = 0.15

    private let catalog = WindowCatalog.shared
    private let panel = SwitcherPanel()
    private let previews = SwitcherPreviews()
    /// Takes new pictures while the grid is open, in Live mode.
    private var liveTimer: Timer?
    private var tap: EventTap?
    /// A shortcut's list, from its keys until those held are let go. Numbered
    /// so the main thread, ending one late, can't end the next.
    private struct Session {
        let number: Int
        let key: Int64
        let held: CGEventFlags
        let shiftReverses: Bool
    }

    /// For the tap's thread: the shortcuts, and the session that's on, if any.
    private let shortcut = Locked(Shortcut.commandTab)
    private let appShortcut = Locked(Shortcut.none)
    private let session = Locked<Session?>(nil)
    /// The tap thread's count of sessions.
    private var sessions = 0
    /// The session the main thread is showing.
    private var sessionShown: Int?
    private var timer: Timer?

    // The switcher is "active" from Cmd-Tab until Cmd is released.
    private var active = false
    /// What's listed: `unfiltered`, or what a search found.
    private var items: [SwitcherItem] = []
    private var unfiltered: [SwitcherItem] = []
    private var query = ""
    /// Only this app's windows.
    private var onlyApp: pid_t?
    /// The row the list opened on, for when a search is cleared.
    private var openedOn = 0
    private var revealList: (() -> Void)?
    /// The display whose windows are listed, while only one's are.
    private var shownOn: NSScreen?
    private var selection = 0
    private var reveal: DispatchWorkItem?

    /// For `--snapshot`: default settings, nothing read or written.
    private(set) var isPreview = false

    /// The displays to set the grid's width for, made up in a preview.
    var gridDisplays: [LayoutDisplay] {
        guard isPreview else { return LayoutDisplay.all() }
        func display(_ name: String, _ width: CGFloat, _ height: CGFloat) -> LayoutDisplay {
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            return LayoutDisplay(id: 0, uuid: name, name: name, frame: frame, usable: frame)
        }
        return [display("Large Display", 2560, 1440), display("Laptop Display", 1512, 982)]
    }

    static func preview() -> SwitcherController {
        let switcher = SwitcherController()
        switcher.isPreview = true
        switcher.config = SwitcherConfig()
        return switcher
    }

    init() {
        config = SwitcherConfig.load()
        shortcut.value = config.shortcut
        appShortcut.value = config.appShortcut
        AppColors.shared.enabled = config.appColors
        SwitcherPanel.previewIcons = config.previewIcons
        catalog.onChange = { [weak self] in self?.refresh() }
        AppIndex.shared.onChange = { [weak self] in self?.refresh() }
        panel.onHover = { [weak self] in self?.select($0) }
        previews.onUpdate = { [weak self] id, image in
            guard let self, self.panel.isVisible, self.panel.style == .previews else { return }
            self.panel.model.previews[id] = image
        }
        panel.onClick = { [weak self] index in
            self?.select(index)
            self?.confirm()
        }
    }

    // MARK: - Lifecycle

    func start() {
        apply()
        // Accessibility may be granted after launch.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.apply() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // macOS's own ⌘Tab is put back in step after the Mac sleeps or the
        // user comes back to this session, in case either turned it on again.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.systemSwitcherSetAt = nil
                self?.apply()
            })
        }
    }

    /// Hands Cmd-Tab back to macOS.
    func stop() {
        timer?.invalidate()
        timer = nil
        wakeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        wakeObservers.removeAll()
        uninstall()
    }

    private func apply() {
        guard config.enabled else { return uninstall() }
        if tap == nil {
            guard AXIsProcessTrusted() else { return }
            let installed = installTap()
            Log.switcher.notice("event tap started: \(installed)")
            if tapFailed == installed { tapFailed = !installed }
            guard installed else { return }
            catalog.use(self, true)
            AppIndex.shared.refresh()
        }
        // macOS handles its own ⌘Tab before event taps see the keys, so it has
        // to be switched off while ours is ⌘Tab, and only then.
        let ours = config.shortcut.keyCode == Shortcut.commandTab.keyCode
            && config.shortcut.flags.subtracting(.shift) == Shortcut.commandTab.flags
        // Only when it changes, plus once a minute in case something else
        // turned macOS's back on: every 2 seconds was a window server call
        // for nothing.
        let now = ProcessInfo.processInfo.systemUptime
        guard systemSwitcherOn != !ours || systemCycleCheckedFor != config.appShortcut || now - (systemSwitcherSetAt ?? -.infinity) > 60 else { return }
        CGSSetSymbolicHotKeyEnabled(1, !ours)
        CGSSetSymbolicHotKeyEnabled(2, !ours)
        // macOS's way through an app's windows goes the same way, if ours has its keys.
        let entry = CaptureKeys.systemPrefs()[String(Self.systemCycleKey)]
        let cycleOurs = config.appShortcut == (CaptureKeys.systemShortcut(entry) ?? Self.systemCycle)
        CGSSetSymbolicHotKeyEnabled(Self.systemCycleKey, !cycleOurs && CaptureKeys.systemEnabled(entry))
        systemSwitcherOn = !ours
        systemCycleCheckedFor = config.appShortcut
        systemSwitcherSetAt = now
    }

    /// macOS's "Move focus to next window", with the keys it has out of the box.
    private static let systemCycleKey: Int32 = 27
    private static let systemCycle = Shortcut(keyCode: 50, flags: [.command])
    /// The shortcut macOS's was last compared with.
    private var systemCycleCheckedFor: Shortcut?

    /// What macOS's own ⌘Tab was last set to, and when.
    private var systemSwitcherOn: Bool?
    private var systemSwitcherSetAt: TimeInterval?
    private var wakeObservers: [NSObjectProtocol] = []

    private func uninstall() {
        guard let tap else { return }
        end()
        tap.stop()
        self.tap = nil
        catalog.use(self, false)
        CGSSetSymbolicHotKeyEnabled(1, true)
        CGSSetSymbolicHotKeyEnabled(2, true)
        CGSSetSymbolicHotKeyEnabled(Self.systemCycleKey, CaptureKeys.systemEnabled(CaptureKeys.systemPrefs()[String(Self.systemCycleKey)]))
        systemCycleCheckedFor = nil
        systemSwitcherOn = true
        systemSwitcherSetAt = nil
    }

    private func installTap() -> Bool {
        tap = EventTap(name: "switcher", events: [.keyDown, .keyUp, .flagsChanged]) { [weak self] type, event in
            // nil means "take the event": `??` here would pass it on after all.
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(type: type, event: event)
        }
        return tap != nil
    }

    // MARK: - Keyboard

    /// On the tap's thread: decides what to take from `session` and
    /// `shortcut` alone, and hands everything the switcher does to the main
    /// thread, in order.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        func main(_ work: @escaping (SwitcherController) -> Void) {
            DispatchQueue.main.async { [weak self] in if let self { work(self) } }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The release of Cmd may have been among the events we missed.
            if session.update({ on in defer { on = nil }; return on != nil }) { main { $0.end() } }
            return pass
        }
        let current = session.value
        // A shortcut is being typed into the settings.
        if ShortcutRecording.active, current == nil { return pass }
        let flags = event.flags
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        guard let current else {
            guard type == .keyDown else { return pass }
            // Exactly a shortcut (and its ⇧ version); other combinations
            // belong to other apps. Its ⌘ ⌥ ⌃ are what hold the list open. ⇧
            // goes backwards, unless the shortcut itself has ⇧.
            let holding: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
            for (shortcut, onlyApp) in [(self.shortcut.value, false), (appShortcut.value, true)] where !shortcut.isNone {
                let held = shortcut.cgFlags.subtracting(.maskShift)
                let shiftReverses = !shortcut.flags.contains(.shift)
                guard code == Int64(shortcut.keyCode), flags.intersection(holding) == held,
                      shiftReverses || flags.contains(.maskShift) else { continue }
                sessions += 1
                let number = sessions
                session.value = Session(number: number, key: code, held: held, shiftReverses: shiftReverses)
                let backwards = shiftReverses && flags.contains(.maskShift)
                main {
                    $0.sessionShown = number
                    $0.begin(backwards: backwards, onlyApp: onlyApp)
                }
                return nil
            }
            return pass
        }

        // The held keys are what keep the switcher open. Checking them on every
        // event means a missed release can never leave the keyboard swallowed.
        guard flags.contains(current.held) else {
            session.value = nil
            if type == .flagsChanged { main { $0.confirm() } } else { main { $0.end() } }
            return pass
        }
        if type == .keyDown {
            if code == current.key {
                let step = current.shiftReverses && flags.contains(.maskShift) ? -1 : 1
                main { $0.move(by: step) }
            } else {
                let shift = flags.contains(.maskShift)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                // A shortcut with ⇧ has it held all along, so it can't mean an
                // action: typing "mail" would minimize a window.
                let actions = shift && current.shiftReverses
                main { $0.keyDown(code, shift: shift, actions: actions, isRepeat: isRepeat) }
            }
        }
        // Keys pressed while the switcher is open must not reach the app behind
        // it, where they would be Cmd-Q, Cmd-W and so on.
        return type == .flagsChanged ? pass : nil
    }

    private func keyDown(_ code: Int64, shift: Bool, actions: Bool, isRepeat: Bool) {
        switch code {
        case Key.tab: move(by: shift ? -1 : 1)
        case Key.right: move(by: 1)
        case Key.left: move(by: -1)
        // In the grid, up and down go to the row above and below.
        case Key.down where grid: select(panel.neighbour(of: selection, rows: 1))
        case Key.up where grid: select(panel.neighbour(of: selection, rows: -1))
        case Key.down: move(by: 1)
        case Key.up: move(by: -1)
        // Esc takes back a search first, then the list.
        case Key.escape: if query.isEmpty { end() } else { search("") }
        case Key.enter: confirm()
        case Key.delete: if !query.isEmpty { search(String(query.dropLast())) }
        default:
            guard !isRepeat else { return }
            // Numbers pick a row, searching or not, so they aren't searched for.
            if let digit = Key.digits.firstIndex(of: code) {
                guard digit < items.count else { return }
                selection = digit
                confirm()
            } else if actions, [Key.w, Key.q, Key.m, Key.h, Key.x].contains(code) {
                // Only once the list is on screen: these should not be done blind.
                guard panel.isVisible, items.indices.contains(selection) else { return }
                let item = items[selection]
                switch code {
                case Key.w: catalog.close(item)
                case Key.q: catalog.quit(item)
                case Key.m: catalog.toggleMinimized(item)
                case Key.h: catalog.toggleHidden(item)
                // Of everything listed, not just what a search left.
                case Key.x: catalog.quitIdle(unfiltered)
                default: break
                }
            } else if code != Key.space || !query.isEmpty, let text = Shortcut.typed(Int(code)) {
                func all(_ set: CharacterSet) -> Bool { text.unicodeScalars.allSatisfy(set.contains) }
                // A shortcut's key stays out of the search, like § after ⌘, unless
                // it's a letter, which searching needs whatever else it's used for.
                let shortcutKey = code == Int64(config.shortcut.keyCode) || code == Int64(config.appShortcut.keyCode)
                if shortcutKey ? all(.alphanumerics) : all(CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces)) {
                    search(query + text)
                }
            }
        }
    }

    // MARK: - Search

    /// Lists what `text` finds, at once if the list wasn't up yet; empty, puts
    /// the list back as it opened.
    private func search(_ text: String) {
        guard active else { return }
        if query.isEmpty, !text.isEmpty { AppIndex.shared.refresh() }
        query = text
        filter()
        selection = text.isEmpty ? min(openedOn, max(items.count - 1, 0)) : 0
        panel.query = query
        if panel.isVisible {
            panel.update(items, selection: selection)
        } else {
            reveal?.cancel()
            revealList?()
        }
    }

    private func filter() {
        guard !query.isEmpty else {
            items = unfiltered
            return
        }
        let index = AppIndex.shared
        // An app's own windows don't lead to opening others.
        var found = SwitcherSearch.results(query, rows: unfiltered, installed: onlyApp == nil ? index.apps : [],
                                           otherName: index.otherName, icon: index.icon)
        // The rows have theirs: only an app without a row may need one looked up.
        AppColors.shared.lookUp(&found)
        items = found
    }

    // MARK: - Session

    private func begin(backwards: Bool, onlyApp only: Bool) {
        onlyApp = only ? NSWorkspace.shared.frontmostApplication.map { catalog.appPID($0.processIdentifier) } : nil
        var (list, currentFirst) = catalog.snapshot()
        if let onlyApp {
            list = list.filter { $0.pid == onlyApp }
            currentFirst = list.first?.state == .window
        }
        // Which display's, from now until it closes. An app's own windows are
        // all listed, wherever they are.
        shownOn = config.shownWindows == .display && !only ? SwitcherPanel.screen(for: config.placement) : nil
        if let shownOn {
            let current = currentFirst ? list.first?.id : nil
            list = Self.windows(list, on: shownOn)
            currentFirst = current != nil && list.first?.id == current
        }
        items = list
        unfiltered = list
        query = ""
        active = true
        if backwards {
            selection = max(list.count - 1, 0)
        } else {
            // Row 1 is the window already in use, so start on the one before it:
            // a quick ⌘Tab goes back there.
            selection = currentFirst && list.count > 1 ? 1 : 0
        }
        let initial = selection
        openedOn = initial
        let backwards = backwards
        if config.style == .previews, SwitcherPreviews.permitted { previews.prepare() }
        let show: () -> Void = { [weak self] in
            // With That display, a display may have no windows: nothing to show,
            // unless something's been typed.
            guard let self, self.active, !self.items.isEmpty || !self.query.isEmpty else { return }
            // Once it shows, the settings may want the current window selected,
            // unless the selection has already been moved.
            if !self.config.startOnPrevious, !backwards, currentFirst, self.selection == initial, self.query.isEmpty {
                self.selection = 0
                self.openedOn = 0
            }
            // Previews need Screen Recording; without it, the list.
            let previews = self.config.style == .previews && SwitcherPreviews.permitted
            self.panel.style = previews ? .previews : .list
            self.panel.previewSize = self.config.previewSize
            if let screen = SwitcherPanel.screen(for: self.config.placement) {
                self.panel.gridWidth = self.config.gridWidth(for: LayoutDisplay(screen))
            }
            self.panel.query = self.query
            self.panel.model.badges = DockBadges.shared.last
            self.panel.show(self.items, selection: self.selection, on: self.config.placement)
            if previews { self.startPreviews() }
            self.catalog.heal()
            let session = self.sessionShown
            DockBadges.shared.read { [weak self] badges in
                guard let self, self.active, self.sessionShown == session else { return }
                self.panel.model.badges = badges
            }
        }
        revealList = show
        let reveal = DispatchWorkItem(block: show)
        self.reveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay, execute: reveal)
    }

    /// The rows for windows on `screen`, by where most of each is: rows for
    /// whole apps (hidden, or with no window) are on no display.
    static func windows(_ items: [SwitcherItem], on screen: NSScreen) -> [SwitcherItem] {
        let displays = LayoutDisplay.all()
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return items }
        let frames = WindowCatalog.frames(of: items.compactMap(\.window))
        return items.filter { item in
            guard item.state == .window || item.state == .minimized, let id = item.window, let frame = frames[id] else { return false }
            return LayoutGeometry.display(of: frame, in: displays)?.id == number
        }
    }

    private func move(by step: Int) {
        guard !items.isEmpty else { return }
        select((selection + step + items.count) % items.count)
    }

    private func select(_ index: Int) {
        guard active, items.indices.contains(index), index != selection else { return }
        selection = index
        panel.update(items, selection: selection)
    }

    /// Closes the switcher and goes to the selected row.
    private func confirm() {
        let item = items.indices.contains(selection) ? items[selection] : nil
        end()
        if let item { catalog.activate(item) }
    }

    /// Closes the switcher without switching.
    private func end() {
        active = false
        // Only the session this one showed: the tap may have started the next.
        let shown = sessionShown
        session.update { if $0?.number == shown { $0 = nil } }
        sessionShown = nil
        reveal?.cancel()
        reveal = nil
        revealList = nil
        stopPreviews()
        panel.hide()
        items = []
        unfiltered = []
        query = ""
        onlyApp = nil
        shownOn = nil
    }

    private var grid: Bool { panel.isVisible && panel.style == .previews }

    // MARK: - Previews

    private var previewIDs: [CGWindowID] {
        items.filter { $0.state == .window }.compactMap(\.window)
    }

    /// Only once the grid is on screen, so a quick ⌘Tab takes no pictures.
    private func startPreviews() {
        let ids = previewIDs
        // Minimized windows can't be taken again, but keep their last picture.
        let shown = items.compactMap(\.window)
        panel.model.previews = config.previewFreshness == .fresh ? [:] : previews.cached(shown)
        previews.refresh(ids, width: panel.previewWidth)
        if config.previewFreshness == .live {
            let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
                guard let self, self.grid, !self.previews.busy else { return }
                self.previews.refresh(self.previewIDs, width: self.panel.previewWidth)
            }
            RunLoop.main.add(timer, forMode: .common)
            liveTimer = timer
        }
    }

    private func stopPreviews() {
        liveTimer?.invalidate()
        liveTimer = nil
        previews.cancel()
        if !unfiltered.isEmpty { previews.keep(only: Set(unfiltered.compactMap(\.window))) }
        panel.model.previews = [:]
    }

    /// Picks up changes made while the list is open (a window closed with W,
    /// say) without reshuffling it: rows keep their place, new ones go last.
    private func refresh() {
        guard active else { return }
        let selected = items.indices.contains(selection) ? items[selection].id : nil
        var fresh = catalog.snapshot().items
        if let onlyApp { fresh = fresh.filter { $0.pid == onlyApp } }
        if let shownOn { fresh = Self.windows(fresh, on: shownOn) }
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = unfiltered.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        unfiltered = kept + fresh.filter { !keptIDs.contains($0.id) }
        if query.isEmpty {
            items = unfiltered
            selection = min(selection, max(items.count - 1, 0))
            // The last row closed with W or Q leaves an empty square otherwise.
            if items.isEmpty { stopPreviews(); panel.hide() }
        } else {
            filter()
            // What's found changes order, so the selection goes by row.
            selection = items.firstIndex { $0.id == selected } ?? 0
        }
        panel.update(items, selection: selection)
    }

    // MARK: - Development

    /// `--test-switcher-displays [report]`: the windows open now, listed for
    /// each display as the switcher lists them with That display: each on
    /// the display with most of it, every window on one display only, and
    /// no row for a whole app. Counts only, no titles.
    static func displaysTest(report path: String?) {
        _ = NSApplication.shared
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        if AXIsProcessTrusted() {
            let catalog = WindowCatalog()
            catalog.start()
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            let items = catalog.snapshot().items
            let windows = items.filter { $0.state == .window || $0.state == .minimized }
            let frames = WindowCatalog.frames(of: windows.compactMap(\.window))
            let displays = LayoutDisplay.all()
            lines.append("     \(items.count) rows, \(windows.count) of them windows, \(frames.count) with a frame, on \(NSScreen.screens.count) displays")
            var seen: [String: Int] = [:]
            for screen in NSScreen.screens {
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                let listed = Self.windows(items, on: screen)
                listed.forEach { seen[$0.id, default: 0] += 1 }
                let elsewhere = listed.filter { item in
                    item.window.flatMap { frames[$0] }.flatMap { LayoutGeometry.display(of: $0, in: displays) }?.id != number
                }
                check("\(screen.localizedName): \(listed.count) windows, each mostly on it", elsewhere.isEmpty, "\(elsewhere.count) elsewhere")
                check("\(screen.localizedName): no rows for whole apps", !listed.contains { $0.window == nil || $0.state == .hiddenApp || $0.state == .noWindows })
            }
            let withFrames = windows.filter { $0.window.map { frames[$0] != nil } ?? false }
            check("every window with a frame is on one display's list", withFrames.allSatisfy { seen[$0.id] == 1 },
                  "\(withFrames.filter { seen[$0.id] != 1 }.count) on none or more than one")
        } else {
            lines.append("skip: Accessibility is not granted to this process (run the app bundle with `open -n`)")
        }
        lines.append(failures == 0 ? "all passed" : "\(failures) failed")
        let output = lines.joined(separator: "\n") + "\n"
        print(output, terminator: "")
        if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    #if TOOLKIT_DEV
    /// `--test-catalog-startup [report]`: how the list fills from nothing, as
    /// at launch; when no app answers at first; and when it has missed
    /// everything and the list opens. Reads other apps' windows, moves nothing.
    static func catalogStartupTest(report path: String?) {
        _ = NSApplication.shared
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        /// How long until it has `count` windows, or nil.
        func wait(_ catalog: WindowCatalog, for count: Int, within seconds: TimeInterval) -> TimeInterval? {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                if catalog.windowCount >= count { return Date().timeIntervalSince(start) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            return nil
        }
        func time(_ value: TimeInterval?) -> String { value.map { String(format: "%.2f s", $0) } ?? "never" }
        if AXIsProcessTrusted() {
            let first = WindowCatalog()
            let start = Date()
            first.start()
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            let count = first.windowCount
            lines.append("     \(count) windows after 3 s")
            first.stop()

            let plain = WindowCatalog()
            plain.start()
            let filled = wait(plain, for: count, within: 2)
            check("every window from nothing, promptly", (filled ?? 99) < 1, time(filled))
            plain.stop()

            let refusing = WindowCatalog()
            refusing.refusedScans = 2
            refusing.start()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let early = refusing.windowCount
            check("apps that don't answer at first aren't listed yet", early == 0, "\(early) windows at 0.3 s")
            let recovered = wait(refusing, for: count, within: 6)
            check("and are asked again until they do", recovered != nil, time(recovered))
            refusing.stop()

            let healing = WindowCatalog()
            healing.start()
            _ = wait(healing, for: count, within: 3)
            healing.forgetWindows()
            healing.heal()
            let onScreen = healing.missingOnScreen
            let healStart = Date()
            while healing.missingOnScreen > 0, Date().timeIntervalSince(healStart) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            lines.append("     \(onScreen) on screen were missing")
            check("what's missed on screen comes back when the list opens", healing.missingOnScreen == 0,
                  String(format: "%.2f s, %d windows", Date().timeIntervalSince(healStart), healing.windowCount))
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            healing.forgetWindows()
            healing.heal()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            // A window that changes on its own comes back through its notice, so not none.
            check("but apps aren't asked again straight away", healing.windowCount < count, "\(healing.windowCount) of \(count) windows")
            healing.stop()

            // What Window Layout's suggestions place a picked window by.
            let placing = WindowCatalog()
            placing.start()
            _ = wait(placing, for: count, within: 3)
            let own = ProcessInfo.processInfo.processIdentifier
            let rows = placing.snapshot().items.filter { $0.state == .window && $0.pid != own }
            let lost = rows.filter { item in item.window.map { LayoutWindow.find(id: $0, pid: item.windowPID ?? item.pid) == nil } ?? true }
            check("every window listed can be found to place it, a helper's too", lost.isEmpty, "\(rows.count) windows, \(lost.count) not found")
            placing.stop()
            lines.append(String(format: "     all in %.1f s", Date().timeIntervalSince(start)))
        } else {
            lines.append("skip: Accessibility is not granted to this process (run the app bundle with `open -n`)")
        }
        lines.append(failures == 0 ? "all passed" : "\(failures) failed")
        let output = lines.joined(separator: "\n") + "\n"
        print(output, terminator: "")
        if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
    }
    #endif

    /// Prints what the switcher would list, for checking window discovery from the terminal.
    static func dumpWindows() {
        // The list asks the app about its own window, so there has to be one.
        _ = NSApplication.shared
        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted to the process running this.")
            return
        }
        let catalog = WindowCatalog()
        let start = Date()
        catalog.start()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let items = catalog.snapshot().items
        let counts = "\(items.filter { $0.window != nil }.count) windows; \(WindowCatalog.probes.value) elements tried for other Spaces, in under \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
        // `--list-windows --counts <file>`: just that line, into a file, for
        // a run through `open -n` where nothing prints.
        if let flag = CommandLine.arguments.firstIndex(of: "--counts"), CommandLine.arguments.count > flag + 1 {
            try? (counts + "\n").write(toFile: CommandLine.arguments[flag + 1], atomically: true, encoding: .utf8)
            return
        }
        print(counts)
        for (index, item) in items.enumerated() {
            print("\(index + 1)\t\(item.state)\t\(item.window.map(String.init) ?? "-")\t\(item.appName)\t\(item.title)")
        }
    }
}
