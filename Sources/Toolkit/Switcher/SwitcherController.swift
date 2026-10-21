import AppKit
import ApplicationServices

/// Replaces Cmd-Tab with a list of windows. Holding Cmd keeps the list open;
/// letting go switches to the selected row.
final class SwitcherController: ObservableObject {
    @Published var config: SwitcherConfig {
        didSet {
            shortcut.value = config.shortcut
            guard config != oldValue, !isPreview else { return }
            config.save()
            apply()
        }
    }

    /// Accessibility is granted but macOS still refused the event tap; this
    /// happens when the grant predates the running process.
    @Published private(set) var tapFailed = false

    private enum Key {
        static let tab: Int64 = 48, escape: Int64 = 53, enter: Int64 = 36
        static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
        static let w: Int64 = 13, q: Int64 = 12, m: Int64 = 46, h: Int64 = 4, x: Int64 = 7
        /// Key codes of 1 to 9, in that order.
        static let digits: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    /// A quick Cmd-Tab is over before this, and switches without showing anything.
    private static let revealDelay = 0.15

    private let catalog = WindowCatalog()
    private let panel = SwitcherPanel()
    private let previews = SwitcherPreviews()
    /// Takes new pictures while the grid is open, in Live mode.
    private var liveTimer: Timer?
    private var tap: EventTap?
    /// For the tap's thread: the shortcut, and the session that's on, if any
    /// (from the shortcut until its held keys are let go). Sessions are
    /// numbered so the main thread, ending one late, can't end the next.
    private let shortcut = Locked(Shortcut.commandTab)
    private let session = Locked<Int?>(nil)
    /// The tap thread's count of sessions.
    private var sessions = 0
    /// The session the main thread is showing.
    private var sessionShown: Int?
    private var timer: Timer?

    // The switcher is "active" from Cmd-Tab until Cmd is released.
    private var active = false
    private var items: [SwitcherItem] = []
    private var selection = 0
    private var reveal: DispatchWorkItem?

    /// For `--snapshot`: default settings, nothing read or written.
    private(set) var isPreview = false

    static func preview() -> SwitcherController {
        let switcher = SwitcherController()
        switcher.isPreview = true
        switcher.config = SwitcherConfig()
        return switcher
    }

    init() {
        config = SwitcherConfig.load()
        shortcut.value = config.shortcut
        catalog.onChange = { [weak self] in self?.refresh() }
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
            NSLog("Toolkit: switcher event tap started = \(installed)")
            if tapFailed == installed { tapFailed = !installed }
            guard installed else { return }
            catalog.start()
        }
        // macOS handles its own ⌘Tab before event taps see the keys, so it has
        // to be switched off while ours is ⌘Tab, and only then.
        let ours = config.shortcut.keyCode == Shortcut.commandTab.keyCode
            && config.shortcut.flags.subtracting(.shift) == Shortcut.commandTab.flags
        // Only when it changes, plus once a minute in case something else
        // turned macOS's back on: every 2 seconds was a window server call
        // for nothing.
        let now = ProcessInfo.processInfo.systemUptime
        guard systemSwitcherOn != !ours || now - (systemSwitcherSetAt ?? -.infinity) > 60 else { return }
        CGSSetSymbolicHotKeyEnabled(1, !ours)
        CGSSetSymbolicHotKeyEnabled(2, !ours)
        systemSwitcherOn = !ours
        systemSwitcherSetAt = now
    }

    /// What macOS's own ⌘Tab was last set to, and when.
    private var systemSwitcherOn: Bool?
    private var systemSwitcherSetAt: TimeInterval?
    private var wakeObservers: [NSObjectProtocol] = []

