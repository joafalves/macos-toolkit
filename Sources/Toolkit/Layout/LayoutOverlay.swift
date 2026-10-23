import AppKit

/// What the overlay shows on its display.
struct LayoutOverlayContent: Equatable {
    var grid: GridSize?
    var selection: CellRange?
    /// The first corner has been typed; the next key picks the other one.
    var pending = false
    /// Where the window will go, in Core Graphics coordinates.
    var highlight: CGRect?
    /// Key labels by key code. Empty draws the grid without them.
    var labels: [Int: String] = [:]
    var dim: CGFloat = 0
    /// The window being placed.
    var title: String?
    var hint: String?
    var gap: CGFloat = 0
    var picker: SlotPicker?
    /// The drop would join the window in the slot, as a tab.
    var joining = false
    /// Windows that can be stacked with, outlined.
    var outlines: [CGRect] = []
}

/// One display's worth of grid, selection and snap preview. As the keyboard
/// grid it takes keys and clicks without activating the toolkit, so the app
/// whose window is being placed stays in front. While a window is dragged
/// it's only a picture that clicks go through.
final class LayoutOverlay {
    var onKey: ((NSEvent) -> Bool)?
    /// A drag across the cells: the block so far, and whether the mouse is up.
    var onCells: ((CellRange, Bool) -> Void)?
    /// A click outside the grid, or another window took the keyboard.
    var onCancel: (() -> Void)?

    private var panel: LayoutPanel?
    private var view: LayoutOverlayView?
    private(set) var display: LayoutDisplay?
    private(set) var interactive = false

    var content = LayoutOverlayContent() {
        didSet { if content != oldValue { view?.content = content } }
    }

    var isVisible: Bool { panel != nil }
    /// For the self-test: the panel on screen, to see that it's freed after.
    var window: NSWindow? { panel }

    func show(on display: LayoutDisplay, interactive: Bool) {
        // Called on every move of a drag: once it's up, there's nothing to do.
        if panel != nil, self.display == display, self.interactive == interactive { return }
        hide()
        guard let screen = display.screen else { return }
        self.display = display
        self.interactive = interactive
        let panel = LayoutPanel(frame: screen.frame, level: .statusBar)
        // macOS's zoom in and out would leave it smaller than the display for
        // a moment, when a drag looks through it only while it covers the
        // whole display: a drag started then went unseen.
        panel.animationBehavior = .none
        let view = LayoutOverlayView(display: display)
        view.content = content
        view.overlay = self
        panel.contentView = view
        panel.ignoresMouseEvents = !interactive
        panel.onKey = { [weak self] event in self?.onKey?(event) ?? false }
        // Weak both ways: a panel holding itself through its own handler was
        // never freed, and each kept a display-sized picture in memory.
        panel.onResign = { [weak self, weak panel] in
            guard let self, let panel, self.interactive, self.panel === panel else { return }
            self.onCancel?()
        }
        panel.orderFrontRegardless()
        if interactive { panel.makeKey() }
        self.panel = panel
        self.view = view
    }

    func hide() {
        let panel = self.panel
        self.panel = nil
        view = nil
        display = nil
        panel?.orderOut(nil)
    }
}

private final class LayoutPanel: CapturePanel {
    var onResign: (() -> Void)?

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// The overlay for one display, built from layers rather than drawn: a
/// layer that's only colour and border needs no picture behind it, so a
/// display-sized overlay costs next to nothing. Drawn, it cost a picture of
/// the whole display several times over, 150 MB on a Retina screen. Only
/// the text has pixels. Laid out top down, like the Core Graphics
/// coordinates everything else uses.
final class LayoutOverlayView: NSView {
    let display: LayoutDisplay
    weak var overlay: LayoutOverlay?
    var content = LayoutOverlayContent() {
        didSet { if content != oldValue { rebuild() } }
    }
    /// Pixels per point for the text.
    var scale: CGFloat {
        didSet { rebuild() }
    }
    private var drag: CellRange?

