import AppKit
import Carbon.HIToolbox
import os
#if TOOLKIT_DEV
import ScreenCaptureKit
#endif

/// The Floating Dock: a ring of apps that opens at the pointer. Held open by
/// its trigger (the right ⌘ key, a shortcut, or a mouse button the Mouse tool
/// gives it), it picks by direction: let go towards an app to bring it forward,
/// further out for one of its windows. A tap leaves it open, for a click, a
/// letter or Tab to search. It reserves no room on screen and leaves the macOS Dock alone.
///
/// While it's open the real pointer stays where it was, hidden and held still
/// (`CGAssociateMouseAndMouseCursorPosition`), and the ring draws a pointer of
/// its own, moved by the mouse's own deltas: it starts at the ring's centre
/// wherever the ring had to go, never stops at the edge of the screen, and the
/// apps below see no movement at all, so nothing there lights up under it.
final class FloatingDockController: ObservableObject {
    enum Source { case keyboard, mouse }

    @Published var config: FloatingDockConfig {
        didSet {
            guard config != oldValue, !isPreview else { return }
            config.save()
            apply()
        }
    }
    /// Accessibility is granted but macOS still refused the event tap.
    @Published private(set) var tapFailed = false

    /// For the Mouse tool's Floating Dock action, which has no other way to it.
    static private(set) weak var shared: FloatingDockController?

    private(set) var isPreview = false
    private var tap: EventTap?
    private let panel = DockRingPanel()
    private var model: DockRingModel { panel.model }
    private let previews = SwitcherPreviews()
    private var trustTimer: Timer?

    // What the tap's thread needs to decide, kept by the main thread.
    private struct TapState {
        var open = false
        var searching = false
        var trigger = DockTrigger.rightCommand
        var shortcut = Shortcut.none
        /// The right ⌘ went down alone and nothing has followed yet: let go, it's a tap.
        var commandPending: UInt64?
        /// The key that holds it open, while it does.
        var heldBy: Held = .none
        /// How far the pointer was last put, on open or close. macOS counts a warp
        /// into the next move's delta, which would throw the ring's pointer that far.
        var warped: CGVector?
        /// The real pointer is the ring's: moves are read by where they put it.
        var follow = false
        /// The apps' letters, for the right ⌘ with one (`quickLetters`); empty when that's off.
        var quickLetters: Set<String> = []
        /// A letter taken with the right ⌘: its key going up is ours too.
        var swallowUp: Int?
        /// The right ⌘ was down at the last change of modifiers. Only its going down
        /// counts: macOS sends a change with the same keys to an app that comes forward,
        /// which the ⌘ still held from a quick switch would take for a press.
        var rightDown = false
        var opening = DockOpening.toggle
        /// Every app's letter on the ring, for keys typed with the right ⌘ held in `.press`.
        var ringLetters: Set<String> = []
        /// The shortcut is down, to toggle the ring as it goes up.
        var shortcutDown: Int?
    }
    enum Held { case none, rightCommand, shortcut, mouse }
    private let state = Locked(TapState())

    // On the main thread, while open.
    private enum Mode { case hold, click }
    private var mode = Mode.hold
    private var held = Held.none
    private var openedAt = Date.distantPast
    /// The ring's own pointer, from its centre: where the real one would be.
    private var pointer = CGPoint.zero
    /// The ring's centre, in screen coordinates (y down, as events have it).
    private var center = CGPoint.zero
    /// The pointer left the centre once since this ring showed: coming back is "back".
    private var leftHub = false
    private var layers: [DockRing] = []
    private var folders: [DockRing] = []
    private var letters: [String: DockApp] = [:]
    private var items: [SwitcherItem] = []
    private var scrollSum: CGFloat = 0
    /// The real pointer is hidden and held still, until it closes.
    private var pointerHeld = false
    /// Where the real pointer is held (the ring's centre), and where it was before.
    private var heldFrom = CGPoint.zero
    private var heldOrigin = CGPoint.zero
    /// Opened over macOS's Dock, which keeps the pointer showing: the real one is
    /// the ring's pointer then, rather than one drawn beside it.
    private var followsPointer = false
    /// ⌥ was down as it opened, as part of its shortcut: not a new window.
    private var optionFromTrigger = false
    /// Which way the ring's pointer is going.
    private var motion = CGVector.zero
    /// Windows whose pictures were asked for since the ring opened.
    private var taken: Set<CGWindowID> = []
    private var scrollQuietUntil = Date.distantPast

    static func preview() -> FloatingDockController {
        let dock = FloatingDockController(preview: true)
        dock.config.enabled = true
        // Apps every Mac has, at made-up paths: nothing is read from this Mac's Dock.
        DockRings.preview = ["Navigator", "Mail", "Messages", "Editor", "Terminal", "Notes", "Calendar", "Files", "Music", "Photos"]
            .map { DockApp(path: "/Applications/Preview \($0).app", bundleID: nil, name: $0) }
        return dock
    }

    private init(preview: Bool) {
        isPreview = true
        config = FloatingDockConfig()
    }

    init() {
        config = FloatingDockConfig.load()
        Self.shared = self
        previews.onUpdate = { [weak self] id, image in self?.model.previews[id] = image }
    }

    func start() { apply() }

    func stop() {
        close(pick: nil)
        tap?.stop()
        tap = nil
        trustTimer?.invalidate()
        trustTimer = nil
        WindowCatalog.shared.use(self, false)
    }

    private func apply() {
        state.update {
            $0.trigger = config.trigger
            $0.shortcut = config.shortcut
            $0.opening = config.opening
        }
        guard config.enabled else { return stop() }
        WindowCatalog.shared.use(self, true)
        if tap == nil { installTap() }
        refreshLetters()
    }