    private func uninstall() {
        guard let tap else { return }
        end()
        tap.stop()
        self.tap = nil
        catalog.stop()
        CGSSetSymbolicHotKeyEnabled(1, true)
        CGSSetSymbolicHotKeyEnabled(2, true)
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
        let active = session.value != nil
        // A shortcut is being typed into the settings.
        if ShortcutRecording.active, !active { return pass }
        let flags = event.flags
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let shortcut = self.shortcut.value
        // The shortcut's ⌘ ⌥ ⌃ are what hold the list open. ⇧ goes backwards,
        // unless the shortcut itself has ⇧.
        let held = shortcut.cgFlags.subtracting(.maskShift)
        let shiftReverses = !shortcut.flags.contains(.shift)

        guard active else {
            // Exactly the shortcut (and its ⇧ version); other combinations
            // belong to other apps.
            let holding: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
            guard type == .keyDown, code == Int64(shortcut.keyCode), flags.intersection(holding) == held,
                  shiftReverses || flags.contains(.maskShift)
            else { return pass }
            sessions += 1
            let number = sessions
            session.value = number
            let backwards = shiftReverses && flags.contains(.maskShift)
            main {
                $0.sessionShown = number
                $0.begin(backwards: backwards)
            }
            return nil
        }

        // The held keys are what keep the switcher open. Checking them on every
        // event means a missed release can never leave the keyboard swallowed.
        guard flags.contains(held) else {
            session.value = nil
            if type == .flagsChanged { main { $0.confirm() } } else { main { $0.end() } }
            return pass
        }
        if type == .keyDown {
            if code == Int64(shortcut.keyCode) {
                let step = shiftReverses && flags.contains(.maskShift) ? -1 : 1
                main { $0.move(by: step) }
            } else {
                let shift = flags.contains(.maskShift)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                main { $0.keyDown(code, shift: shift, isRepeat: isRepeat) }
            }
        }
        // Keys pressed while the switcher is open must not reach the app behind
        // it, where they would be Cmd-Q, Cmd-W and so on.
        return type == .flagsChanged ? pass : nil
    }

    private func keyDown(_ code: Int64, shift: Bool, isRepeat: Bool) {
        switch code {
        case Key.tab: move(by: shift ? -1 : 1)
        case Key.right: move(by: 1)
        case Key.left: move(by: -1)
        // In the grid, up and down go to the row above and below.
        case Key.down where grid: select(panel.neighbour(of: selection, rows: 1))
        case Key.up where grid: select(panel.neighbour(of: selection, rows: -1))
        case Key.down: move(by: 1)
        case Key.up: move(by: -1)
        case Key.escape: end()
        case Key.enter: confirm()
        default:
            guard !isRepeat else { return }
            if let digit = Key.digits.firstIndex(of: code) {
                guard digit < items.count else { return }
                selection = digit
                confirm()
            } else if panel.isVisible, items.indices.contains(selection) {
                // Only once the list is on screen: these should not be done blind.
                let item = items[selection]
                switch code {
                case Key.w: catalog.close(item)
                case Key.q: catalog.quit(item)
                case Key.m: catalog.toggleMinimized(item)
                case Key.h: catalog.toggleHidden(item)
                case Key.x: catalog.quitIdle(items)
                default: break
                }
            }
        }
    }

    // MARK: - Session

    private func begin(backwards: Bool) {
        let (list, currentFirst) = catalog.snapshot()
        items = list
        active = true
        if backwards {
            selection = max(list.count - 1, 0)
        } else {
            // Row 1 is the window already in use, so start on the one before it:
            // a quick ⌘Tab goes back there.
            selection = currentFirst && list.count > 1 ? 1 : 0
        }
        let initial = selection
        let backwards = backwards
        if config.style == .previews, SwitcherPreviews.permitted { previews.prepare() }
        let reveal = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            // Once it shows, the settings may want the current window selected,
            // unless the selection has already been moved.
            if !self.config.startOnPrevious, !backwards, currentFirst, self.selection == initial { self.selection = 0 }
            // Previews need Screen Recording; without it, the list.
            let previews = self.config.style == .previews && SwitcherPreviews.permitted
            self.panel.style = previews ? .previews : .list
            self.panel.previewSize = self.config.previewSize
            self.panel.show(self.items, selection: self.selection, on: self.config.placement)
            if previews { self.startPreviews() }
        }
        self.reveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay, execute: reveal)
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
        session.update { if $0 == shown { $0 = nil } }
        sessionShown = nil
        reveal?.cancel()
        reveal = nil
        stopPreviews()
        panel.hide()
        items = []
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
        if !items.isEmpty { previews.keep(only: Set(items.compactMap(\.window))) }
        panel.model.previews = [:]
    }

    /// Picks up changes made while the list is open (a window closed with W,
    /// say) without reshuffling it: rows keep their place, new ones go last.
    private func refresh() {
        guard active else { return }
        let fresh = catalog.snapshot().items
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = items.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        items = kept + fresh.filter { !keptIDs.contains($0.id) }
        selection = min(selection, max(items.count - 1, 0))
        panel.update(items, selection: selection)
    }

    // MARK: - Development

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
