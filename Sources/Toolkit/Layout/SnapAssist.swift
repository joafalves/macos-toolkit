import AppKit
import Carbon.HIToolbox

/// After a window is dropped into part of a display, the other windows on it
/// are offered for the part that's left, as Windows' Snap Assist does: in the
/// switcher's own list or grid, filling that part. Picking one puts it there;
/// for a layout of three, the part after that is offered next.
final class SnapAssist {
    /// A part of a display that's left.
    struct Slot: Equatable {
        let unit: CGRect
        let display: LayoutDisplay
        /// Where a window would go, with the gap, in Core Graphics coordinates.
        let frame: CGRect
    }

    /// A window on screen, front to back, for deciding what to offer.
    struct OnScreen: Equatable {
        let id: CGWindowID
        let frame: CGRect
        var pid: pid_t = 0
    }

    /// A window was picked for a slot. The controller puts it there, then
    /// calls `next()`.
    var onPick: ((SwitcherItem, Slot) -> Void)?
    /// Taken by a stack, or by a window on its way into it, which the
    /// windows on screen don't show yet.
    var taken: (CGRect) -> Bool = { _ in false }

    private let panel = SwitcherPanel(takesKeys: true)
    /// The part being offered, drawn like a drop preview, under the panel.
    private let outline = LayoutOverlay()
    private let previews = SwitcherPreviews()
    private var pending: [Slot] = []
    private var current: Slot?
    private var items: [SwitcherItem] = []
    private var selection = 0
    private var displays: [LayoutDisplay] = []
    /// The dropped window and those picked since: not offered again.
    private var used: Set<CGWindowID> = []
    /// Brought to the front when it's over, rather than after each pick,
    /// which would take the keyboard from the next offer.
    private var lastPicked: SwitcherItem?
    private var style = SuggestStyle.previews
    private var from = SuggestFrom.fallback

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.onHover = { [weak self] index in self?.select(index) }
        panel.onClick = { [weak self] index in self?.pick(index) }
        panel.onKey = { [weak self] event in self?.key(event) }
        panel.onResign = { [weak self] in self?.dismiss() }
        previews.onUpdate = { [weak self] id, image in
            guard let self, self.panel.isVisible, self.panel.style == .previews else { return }
            self.panel.model.previews[id] = image
        }
    }

    // MARK: - Session

    /// Starts offering windows for `slots`, after `window` was dropped.
    func offer(_ slots: [Slot], after window: CGWindowID, displays: [LayoutDisplay], style: SuggestStyle, from: SuggestFrom) {
        dismiss()
        guard style != .off, !slots.isEmpty else { return }
        self.style = style
        self.from = from
        self.displays = displays
        pending = slots
        used = [window]
        if style == .previews, SwitcherPreviews.permitted { previews.prepare() }
        next()
    }

    /// The next slot that's empty and has windows to offer, or the end.
    func next() {
        let onScreen = Self.onScreen()
        let all = WindowCatalog.shared.snapshot().items
        // Pictures of windows that have closed would otherwise stay for good.
        previews.keep(only: Set(all.compactMap(\.window)))
        while !pending.isEmpty {
            let slot = pending.removeFirst()
            if taken(slot.frame) || Self.filled(slot.frame, by: onScreen, except: used) { continue }
            let candidates = Self.candidates(all, onScreen: onScreen, on: slot.display, in: displays, excluding: used, from: from)
            guard !candidates.isEmpty else { continue }
            show(candidates, in: slot)
            return
        }
        finish()
    }

    /// Ends it, bringing the last picked window to the front.
    private func finish() {
        let picked = lastPicked
        dismiss()
        if let picked { WindowCatalog.shared.activate(picked) }
    }

    func dismiss() {
        pending = []
        current = nil
        items = []
        lastPicked = nil
        previews.cancel()
        panel.model.previews = [:]
        panel.hide()
        outline.hide()
    }

    private func show(_ candidates: [SwitcherItem], in slot: Slot) {
        current = slot
        items = candidates
        selection = 0
        outline.content = LayoutOverlayContent(highlight: slot.frame)
        outline.show(on: slot.display, interactive: false)
        let pictures = style == .previews && SwitcherPreviews.permitted
        panel.style = pictures ? .previews : .list
        panel.previewSize = .large
        panel.show(items, selection: 0, filling: Coordinates.toAppKit(slot.frame))
        guard pictures else { return }
        let ids = items.compactMap(\.window)
        panel.model.previews = previews.cached(ids)
        previews.refresh(ids, width: panel.previewWidth)
    }

    // MARK: - Input

    private func select(_ index: Int) {
        guard items.indices.contains(index), index != selection else { return }
        selection = index
        panel.update(items, selection: selection)
    }

    private func pick(_ index: Int) {
        guard items.indices.contains(index), let slot = current else { return }
        let item = items[index]
        if let id = item.window { used.insert(id) }
        lastPicked = item
        panel.hide()
        outline.hide()
        previews.cancel()
        onPick?(item, slot)
    }

    private func key(_ event: NSEvent) {
        let grid = panel.style == .previews
        switch Int(event.keyCode) {
        // Not Space: someone typing straight after a snap would drop a window in.
        case kVK_Return, kVK_ANSI_KeypadEnter: pick(selection)
        case kVK_Tab where !event.modifierFlags.contains(.shift): select(min(selection + 1, items.count - 1))
        case kVK_RightArrow: select(min(selection + 1, items.count - 1))
        case kVK_LeftArrow, kVK_Tab: select(max(selection - 1, 0))
        case kVK_DownArrow: select(grid ? panel.neighbour(of: selection, rows: 1) : min(selection + 1, items.count - 1))
        case kVK_UpArrow: select(grid ? panel.neighbour(of: selection, rows: -1) : max(selection - 1, 0))
        default:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            if let digit = digits.firstIndex(of: Int(event.keyCode)), digit < items.count {
                pick(digit)
            } else {
                // Esc, or typing: the offer goes away and the keys are the app's again.
                finish()
            }
        }
    }

    // MARK: - What to offer (no state, for the self-test too)

    /// Normal windows on screen now, front to back: the current Space only.
    static func onScreen() -> [OnScreen] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return OnScreen(id: id, frame: frame, pid: info[kCGWindowOwnerPID as String] as? pid_t ?? 0)
        }
    }

    /// A window is already in the slot, and in sight there (one put there
    /// before, say): nothing to offer for it. One in the slot but under
    /// another window, a maximized one say, doesn't count: the slot looks
    /// empty. `onScreen` is front to back.
    static func filled(_ slot: CGRect, by onScreen: [OnScreen], except: Set<CGWindowID>) -> Bool {
        occupant(of: slot, by: onScreen, except: except) != nil
    }

    /// The window that fills the slot, in sight, if one does.
    static func occupant(of slot: CGRect, by onScreen: [OnScreen], except: Set<CGWindowID>) -> OnScreen? {
        let others = onScreen.filter { !except.contains($0.id) }
        for (index, window) in others.enumerated() where LayoutWindow.near(window.frame, slot) {
            let covered = others[..<index].contains { above in
                let overlap = above.frame.intersection(slot)
                return !overlap.isNull && overlap.width * overlap.height > slot.width * slot.height * 0.1
            }
            if !covered { return window }
        }
        return nil
    }

    /// Open windows on the current Space, leaving out the ones in
    /// `excluding`, most recently used first: this display's, and the other
    /// displays' after them as `from` says.
    static func candidates(_ items: [SwitcherItem], onScreen: [OnScreen], on display: LayoutDisplay,
                           in displays: [LayoutDisplay], excluding: Set<CGWindowID>, from: SuggestFrom = .all) -> [SwitcherItem] {
        let frames = Dictionary(onScreen.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let open = items.filter { item in
            guard item.state == .window, let id = item.window, !excluding.contains(id) else { return false }
            return frames[id] != nil
        }
        func here(_ item: SwitcherItem) -> Bool {
            item.window.flatMap { frames[$0] }.flatMap { LayoutGeometry.display(of: $0, in: displays) }?.id == display.id
        }
        let local = open.filter(here)
        switch from {
        case .display: return local
        case .fallback: return local.isEmpty ? open : local
        case .all: return local + open.filter { !here($0) }
        }
    }
}