    init(display: LayoutDisplay) {
        self.display = display
        scale = display.screen?.backingScaleFactor ?? 2
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        let root = CALayer()
        root.isGeometryFlipped = true
        // Set before asking for layers, so the view hosts this one and never draws.
        layer = root
        wantsLayer = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    /// A cell's box on screen. Without a gap the boxes would touch, so they
    /// are drawn a little apart; the window still fills the whole cell.
    private func box(_ range: CellRange, in grid: GridSize) -> CGRect {
        let rect = local(LayoutGeometry.place(range.unit(in: grid), in: display.usable, gap: content.gap))
        return content.gap < 8 ? rect.insetBy(dx: 4, dy: 4) : rect
    }

    private func rebuild() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.sublayers = nil
        root.backgroundColor = content.dim > 0 ? NSColor.black.withAlphaComponent(content.dim).cgColor : nil
        let accent = NSColor.controlAccentColor
        if let grid = content.grid {
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    shape(box(CellRange(CellRange.Cell(column: column, row: row)), in: grid),
                          fill: .white.withAlphaComponent(0.07), stroke: .white.withAlphaComponent(0.3), radius: 12)
                }
            }
        }
        for outline in content.outlines where outline != content.highlight {
            shape(local(outline).insetBy(dx: 1.5, dy: 1.5), fill: accent.withAlphaComponent(0.08), stroke: accent.withAlphaComponent(0.8), width: 2, radius: 12)
        }
        if let highlight = content.highlight {
            shape(local(highlight).insetBy(dx: 1.5, dy: 1.5), fill: accent.withAlphaComponent(0.3), stroke: accent, width: 3, radius: 12)
        }
        if let grid = content.grid, !content.labels.isEmpty {
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    let cell = CellRange.Cell(column: column, row: row)
                    key(content.labels[GridKeys.keyCode(for: cell, in: grid)] ?? "?", in: box(CellRange(cell), in: grid),
                        selected: content.selection?.contains(cell) ?? false,
                        anchor: content.pending && content.selection?.anchor == cell)
                }
            }
        }
        if content.joining, let highlight = content.highlight { joiningBadge(in: local(highlight)) }
        if let picker = content.picker { bar(picker) }
        let usable = local(display.usable)
        if let title = content.title, !title.isEmpty {
            pill(title, centerX: usable.midX, y: usable.minY + 18, bold: true)
        }
        if let hint = content.hint {
            pill(hint, centerX: usable.midX, y: usable.maxY - 18, bold: false, fromBottom: true)
        }
    }

    @discardableResult
    private func shape(_ rect: CGRect, fill: NSColor?, stroke: NSColor? = nil, width: CGFloat = 1, radius: CGFloat) -> CALayer {
        let shape = CALayer()
        shape.frame = rect
        shape.backgroundColor = fill?.cgColor
        shape.borderColor = stroke?.cgColor
        shape.borderWidth = stroke == nil ? 0 : width
        shape.cornerRadius = radius
        layer?.addSublayer(shape)
        return shape
    }

    private func text(_ string: NSAttributedString, at origin: CGPoint) {
        let text = CATextLayer()
        text.string = string
        text.contentsScale = scale
        text.frame = CGRect(origin: origin, size: string.size())
        layer?.addSublayer(text)
    }

    /// In the middle of the preview: this drop adds a tab.
    private func joiningBadge(in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: "Add as a tab", attributes: attributes)
        let size = text.size()
        let symbol = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold).applying(.init(paletteColors: [.white])))
        let iconWidth: CGFloat = symbol == nil ? 0 : 28
        let box = CGRect(x: rect.midX - (size.width + iconWidth + 28) / 2, y: rect.midY - 20, width: size.width + iconWidth + 28, height: 40)
        shape(box, fill: .controlAccentColor, radius: 20)
        if let symbol, let image = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let icon = CALayer()
            icon.contents = image
            icon.contentsScale = scale
            icon.contentsGravity = .resizeAspect
            icon.frame = CGRect(x: box.minX + 14, y: box.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height)
            layer?.addSublayer(icon)
        }
        self.text(text, at: CGPoint(x: box.minX + 14 + iconWidth, y: box.midY - size.height / 2))
    }

    private func bar(_ picker: SlotPicker) {
        shape(local(picker.frame), fill: NSColor(white: 0.1, alpha: 0.88), stroke: .white.withAlphaComponent(0.18), radius: 12)
        for (index, layout) in picker.layouts.enumerated() {
            let tile = local(picker.tiles[index])
            for (zone, unit) in layout.enumerated() {
                let hovered = picker.hovered == SlotPicker.Hit(layout: index, zone: zone)
                shape(picker.rect(of: unit, in: tile), fill: hovered ? .controlAccentColor : .white.withAlphaComponent(0.3), radius: 3)
            }
            if picker.hovered?.layout == index {
                shape(tile.insetBy(dx: -2.5, dy: -2.5), fill: nil, stroke: .white.withAlphaComponent(0.7), width: 1.5, radius: 5)
            }
        }
    }

    private func key(_ label: String, in rect: CGRect, selected: Bool, anchor: Bool) {
        let size = max(min(rect.height * 0.2, rect.width * 0.2, 40), 12)
        let string = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(selected ? 1 : 0.85),
        ])
        let textSize = string.size()
        let side = max(textSize.width + size * 0.8, size * 1.8)
        let cap = CGRect(x: rect.midX - side / 2, y: rect.midY - size * 0.9, width: side, height: size * 1.8)
        shape(cap, fill: selected ? .controlAccentColor : .black.withAlphaComponent(0.45),
              stroke: anchor ? .white : .white.withAlphaComponent(selected ? 0.6 : 0.25), width: anchor ? 3 : 1, radius: size * 0.35)
        text(string, at: CGPoint(x: cap.midX - textSize.width / 2, y: cap.midY - textSize.height / 2))
    }

    private func pill(_ string: String, centerX: CGFloat, y: CGFloat, bold: Bool, fromBottom: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: bold ? .semibold : .regular),
            .foregroundColor: NSColor.white,
        ]
        var text = NSAttributedString(string: string, attributes: attributes)
        // Long window titles are cut, not wrapped.
        let maxWidth = bounds.width - 80
        if text.size().width > maxWidth {
            var cut = string
            while text.size().width > maxWidth, cut.count > 1 {
                cut.removeLast()
                text = NSAttributedString(string: cut + "…", attributes: attributes)
            }
        }
        let size = text.size()
        let box = CGRect(x: centerX - size.width / 2 - 12, y: fromBottom ? y - size.height - 10 : y,
                         width: size.width + 24, height: size.height + 10)
        shape(box, fill: .black.withAlphaComponent(0.6), radius: box.height / 2)
        self.text(text, at: CGPoint(x: box.minX + 12, y: box.minY + 5))
    }

    // MARK: - Mouse

    /// The cell under a point in this view, or nil outside the usable area.
    private func cell(at point: CGPoint) -> CellRange.Cell? {
        guard let grid = content.grid else { return nil }
        let usable = local(display.usable)
        guard usable.contains(point) else { return nil }
        let unit = CGPoint(x: (point.x - usable.minX) / usable.width, y: (point.y - usable.minY) / usable.height)
        return CellRange.cell(at: unit, in: grid)
    }

    override func mouseDown(with event: NSEvent) {
        guard let cell = cell(at: convert(event.locationInWindow, from: nil)) else {
            drag = nil
            overlay?.onCancel?()
            return
        }
        drag = CellRange(cell)
        overlay?.onCells?(CellRange(cell), false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var range = drag, let grid = content.grid else { return }
        let point = convert(event.locationInWindow, from: nil)
        let usable = local(display.usable)
        let unit = CGPoint(x: min(max((point.x - usable.minX) / usable.width, 0), 0.999),
                           y: min(max((point.y - usable.minY) / usable.height, 0), 0.999))
        range.cursor = CellRange.cell(at: unit, in: grid)
        guard range != drag else { return }
        drag = range
        overlay?.onCells?(range, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let range = drag else { return }
        drag = nil
        overlay?.onCells?(range, true)
    }
}