    /// The apps' letters, as the ring gives them, and the set the tap reads for
    /// the right ⌘ with a letter. Made again as the ring opens, which reads the Dock.
    private func refreshLetters() {
        let pinnedApps = DockRings.apps(in: DockRings.entries(config))
        let chosen = DockRings.letters(for: pinnedApps, chosen: config.letters)
        letters = Dictionary(pinnedApps.compactMap { app in chosen[app.path].map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        let keys = config.quickLetters && config.trigger == .rightCommand ? Set(letters.keys) : []
        let all = Set(letters.keys)
        state.update { $0.quickLetters = keys; $0.ringLetters = all }
    }

    /// The right ⌘ with an app's letter, the ring never shown: the app forward, or with ⌥ a new window of it.
    private func quickSwitch(_ letter: String, newWindow: Bool) {
        guard let app = letters[letter] else { return }
        // The ring may have been taken just as the letter came: it goes with the switch.
        close {
            if newWindow {
                Self.newWindow(of: RingSlot(id: app.path, kind: .app(app), name: app.name, icon: nil))
            } else {
                Self.bringForward(app, windows: DockRings.windows(of: app, in: WindowCatalog.shared.snapshot().items))
            }
        }
    }

    private func installTap() {
        guard AXIsProcessTrusted() else {
            // Picked up as soon as it's granted, not only at the next launch.
            if trustTimer == nil {
                trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self, AXIsProcessTrusted() else { return }
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.apply()
                }
            }
            return
        }
        let events: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                     .otherMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        tap = EventTap(name: "floating-dock", events: events) { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(type: type, event: event)
        }
        let failed = tap == nil
        if tapFailed != failed { tapFailed = failed }
        Log.dock.notice("floating dock tap started: \(!failed, privacy: .public)")
    }

    // MARK: - On the tap's thread

    /// The right ⌘ key, apart from the left one.
    private static let rightCommandBit: UInt64 = 0x10
    private static let leftCommandBit: UInt64 = 0x08

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        func main(_ work: @escaping (FloatingDockController) -> Void) {
            DispatchQueue.main.async { [weak self] in if let self { work(self) } }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // It may have missed the right ⌘ going up, which would leave its next press unseen.
            state.update { $0.commandPending = nil; $0.rightDown = false }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == ButtonActions.marker { return pass }
        let current = state.value
        if ShortcutRecording.active, !current.open { return pass }

        switch type {
        case .flagsChanged:
            // ⌥ while it's open: a new window of the app picked. One already down as it
            // opened is the shortcut's, and counts once it's been let go and pressed again.
            if current.open {
                let alt = event.flags.contains(.maskAlternate)
                main { $0.option(alt) }
            }
            guard current.trigger == .rightCommand else { return pass }
            let raw = event.flags.rawValue
            let right = raw & Self.rightCommandBit != 0
            let others = event.flags.intersection([.maskShift, .maskControl, .maskAlternate]) != [] || raw & Self.leftCommandBit != 0
            let pressed = right && !current.rightDown
            if current.rightDown != right { state.update { $0.rightDown = right } }
            if pressed, !others, current.heldBy == .none, current.commandPending == nil {
                if current.opening == .press, !current.open {
                    // Shown at once, for as long as it's held. Marked open here, so a key
                    // typed while the ring is being built is already the ring's.
                    state.update { $0.heldBy = .rightCommand; $0.open = true }
                    main { $0.open(mode: .hold, held: .rightCommand) }
                } else {
                    // Toggled as it goes up, never while it's held: held, it's waiting for
                    // a letter or a ⌘ shortcut, and the ring would only be in the way.
                    let stamp = event.timestamp
                    state.update { $0.commandPending = stamp }
                }
            } else if !right {
                if current.commandPending != nil {
                    // Let go alone, with no key, click or scroll in between: open it to stay, or close it.
                    state.update { $0.commandPending = nil }
                    if !others { main { $0.tapped(from: .keyboard) } }
                } else if current.heldBy == .rightCommand {
                    state.update { $0.heldBy = .none }
                    main { $0.released() }
                }
            } else if others, current.commandPending != nil {
                state.update { $0.commandPending = nil }
            }
            return pass

        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // A key with the right ⌘ down: a ⌘ shortcut, or a letter for the ring, so letting
            // go of it is no tap (which would open the ring after the switch).
            if type == .keyDown, current.commandPending != nil { state.update { $0.commandPending = nil } }
            // A key the dock took going down: going up is the dock's too, even once it's closed.
            if type == .keyUp, current.swallowUp == code {
                state.update { $0.swallowUp = nil }
                return nil
            }
            // The shortcut, to toggle (and, held for the ring in `.press`, to close one left open):
            // the ring opens or closes as it goes up.
            if current.trigger == .shortcut, !current.shortcut.isNone, code == current.shortcut.keyCode, current.heldBy != .shortcut {
                if type == .keyUp, current.shortcutDown == code {
                    state.update { $0.shortcutDown = nil }
                    main { $0.tapped(from: .keyboard) }
                    return nil
                }
                if type == .keyDown, current.shortcutDown == code { return nil }
                if type == .keyDown, !repeating, current.opening == .toggle || current.open,
                   event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == current.shortcut.cgFlags {
                    state.update { $0.shortcutDown = code }
                    return nil
                }
            }
            if !current.open {
                // The right ⌘ (alone, or with ⌥ for a new window) and an app's letter: that app,
                // at once, the ring never shown. Any other key with it is a ⌘ shortcut, the app's.
                let raw = event.flags.rawValue
                if type == .keyDown, !repeating, !current.quickLetters.isEmpty, raw & Self.rightCommandBit != 0,
                   raw & Self.leftCommandBit == 0, event.flags.intersection([.maskShift, .maskControl]).isEmpty {
                    let plain = event.copy()
                    plain?.flags = []
                    let letter = Self.text(of: plain ?? event).lowercased()
                    if current.quickLetters.contains(letter) {
                        let alt = event.flags.contains(.maskAlternate)
                        state.update { $0.swallowUp = code }
                        main { $0.quickSwitch(letter, newWindow: alt) }
                        return nil
                    }
                }
                guard current.trigger == .shortcut, current.opening == .press, !current.shortcut.isNone, type == .keyDown, !repeating,
                      code == current.shortcut.keyCode,
                      event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == current.shortcut.cgFlags
                else { return pass }
                state.update { $0.heldBy = .shortcut; $0.open = true }
                main { $0.open(mode: .hold, held: .shortcut) }
                return nil
            }
            if current.heldBy == .shortcut, code == current.shortcut.keyCode {
                if type == .keyUp {
                    state.update { $0.heldBy = .none }
                    main { $0.released() }
                }
                return nil
            }
            // ⌘Tab while it's open: the switcher's, or macOS's. The ring gives way.
            if type == .keyDown, code == kVK_Tab, event.flags.contains(.maskCommand) {
                state.update { $0.open = false; $0.searching = false; $0.heldBy = .none }
                main { $0.close(pick: nil) }
                return pass
            }
            // Everything typed while it's open is the dock's: never ⌘Q in the app behind.
            if type == .keyDown {
                // The letter as typed without ⌥, which turns it into another character.
                let alt = event.flags.contains(.maskAlternate)
                let plain = event.copy()
                plain?.flags = []
                let text = Self.text(of: plain ?? event)
                // Held open by the right ⌘, a key that isn't an app's letter (or esc, ↩) is a
                // ⌘ shortcut: the ring gives way and the app gets it, as without the dock.
                if current.heldBy == .rightCommand, ![kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter].contains(code),
                   !current.ringLetters.contains(text.lowercased()) {
                    state.update { $0.open = false; $0.searching = false; $0.heldBy = .none }
                    main { $0.close(pick: nil) }
                    return pass
                }
                state.update { $0.swallowUp = code }
                main { $0.key(code, text: text, alt: alt) }
            }
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            var dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
            if let warp = current.warped {
                state.update { $0.warped = nil }
                // Taken out only when it's there: what's left is a hand's move, far smaller.
                let rest = CGVector(dx: dx - warp.dx, dy: dy - warp.dy)
                if hypot(rest.dx, rest.dy) < hypot(dx, dy) / 2 { (dx, dy) = (rest.dx, rest.dy) }
            }
            guard current.open else { return pass }
            if current.follow {
                let location = event.location
                main { $0.moved(to: location) }
                return nil
            }
            main { $0.moved(by: CGVector(dx: dx, dy: dy)) }
            return nil

        case .leftMouseDown, .rightMouseDown:
            // A ⌘-click with the right ⌘: the app's, not the dock's.
            if current.commandPending != nil { state.update { $0.commandPending = nil } }
            guard current.open else { return pass }
            if type == .rightMouseDown { main { $0.rightClicked() } }
            return nil
        case .leftMouseUp:
            guard current.open else { return pass }
            main { $0.clicked() }
            return nil
        case .rightMouseUp:
            return current.open ? nil : pass

        case .scrollWheel:
            if current.commandPending != nil { state.update { $0.commandPending = nil } }
            guard current.open else { return pass }
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let delta = continuous ? CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
                                   : CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 40
            main { $0.scrolled(delta) }
            return nil

        default:
            return pass
        }
    }

    private static func text(of event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    // MARK: - Opening and closing

    /// From the Mouse tool: a button held, or let go.
    func trigger(down: Bool, source: Source) {
        guard config.enabled, !isPreview else { return }
        if config.opening == .toggle {
            if !down { tapped(from: source) }
            return
        }
        if down {
            if state.value.open { return close(pick: nil) }
            state.update { $0.heldBy = .mouse }
            open(mode: .hold, held: .mouse)
        } else if held == .mouse {
            state.update { if $0.heldBy == .mouse { $0.heldBy = .none } }
            released()
        }
    }

    private func tapped(from source: Source) {
        guard !state.value.open else { return close(pick: nil) }
        open(mode: .click, held: .none)
    }

    private func open(mode: Mode, held: Held) {
        guard config.enabled, !isPreview else {
            state.update { $0.open = false; $0.heldBy = .none }
            return
        }
        // Already showing: the tap may have marked it open for this one, which isn't
        // coming, so it's marked as the ring that is, or every move would be swallowed.
        guard !panel.isVisible else {
            let current = self.held
            state.update { $0.open = true; $0.heldBy = current }
            return
        }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        items = WindowCatalog.shared.snapshot().items
        buildLayers()
        guard !layers.isEmpty else {
            state.update { $0.open = false; $0.heldBy = .none }
            return
        }
        self.mode = mode
        self.held = held
        openedAt = Date()
        folders = []
        model.layer = 0
        model.searching = false
        model.letters = true
        optionFromTrigger = NSEvent.modifierFlags.contains(.option)
        model.newWindow = false
        showRing(layers[0], layerCount: layers.count)
        center = clamped(pointer)
        self.pointer = .zero
        motion = .zero
        holdPointer(at: center, from: pointer)
        leftHub = false
        state.update { $0.open = true; $0.searching = false }
        takePreviews()
        DockBadges.shared.read { [weak self] badges in self?.applyBadges(badges) }
        track()
        reveal()
    }

    private func reveal() {
        guard state.value.open else { return }
        panel.show(at: Self.appKit(center))
        panel.movePointer(to: pointer)
    }

    /// Lets go of the trigger held in `.press`: a pick if it moved to one, else it closes.
    private func released() {
        guard state.value.open else { return }
        if !model.moved, mode == .hold { return close(pick: nil) }
        commit()
    }

    private func clicked() {
        commit()
    }

    /// A right-click on an app is a new window of it, as the Dock's own menu offers;
    /// anywhere else it closes.
    private func rightClicked() {
        guard let hover = model.hover, model.slots.indices.contains(hover), !model.far, model.slots[hover].app != nil else { return close(pick: nil) }
        let slot = model.slots[hover]
        close { Self.newWindow(of: slot) }
    }

    /// ⌥ went down or up while it's open.
    private func option(_ down: Bool) {
        if !down { optionFromTrigger = false }
        let on = down && !optionFromTrigger
        if model.newWindow != on { model.newWindow = on }
    }

    func close(pick: (() -> Void)?) {
        // Whatever closed it, even ⌘Tab marking it shut before the ring showed: the
        // pointer is always let go of, or it stays stopped and hidden.
        guard state.value.open || panel.isVisible || pointerHeld else { pick?(); return }
        state.update { $0.open = false; $0.searching = false; $0.heldBy = .none }
        held = .none
        // The real pointer comes back where the ring's was, so it doesn't jump;
        // where it was held, moved as much, if the ring never showed.
        let shown = panel.isVisible
        let from = shown ? center : heldOrigin
        panel.hide()
        previews.cancel()
        taken = []
        releasePointer(at: CGPoint(x: from.x + pointer.x, y: from.y + pointer.y))
        model.hover = nil
        model.fan = []
        model.searching = false
        model.query = ""
        pick?()
    }

    // MARK: - The rings

    private func buildLayers() {
        let entries = DockRings.entries(config)
        let running = NSWorkspace.shared.runningApplications
        let pinnedApps = DockRings.apps(in: entries)
        let chosen = DockRings.letters(for: pinnedApps, chosen: config.letters)
        letters = Dictionary(pinnedApps.compactMap { app in chosen[app.path].map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        let keys = config.quickLetters && config.trigger == .rightCommand ? Set(letters.keys) : []
        let all = Set(letters.keys)
        state.update { $0.quickLetters = keys; $0.ringLetters = all }
        let badges = DockBadges.shared.last
        func ring(_ title: String, _ list: [DockEntry]) -> DockRing {
            DockRing(title: title, slots: DockRings.slots(list, letters: chosen, badges: badges, items: items, running: running))
        }
        var result: [DockRing] = []
        let (shown, rest) = DockRings.split(entries, slots: config.slots, overflow: config.overflow)
        if !shown.isEmpty { result.append(ring(String(localized: "Pinned"), shown)) }
        let open = DockRings.openApps(excluding: pinnedApps, items: items, running: running).map { DockEntry.app($0) }
        if !open.isEmpty {
            let (openShown, _) = DockRings.split(open, slots: config.slots, overflow: .moreSlot)
            result.append(ring(String(localized: "Open apps"), openShown))
        }
        if !rest.isEmpty {
            let (moreShown, _) = DockRings.split(rest, slots: config.slots, overflow: .moreSlot)
            result.append(ring(String(localized: "More"), moreShown))
        }
        layers = result
    }

    private func showRing(_ ring: DockRing, layerCount: Int) {
        model.slots = ring.slots
        model.title = ring.title
        model.geometry = RingGeometry(n: ring.slots.count, room: config.slots)
        model.layers = folders.isEmpty ? layerCount : 1
        model.hover = nil
        model.fan = []
        model.fanHover = nil
        model.far = false
        model.moved = false
        panel.updateMask()
    }

    private func applyBadges(_ badges: [String: String]) {
        guard state.value.open else { return }
        for i in model.slots.indices {
            if let app = model.slots[i].app { model.slots[i].badge = badges[URL(fileURLWithPath: app.path).lastPathComponent] }
        }
    }

    /// Into a folder, in the same place, the pointer back at the centre.
    private func push(_ entries: [DockEntry], title: String) {
        let running = NSWorkspace.shared.runningApplications
        let chosen = Dictionary(letters.map { ($0.value.path, $0.key) }, uniquingKeysWith: { first, _ in first })
        let (shown, _) = DockRings.split(entries, slots: config.slots, overflow: .moreSlot)
        let ring = DockRing(title: title, slots: DockRings.slots(shown, letters: chosen, badges: DockBadges.shared.last, items: items, running: running))
        folders.append(ring)
        showRing(ring, layerCount: 1)
        reposition()
    }

    private func pop() {
        guard !folders.isEmpty else { return }
        folders.removeLast()
        showRing(folders.last ?? layers[model.layer], layerCount: layers.count)
        reposition()
    }

    /// After a change of ring: the same centre where it fits, the pointer back on it.
    private func reposition() {
        center = clamped(center)
        pointer = .zero
        motion = .zero
        leftHub = false
        if panel.isVisible { panel.show(at: Self.appKit(center)) }
        panel.movePointer(to: pointer)
        placeRealPointer()
    }

    private func scrolled(_ delta: CGFloat) {
        guard folders.isEmpty, layers.count > 1, !model.searching, Date() > scrollQuietUntil else { return }
        scrollSum += delta
        guard abs(scrollSum) >= 40 else { return }
        let step = scrollSum > 0 ? -1 : 1
        scrollSum = 0
        scrollQuietUntil = Date().addingTimeInterval(0.3)
        let next = min(max(model.layer + step, 0), layers.count - 1)
        guard next != model.layer else { return }
        model.layer = next
        showRing(layers[next], layerCount: layers.count)
        reposition()
    }

    // MARK: - Following the pointer

    /// The mouse moved: the ring's pointer with it, kept within the ring's panel.
    private func moved(by delta: CGVector) {
        guard state.value.open else { return }
        follow(to: kept(CGPoint(x: pointer.x + delta.dx, y: pointer.y + delta.dy)))
        panel.movePointer(to: pointer)
        track()
    }

    /// The real pointer moved, when it's the ring's: kept within the panel too.
    private func moved(to location: CGPoint) {
        guard state.value.open else { return }
        let raw = CGPoint(x: location.x - center.x, y: location.y - center.y)
        follow(to: kept(raw))
        if pointer != raw { placeRealPointer() }
        track()
    }

    /// The ring's pointer to `p`, with which way it's going, smoothed over a few events.
    private func follow(to p: CGPoint) {
        motion = CGVector(dx: motion.dx * 0.6 + (p.x - pointer.x) * 0.4, dy: motion.dy * 0.6 + (p.y - pointer.y) * 0.4)
        pointer = p
    }

    private func kept(_ p: CGPoint) -> CGPoint {
        let g = model.geometry
        return CGPoint(x: min(max(p.x, -g.ex + 4), g.ex - 4), y: min(max(p.y, -g.ey + 4), g.ey - 4))
    }

    private func track() {
        guard state.value.open, !model.searching else { return }
        let g = model.geometry
        let d = CGVector(dx: pointer.x, dy: pointer.y)
        let dist = hypot(d.dx, d.dy)
        if dist > 5 { model.moved = true }
        if dist > g.pickR + 8 { leftHub = true }
        let angle = atan2(d.dy, d.dx)

        if dist < g.pickR {
            // Back to the centre of a folder's ring: the ring it came from.
            if leftHub, !folders.isEmpty { return pop() }
            set(hover: nil, far: false, fan: nil)
            return
        }
        var slot = g.slot(at: d)
        if dist < g.far {
            // Heading out for a card that sits over a neighbour's direction: past the
            // icons' centres, the slot whose windows show holds while the pointer goes
            // outwards, towards a card. Going round the ring, it's the slot pointed at.
            let outward = (motion.dx * d.dx + motion.dy * d.dy) / dist
            let around = abs(motion.dx * d.dy - motion.dy * d.dx) / dist
            if let hover = model.hover, hover != slot, dist >= g.R1, !model.fan.isEmpty, outward > 0, outward >= around * 0.35,
               Self.towards(angle, model.fan) {
                slot = hover
            }
            set(hover: slot, far: false, fan: nil)
            return
        }
        // Past the ring: the slot left by holds while the pointer is on or by its cards.
        let point = CGPoint(x: d.dx, y: d.dy)
        if let hover = model.hover, let near = Self.nearest(point, model.fan), near.distance < 40 { slot = hover }
        if case .folder(let entries) = model.slots[slot].kind {
            return push(entries, title: model.slots[slot].name)
        }
        set(hover: slot, far: true, fan: nil)
        // The card nearest the pointer, and none once it's well away from them all.
        let k = Self.nearest(point, model.fan).flatMap { $0.distance < 40 ? $0.index : nil }
        if model.fanHover != k { model.fanHover = k }
    }

    private func set(hover: Int?, far: Bool, fan: Int?) {
        var reshaped = false
        if hover != model.hover {
            model.hover = hover
            let items = hover.map { fanItems(for: $0) } ?? []
            reshaped = !(items.isEmpty && model.fan.isEmpty)
            model.fan = items
            requestPreviews()
        }
        if model.far != far {
            model.far = far
            reshaped = reshaped || !model.fan.isEmpty
        }
        // The cards are part of the glass: its shape follows them.
        if reshaped { panel.updateMask() }
        if !far, model.fanHover != nil { model.fanHover = nil }
    }

    private func fanItems(for index: Int) -> [FanItem] {
        guard model.slots.indices.contains(index) else { return [] }
        let slot = model.slots[index], g = model.geometry
        // The windows, the most recent straight out and the rest either side; at
        // most three, or the two most recent when there are more, and the way to
        // all of them at the start. A new window is ⌥ or a right-click on the app,
        // which keeps a place of its own off the cards.
        var windows: [FanItem.Kind] = slot.windows.map { .window($0) }
        let more = windows.count > 3 ? windows.count - 2 : nil
        if more != nil { windows = Array(windows.prefix(2)) }
        var offsets = RingGeometry.fanOffsets(windows.count)
        var kinds = windows
        let lo = offsets.min() ?? 0
        if let more { kinds.append(.all(more)); offsets.append(lo - 1) }
        let centres = g.cardCentres(slot: index, places: offsets)
        return kinds.enumerated().map { k, kind in
            let id: String
            switch kind {
            case .window(let item): id = item.id
            case .all: id = "all:" + slot.id
            }
            return FanItem(id: id, kind: kind, center: centres[k])
        }
    }

    /// Fresh pictures of every window the ring can show, taken as it opens, so
    /// they're there by the time it's pointed at; the last ones show meanwhile.
    private func takePreviews() {
        guard SwitcherPreviews.permitted else { return }
        let open = Set(items.compactMap(\.window))
        previews.keep(only: open)
        model.previews = model.previews.filter { open.contains($0.key) }
        // As many as a fan shows: three, or the two most recent when there are more.
        var seen = Set<CGWindowID>()
        let ids = Array(layers.flatMap(\.slots).flatMap { $0.windows.prefix(3) }.compactMap(\.window).filter { seen.insert($0).inserted }.prefix(40))
        for (id, image) in previews.cached(ids) { model.previews[id] = image }
        previews.add(ids, width: 300)
        taken = Set(ids)
    }

    /// The fan's pictures: taken as the ring opened, or now for a folder's apps.
    private func requestPreviews() {
        guard SwitcherPreviews.permitted else { return }
        let ids = model.fan.compactMap { item -> CGWindowID? in if case .window(let w) = item.kind { return w.window } else { return nil } }
        let missing = ids.filter { !taken.contains($0) }
        guard !missing.isEmpty else { return }
        for (id, image) in previews.cached(missing) where model.previews[id] == nil { model.previews[id] = image }
        previews.add(missing, width: 300)
        taken.formUnion(missing)
    }

    /// Whether a line out from the centre at `angle` meets one of the cards.
    private static func towards(_ angle: CGFloat, _ fan: [FanItem]) -> Bool {
        fan.contains { item in
            let r = RingGeometry.rect(at: item.center), mid = atan2(item.center.y, item.center.x)
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            let half = corners.map { RingGeometry.angleDiff(atan2($0.y, $0.x), mid) }.max() ?? 0
            return RingGeometry.angleDiff(angle, mid) <= half
        }
    }

    /// The card nearest `p` (from the ring's centre, y down), and how far it is: 0 on it.
    private static func nearest(_ p: CGPoint, _ fan: [FanItem]) -> (index: Int, distance: CGFloat)? {
        fan.enumerated().map { k, item in
            let r = RingGeometry.rect(at: item.center)
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return (k, hypot(dx, dy))
        }
        .min { $0.distance < $1.distance }
    }

    // MARK: - Picking

    private func commit() {
        guard let hover = model.hover, model.slots.indices.contains(hover) else { return close(pick: nil) }
        let slot = model.slots[hover]
        // With ⌥, on the app: a new window of it.
        if model.newWindow, !model.far, slot.app != nil { return close { [slot] in Self.newWindow(of: slot) } }
        // The card lit is the pick: past the ring the one pointed at, on the app its most recent window.
        if let k = model.pick, model.fan.indices.contains(k) {
            switch model.fan[k].kind {
            case .window(let item): return close { WindowCatalog.shared.activate(item) }
            case .all: return close { [slot] in Self.showAllWindows(of: slot) }
            }
        }
        switch slot.kind {
        case .folder(let entries): push(entries, title: slot.name)
        case .app(let app): close { [slot] in Self.bringForward(app, windows: slot.windows) }
        }
    }

    private static func bringForward(_ app: DockApp, windows: [SwitcherItem]) {
        if let first = windows.first(where: { $0.state == .window }) ?? windows.first {
            WindowCatalog.shared.activate(first)
        } else {
            // Opens it, or brings it forward with a window as the Dock does.
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Brings the app forward and asks it for a new window: its own menu item
    /// with ⌘N, as a click there would, or the keys themselves where it has none.
    private static func newWindow(of slot: RingSlot) {
        guard let app = slot.app else { return }
        guard let running = NSWorkspace.shared.runningApplications.first(where: { DockRings.isRunning(app, [$0]) }) else {
            // Not open: opening it gives it its first window.
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        running.activate()
        let pid = running.processIdentifier
        // Accessibility can wait on a busy app, so never on the main thread.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            if !pressMenuItem(key: "N", in: pid) {
                DispatchQueue.main.async { ButtonActions.press(Shortcut(keyCode: kVK_ANSI_N, flags: [.command], key: "N")) }
            }
        }
    }

    /// Presses the item of `pid`'s menu bar whose shortcut is ⌘ and `key` alone.
    private static func pressMenuItem(key: String, in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? T
        }
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return false }
        // The menus by the bar (File is near the start), each one's items, a level deep.
        for menu in (attribute(bar, kAXChildrenAttribute) as [AXUIElement]? ?? []).prefix(6) {
            for list in attribute(menu, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
                for item in attribute(list, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
                    guard let char: String = attribute(item, kAXMenuItemCmdCharAttribute), char.uppercased() == key,
                          (attribute(item, kAXMenuItemCmdModifiersAttribute) as NSNumber?)?.intValue ?? 0 == 0,
                          (attribute(item, kAXEnabledAttribute) as Bool?) ?? true else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// Brings the app forward, then macOS's own view of its windows.
    private static func showAllWindows(of slot: RingSlot) {
        guard let app = slot.app else { return }
        bringForward(app, windows: slot.windows)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { ShowDesktop.appWindows() }
    }

    // MARK: - Keys

    private func key(_ code: Int, text: String, alt: Bool) {
        if model.searching { return searchKey(code, text: text) }
        switch code {
        case kVK_Escape: close(pick: nil)
        case kVK_Tab: startSearch()
        case kVK_Return, kVK_ANSI_KeypadEnter: commit()
        case kVK_Delete: if folders.isEmpty { close(pick: nil) } else { pop() }
        default:
            let letter = text.lowercased()
            guard letter.count == 1, let app = letters[letter] else { return }
            let windows = DockRings.windows(of: app, in: items)
            // With ⌥, a new window of it.
            if alt, !optionFromTrigger {
                let slot = RingSlot(id: app.path, kind: .app(app), name: app.name, icon: nil)
                return close { Self.newWindow(of: slot) }
            }
            close { Self.bringForward(app, windows: windows) }
        }
    }

    private func startSearch() {
        AppIndex.shared.refresh()
        model.searching = true
        model.query = ""
        model.selection = 0
        model.results = searchResults("")
        state.update { $0.searching = true }
        panel.updateMask()
    }

    private func searchKey(_ code: Int, text: String) {
        switch code {
        case kVK_Escape:
            model.searching = false
            state.update { $0.searching = false }
            panel.updateMask()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard model.results.indices.contains(model.selection) else { return }
            let app = model.results[model.selection]
            let windows = DockRings.windows(of: app, in: items)
            close { Self.bringForward(app, windows: windows) }
        case kVK_Delete:
            model.query = String(model.query.dropLast())
            model.selection = 0
            model.results = searchResults(model.query)
        case kVK_LeftArrow: model.selection = max(0, model.selection - 1)
        case kVK_RightArrow: model.selection = min(max(model.results.count - 1, 0), model.selection + 1)
        case kVK_UpArrow: model.selection = max(0, model.selection - 5)
        case kVK_DownArrow: model.selection = min(max(model.results.count - 1, 0), model.selection + 5)
        default:
            guard !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
            model.query += text
            model.selection = 0
            model.results = searchResults(model.query)
        }
    }

    /// The pinned apps first, then every app on the Mac, by how well the name matches.
    private func searchResults(_ query: String) -> [DockApp] {
        let pinned = DockRings.apps(in: DockRings.entries(config))
        let installed = AppIndex.shared.apps.map { DockApp(path: $0.url.path, bundleID: $0.bundleID, name: $0.name) }
        var seen = Set<String>()
        let all = (pinned + installed).filter { seen.insert($0.bundleID ?? $0.path).inserted }
        guard !query.isEmpty else { return Array(pinned.prefix(15)) }
        return all.compactMap { app in SwitcherSearch.rank(query, in: app.name).map { (app, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: - Screen geometry

    /// The pointer, in screen coordinates (y down).
    private static func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// From screen coordinates (y down from the top of the main display) to AppKit's.
    private static func onScreen(_ p: CGPoint) -> Bool {
        var count: UInt32 = 0
        var display: CGDirectDisplayID = 0
        return CGGetDisplaysWithPoint(p, 1, &display, &count) == .success && count > 0
    }

    private static func appKit(_ p: CGPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: height - p.y)
    }

    /// The centre for a ring opened at `p`: on its display, as near as it can be with the whole ring and its windows on screen.
    private func clamped(_ p: CGPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: p.x, y: height - p.y)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(appKitPoint, $0.frame, false) }) ?? NSScreen.main else { return p }
        let v = screen.visibleFrame
        // The visible frame, in screen coordinates.
        let area = CGRect(x: v.minX, y: height - v.maxY, width: v.width, height: v.height)
        let g = model.geometry, m: CGFloat = 8
        func fit(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat, _ half: CGFloat) -> CGFloat {
            hi - lo < half * 2 + m * 2 ? (lo + hi) / 2 : min(max(value, lo + half + m), hi - half - m)
        }
        return CGPoint(x: fit(p.x, area.minX, area.maxX, g.ex), y: fit(p.y, area.minY, area.maxY, g.ey))
    }

    /// Holds the real pointer still and hides it: the mouse still reports its
    /// moves, which drive the ring's own. Undone on close; a crash undoes it too,
    /// as both belong to this process's connection to the window server. It's held
    /// under the ring's centre, where the ring's own pointer starts.
    ///
    /// Over macOS's Dock it can't be hidden: the Dock never sees it leave, so it
    /// stays up and keeps it showing (`--test-dock-cursor`: nothing hides it). The
    /// real pointer is then the ring's: it moves as usual, its moves still kept
    /// from the apps below, and the ring reads where it is.
    private func holdPointer(at center: CGPoint, from origin: CGPoint) {
        guard !pointerHeld else { return }
        pointerHeld = true
        heldOrigin = origin
        heldFrom = origin
        followsPointer = Self.overDock(origin)
        if hypot(center.x - origin.x, center.y - origin.y) >= 1 {
            CGWarpMouseCursorPosition(center)
            heldFrom = center
            let warp = CGVector(dx: center.x - origin.x, dy: center.y - origin.y)
            if !followsPointer { state.update { $0.warped = warp } }
        }
        panel.showsPointer = !followsPointer
        if followsPointer {
            // Let go at once, which skips the pause a warp brings.
            CGAssociateMouseAndMouseCursorPosition(1)
            state.update { $0.follow = true }
            return
        }
        CaptureCursor.allowInBackground()
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
    }

    private func releasePointer(at point: CGPoint) {
        guard pointerHeld else { return }
        pointerHeld = false
        if followsPointer {
            // Already where the ring's pointer was.
            followsPointer = false
            state.update { $0.follow = false }
            return
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        if Self.onScreen(point), hypot(point.x - heldFrom.x, point.y - heldFrom.y) >= 1 { Self.place(point) }
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// Puts the real pointer at `p` with a move of the mouse, not a warp: a warp holds
    /// back the mouse's own moves for a moment after, and with the hand still moving
    /// as the ring closes that left the pointer stopped dead. The move also lets the
    /// app below see where it now is.
    private static func place(_ p: CGPoint) {
        guard let source = CGEventSource(stateID: .privateState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        else { CGWarpMouseCursorPosition(p); return }
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
                                                          state: .eventSuppressionStateSuppressionInterval)
        move.setIntegerValueField(.eventSourceUserData, value: ButtonActions.marker)
        move.post(tap: .cghidEventTap)
    }

    /// The real pointer put where the ring's is, when it's the ring's.
    private func placeRealPointer() {
        guard followsPointer else { return }
        CGWarpMouseCursorPosition(CGPoint(x: center.x + pointer.x, y: center.y + pointer.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Whether one of macOS's Dock's own windows is at `p`: the bar, shown.
    private static func overDock(_ p: CGPoint) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return false }
        let level = Int(CGWindowLevelForKey(.dockWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == dock && (info[kCGWindowLayer as String] as? Int) == level
                && (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.contains(p) == true
        }
    }
}


#if TOOLKIT_DEV
extension FloatingDockController {
    /// The real ring, glass and all, opened at the pointer with this Mac's apps
    /// and pictured with what's behind it: at rest, pointed at the app with the
    /// most windows, and out on its first card. Changes no setting.
    static func liveCapture(to folder: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dock = FloatingDockController()
        guard dock.config.enabled else { return print("the Floating Dock is off") }
        WindowCatalog.shared.use(dock, true)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        dock.open(mode: .click, held: .none)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        dock.capture(to: folder + "/rest.png")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        dock.capture(to: folder + "/rest-later.png")
        if let index = dock.model.slots.indices.max(by: { dock.model.slots[$0].windows.count < dock.model.slots[$1].windows.count }) {
            dock.set(hover: index, far: false, fan: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            dock.capture(to: folder + "/hover.png")
            // On to the next place and back: the ticks the highlight leaves must be whole.
            dock.set(hover: (index + 1) % dock.model.slots.count, far: false, fan: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            dock.capture(to: folder + "/moved.png")
            dock.set(hover: index, far: false, fan: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            dock.set(hover: index, far: true, fan: nil)
            dock.model.fanHover = 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            dock.capture(to: folder + "/far.png")
            print("pointed at \(dock.model.slots[index].name): \(dock.model.slots[index].windows.count) windows")
        }
        dock.close(pick: nil)
        WindowCatalog.shared.use(dock, false)
    }

    /// Over macOS's Dock the pointer can't be hidden. Puts it there and in the
    /// middle of the display, opens the ring, and looks for the real pointer in a
    /// capture and whether the ring follows it instead; then puts it back.
    static func cursorTest(to path: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dock = FloatingDockController()
        guard dock.config.enabled, let screen = NSScreen.screens.first else { return print("the Floating Dock is off") }
        WindowCatalog.shared.use(dock, true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let original = CGEvent(source: nil)?.location ?? .zero
        let height = screen.frame.height
        let dockHeight = screen.visibleFrame.minY - screen.frame.minY
        let overDock = CGPoint(x: screen.frame.midX, y: height - max(dockHeight / 2, 2))
        let middle = CGPoint(x: screen.frame.midX, y: height / 2)
        var lines = ["dock height \(dockHeight), pointer was at \(original)"]
        func put(_ p: CGPoint) {
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1)
            let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
            event?.setIntegerValueField(.eventSourceUserData, value: ButtonActions.marker)
            event?.post(tap: .cghidEventTap)
        }
        for (name, start) in [("middle", middle), ("dock", overDock)] {
            put(start)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            let under = windowOwner(at: start)
            dock.open(mode: .click, held: .none)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let seen = cursorSeen(at: dock.heldFrom)
            lines.append("\(name): under \(under), real pointer in capture \(seen.map(String.init) ?? "?"), the ring's own drawn \(dock.panel.showsPointer), follows the real one \(dock.followsPointer)")
            dock.close(pick: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        put(original)
        WindowCatalog.shared.use(dock, false)
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func windowOwner(at p: CGPoint) -> String {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(p), (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return "\(info[kCGWindowOwnerName as String] as? String ?? "?") layer \(info[kCGWindowLayer as String] as? Int ?? -1)"
        }
        return "nothing"
    }

    /// Whether a capture with the cursor differs from one without, around `p`.
    private static func cursorSeen(at p: CGPoint) -> Bool? {
        func grab(_ cursor: Bool) -> [UInt8]? {
            var bytes: [UInt8]?
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                defer { done.signal() }
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let display = content.displays.first(where: { $0.frame.contains(p) }) else { return }
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: p.x - display.frame.minX - 8, y: p.y - display.frame.minY - 8, width: 48, height: 48)
                config.width = 96
                config.height = 96
                config.showsCursor = cursor
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config) else { return }
                var data = [UInt8](repeating: 0, count: 96 * 96 * 4)
                let context = CGContext(data: &data, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
                bytes = data
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return bytes
        }
        guard let with = grab(true), let without = grab(false) else { return nil }
        let differing = zip(with, without).filter { abs(Int($0) - Int($1)) > 40 }.count
        return differing > 40
    }

    private func capture(to path: String) {
        guard let id = panel.windowNumber.map({ CGWindowID($0) }),
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
        else { return print("no panel") }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: bounds.midX, y: bounds.midY)) })
            else { return print("no display") }
            let config = SCStreamConfiguration()
            config.sourceRect = bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let scale = NSScreen.screens.first(where: { $0.displayID == display.displayID })?.backingScaleFactor ?? 2
            config.width = Int(bounds.width * scale)
            config.height = Int(bounds.height * scale)
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
            else { return print("capture failed") }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            // The panel alone, nothing behind it: what it draws itself.
            if let window = content.windows.first(where: { $0.windowID == id }),
               let alone = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: {
                   let own = SCStreamConfiguration()
                   own.width = config.width
                   own.height = config.height
                   own.showsCursor = false
                   return own
               }()),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-alone.png")) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, alone, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}
#endif
