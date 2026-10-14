import AppKit
import SwiftUI

/// What the switcher list shows. Only `shown` rows are on screen at once; the
/// range follows the selection.
final class SwitcherListModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var selection = 0
    /// Index of the first row on screen.
    @Published var first = 0
    @Published var shown = 0

    var visible: ArraySlice<SwitcherItem> {
        items[min(first, items.count)..<min(first + shown, items.count)]
    }

    /// Moves the visible range by `delta` rows, or just far enough to show the selection.
    func scroll(by delta: Int = 0) {
        var first = first + delta
        if delta == 0 {
            if selection < first { first = selection }
            if selection >= first + shown { first = selection - shown + 1 }
        }
        self.first = max(0, min(first, items.count - shown))
    }
}

struct SwitcherListView: View {
    static let rowHeight: CGFloat = 38
    static let padding: CGFloat = 8

    @ObservedObject var model: SwitcherListModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.visible.enumerated()), id: \.element.id) { offset, item in
                let index = model.first + offset
                SwitcherRow(item: item, number: index < 9 ? index + 1 : nil, selected: index == model.selection)
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SwitcherRow: View {
    let item: SwitcherItem
    let number: Int?
    let selected: Bool

    private var stateSymbol: String? {
        switch item.state {
        case .window: return nil
        case .minimized: return "minus.circle"
        case .hiddenApp: return "eye.slash"
        case .noWindows: return "macwindow.badge.plus"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(number == nil ? 0 : (selected ? 0.22 : 0.1)),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .frame(width: 26, height: 26)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if let stateSymbol {
                Image(systemName: stateSymbol).font(.footnote)
            }
            // Rows that stand for an app already show its name as the title.
            if item.window != nil, item.title != item.appName {
                Text(item.appName)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .opacity(0.6)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .opacity(item.dimmed ? 0.55 : 1)
        .padding(.horizontal, 8)
        .frame(height: SwitcherListView.rowHeight)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// The floating list. It never becomes key: the keyboard is handled by the
/// controller's event tap, and the mouse by a view laid over the rows.
final class SwitcherPanel {
    let model = SwitcherListModel()
    /// The pointer moved onto the row at this index.
    var onHover: (Int) -> Void = { _ in }
    var onClick: (Int) -> Void = { _ in }

    private lazy var panel = makePanel()
    /// Area of the display the list is on. Chosen when it opens, so it does
    /// not jump displays while open.
    private var screen = NSRect.zero
    private(set) var isVisible = false

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Shows over full-screen apps and on whichever Space is current.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let list = NSHostingView(rootView: SwitcherListView(model: model))
        let mouse = MouseCatcher()
        mouse.panel = self
        for view in [list, mouse] {
            view.frame = background.bounds
            view.autoresizingMask = [.width, .height]
            background.addSubview(view)
        }
        panel.contentView = background
        return panel
    }

    func show(_ items: [SwitcherItem], selection: Int, on placement: SwitcherPlacement) {
        let screens = NSScreen.screens
        let chosen: NSScreen?
        switch placement {
        case .mainScreen: chosen = screens.first
        case .mouse: chosen = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        case .activeWindow: chosen = NSScreen.main
        }
        screen = (chosen ?? screens.first)?.visibleFrame ?? .zero
        isVisible = true
        update(items, selection: selection)
        panel.orderFrontRegardless()
    }

    func update(_ items: [SwitcherItem], selection: Int) {
        guard isVisible else { return }
        let room = Int((screen.height * 0.7 - SwitcherListView.padding * 2) / SwitcherListView.rowHeight)
        model.items = items
        model.selection = selection
        model.shown = min(items.count, max(room, 3))
        model.scroll()

        let size = NSSize(width: min(620, screen.width - 80),
                          height: CGFloat(max(model.shown, 1)) * SwitcherListView.rowHeight + SwitcherListView.padding * 2)
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
    }

    fileprivate func index(at point: NSPoint) -> Int? {
        let row = Int(floor((point.y - SwitcherListView.padding) / SwitcherListView.rowHeight))
        return (0..<model.shown).contains(row) ? model.first + row : nil
    }
}

/// Sits on top of the list and turns pointer positions into row indexes.
/// SwiftUI's own hover and tap handling needs a key window, which the panel never is.
private final class MouseCatcher: NSView {
    weak var panel: SwitcherPanel?
    private var scrolled: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    private func index(of event: NSEvent) -> Int? {
        panel?.index(at: convert(event.locationInWindow, from: nil))
    }

    // Only real movement selects, so the list can open under a resting pointer.
    override func mouseMoved(with event: NSEvent) {
        if let index = index(of: event) { panel?.onHover(index) }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = index(of: event) { panel?.onClick(index) }
    }

    override func scrollWheel(with event: NSEvent) {
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * SwitcherListView.rowHeight
        let rows = Int(scrolled / SwitcherListView.rowHeight)
        guard rows != 0 else { return }
        scrolled -= CGFloat(rows) * SwitcherListView.rowHeight
        panel?.model.scroll(by: -rows)
    }
}
