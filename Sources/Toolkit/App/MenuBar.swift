import AppKit

/// One piece of the toolkit's menu bar item.
struct MenuBarSegment: Equatable {
    enum Kind: Hashable {
        case toolkit, capture, recording, awake, mixer, mouse, layout
        /// One of System Stats' stats, or all of them in the compact layout.
        case stat(StatKind), stats

        /// Whose place in the order it takes: a recording takes Screen Capture's.
        var tool: MenuBarTool {
            switch self {
            case .toolkit: return .toolkit
            case .stat, .stats: return .stats
            case .capture, .recording: return .capture
            case .awake: return .awake
            case .mixer: return .mixer
            case .mouse: return .mouse
            case .layout: return .layout
            }
        }
    }

    let kind: Kind
    /// Drawn in the menu bar's own colour, like macOS's icons.
    var glyph: NSImage?
    /// Drawn as it is: the recording's red dot.
    var colored: NSImage?
    var text: String?
    /// The text greyed, as for a muted volume.
    var dimText = false
    /// The glyph and text in a colour of their own, as memory under pressure.
    var tint: NSColor?
    /// Small text, two lines to a column, in place of `text`.
    var columns: [NSAttributedString]?
    /// The widest `text` can get ("100%"): the part keeps that width, the text
    /// to its right edge, so a digit more or less doesn't shift the menu bar.
    var widthOf: String?
    /// Text wider than `widthOf` ("100%" in the room of "99%") is fitted into
    /// that width, a little tighter and into its margins, rather than
    /// widening the part.
    var fitted = false
    /// For VoiceOver and the tooltip.
    var label: String

    static func == (a: MenuBarSegment, b: MenuBarSegment) -> Bool {
        a.kind == b.kind && a.glyph === b.glyph && a.colored === b.colored && a.text == b.text && a.dimText == b.dimText
            && a.tint == b.tint && a.columns == b.columns && a.widthOf == b.widthOf && a.fitted == b.fitted && a.label == b.label
    }
}

/// The toolkit's one menu bar item. Every tool that wants a place in the menu
/// bar gets a part of it, side by side, so they move together and can't be
/// split up by other apps' icons. The parts are laid out by a row of views,
/// and the item shows them as one image, the button's own: macOS draws an
/// item's image itself on every display, sharp at each one's resolution, and
/// dims a template one on a display that isn't active, as it does its own
/// icons. Views in the button were copied onto the other displays as a
/// picture: never dimmed, and blurry on a Retina one beside a 1x one.
final class MenuBarItem: NSObject {
    /// A part was clicked: which, where in the item's button, and whether it
    /// was a right-click (or a click with ⌃).
    var onClick: ((MenuBarSegment.Kind, NSRect, Bool) -> Void)?

    private let item: NSStatusItem
    /// Not in the button: it lays the parts out, and says what to draw.
    private let row = MenuBarRow()
    /// What the button's image shows now: a new image only when this changes.
    private var drawn: MenuBarDrawing?
    private var drawnLower: CGFloat?
    private var placeObservers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var dark: Bool?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Remembers where it was dragged to with ⌘.
        item.autosaveName = "MacOS Toolkit"
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        row.onResize = { [weak self] in self?.fit() }
        // An image in colours of its own has the label colour drawn into it:
        // drawn again for a light or dark menu bar. A template one macOS colours.
        // Only on a real change: setting the image tells observers too, and
        // drawing again on that went round without end.
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] button, _ in
            let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            DispatchQueue.main.async {
                guard let self, dark != self.dark else { return }
                self.dark = dark
                self.render(again: true)
            }
        }
        // Placed, moved to another display, or the displays changed: the
        // middle of the menu bar is worked out again (`lower`).
        let center = NotificationCenter.default
        let placed: (Notification) -> Void = { [weak self] note in
            guard let self, note.object as? NSWindow === self.button?.window else { return }
            self.render()
        }
        placeObservers = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main, using: placed),
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main, using: placed),
            // Displays connected, removed or changed: measured again.
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.measured = [:]
                self?.render()
            },
        ]
    }

    var button: NSStatusBarButton? { item.button }

    /// Whether a point on screen (AppKit coordinates) is on the item. A click
    /// there also reaches global monitors, as macOS draws the item outside
    /// the app; panels that close on clicks elsewhere leave it to the item.
    func contains(screenPoint point: NSPoint) -> Bool {
        button?.window?.frame.contains(point) ?? false
    }

    /// Out of the menu bar, for tests.
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func show(_ segments: [MenuBarSegment]) {
        row.show(segments)
        render()
        button?.setAccessibilityLabel(segments.map(\.label).joined(separator: ", "))
        button?.toolTip = segments.count == 1 ? segments[0].label : nil
    }

    /// Between two tools, and between one tool's own parts.
    func setSeparators(between: MenuBarSeparator, within: MenuBarSeparator) {
        guard row.separator != between || row.toolSeparator != within else { return }
        row.separator = between
        row.toolSeparator = within
        render()
    }

    /// Points between two parts; half of it on each side of every part.
    var spacing: CGFloat {
        get { row.padding * 2 }
        set {
            row.padding = (newValue / 2).rounded()
            render()
        }
    }

    /// While a part's menu or panel is open, the other parts step back.
    func setPressed(_ kind: MenuBarSegment.Kind?) {
        row.setPressed(kind)
        render()
    }

    /// A part's menu, opened as the item's own: macOS keeps the whole item
    /// lit while it's open only for a menu attached this way (it ignores an
    /// app's own highlight on a menu bar item). Returns once it has closed.
    func open(_ menu: NSMenu, for kind: MenuBarSegment.Kind) {
        setPressed(kind)
        item.menu = menu
        button?.performClick(nil)
        // Detached again, or every click would open it instead of reaching the parts.
        item.menu = nil
        setPressed(nil)
    }

    /// Where a part is in the button, for a popover or menu to hang from.
    func rect(of kind: MenuBarSegment.Kind) -> NSRect? {
        guard let button, let frame = row.frame(of: kind) else { return nil }
        return NSRect(x: rowX + frame.minX, y: 0, width: frame.width, height: button.bounds.height)
    }

    /// Where the row's left edge is in the button: the image is centred in it.
    private var rowX: CGFloat {
        guard let button else { return 0 }
        return ((button.bounds.width - row.frame.width) / 2).rounded()
    }

    /// The item as wide as the row. Only when the row's width changes: a part
    /// added or removed, or a number growing a digit.
    private func fit() {
        // No margin of its own: macOS puts the same gap around every item.
        item.length = row.frame.width
        render()
    }

    /// A new image for the button, only if what it shows has changed: the
    /// same drawing again (a reading that didn't move) costs nothing.
    private func render(again: Bool = false) {
        let drawing = row.drawing(), lower = lower()
        guard again || drawing != drawn || lower != drawnLower else { return }
        // Again only matters for colours of its own; macOS colours a template.
        if again, drawing == drawn, lower == drawnLower, drawing.isTemplate { return }
        drawn = drawing
        drawnLower = lower
        button?.image = drawing.image(lower: lower)
    }

    /// How far below the middle of its place the image is drawn, so it's in
    /// the middle of the menu bar. macOS puts an item's 22 pt place in the
    /// middle of some menu bars and not others (a point high in a 30 pt one,
    /// measured: 6 pt over a part, 8 under; centred in a 33 pt one beside a
    /// notch), and the place's frame says which: it matched both.
    ///
    /// Each display needs its own, whether it shows the item or macOS's copy
    /// of it (measured: the copy on the 30 pt bar was a point high too), and
    /// they all share the one image. With several displays, the main one's
    /// is kept, so nothing moves as the active display changes: the main
    /// display is always right, another can be a point off. It's known once
    /// the item has been on the main display; until then, the display it's on.
    /// Whole points, so it's sharp on a 1x display too.
    private func lower() -> CGFloat {
        guard let button, let place = button.superview, let window = button.window, let screen = window.screen else { return 0 }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        // No menu bar showing (hidden, or full screen), or not placed yet.
        guard bar > 0, window.frame.height >= place.frame.height else { return 0 }
        let middle = window.convertToScreen(place.convert(place.bounds, to: nil)).midY
        let here = (middle - (screen.frame.maxY - bar / 2)).rounded()
        guard let number = Self.number(of: screen) else { return here }
        measured[number] = here
        guard NSScreen.screens.count > 1, let main = NSScreen.screens.first.flatMap(Self.number) else { return here }
        return measured[main] ?? here
    }

    /// What each display needs (`lower`), as measured while the item was on it.
    private var measured: [CGDirectDisplayID: CGFloat] = [:]

    private static func number(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    @objc private func clicked() {
        guard let button, let window = button.window else { return }
        let event = NSApp.currentEvent
        // From the pointer's place on screen: macOS hands the button every
        // click as if it landed in its middle.
        let point = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard let kind = row.kind(at: point.x - rowX), let rect = rect(of: kind) else { return }
        // ⌃ from the keyboard as it is now: the click event macOS hands over
        // is made up, and its modifiers can't be trusted.
        let right = event?.type == .rightMouseUp || NSEvent.modifierFlags.contains(.control)
        onClick?(kind, rect, right)
    }
}

/// The parts side by side with a separator between each, laid out by hand:
/// each part as wide as its content, which for numbers means as wide as their
/// widest digits, so the menu bar doesn't shift as they change.
final class MenuBarRow: NSView {
    /// Called when the row's width changes.
    var onResize: (() -> Void)?

    private var parts: [MenuBarSegment.Kind: MenuBarPartView] = [:]
    private var order: [MenuBarSegment.Kind] = []
    private var dividers: [MenuBarDivider] = []
    private var pressed: MenuBarSegment.Kind?

    static let height: CGFloat = 22
    /// Space on each side of a part's content, between two parts: by default a
    /// little less than between the menu bar's items, so the group reads as
    /// one. Set in Settings. Not at the item's two ends, where macOS already
    /// leaves its own gap, as for any item.
    var padding: CGFloat = 6 {
        didSet {
            guard padding != oldValue else { return }
            parts.values.forEach { $0.needsLayout = true }
            layoutParts()
        }
    }
    /// Set in Settings: between two tools, and between one tool's own parts.
    var separator = MenuBarSeparator.pipe {
        didSet { if separator != oldValue { layoutParts() } }
    }
    var toolSeparator = MenuBarSeparator.dot {
        didSet { if toolSeparator != oldValue { layoutParts() } }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: Self.height))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go to the button, which knows what each part does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ segments: [MenuBarSegment]) {
        let kinds = segments.map(\.kind)
        for kind in parts.keys where !kinds.contains(kind) {
            parts.removeValue(forKey: kind)?.removeFromSuperview()
        }
        for segment in segments {
            let part = parts[segment.kind] ?? {
                let part = MenuBarPartView()
                addSubview(part)
                parts[segment.kind] = part
                return part
            }()
            part.show(segment)
        }
        order = kinds
        while dividers.count < max(kinds.count - 1, 0) {
            let divider = MenuBarDivider()
            addSubview(divider)
            dividers.append(divider)
        }
        while dividers.count > max(kinds.count - 1, 0) { dividers.removeLast().removeFromSuperview() }
        applyPressed()
        layoutParts()
    }

    func setPressed(_ kind: MenuBarSegment.Kind?) {
        guard kind != pressed else { return }
        pressed = kind
        applyPressed()
    }

    private func applyPressed() {
        for (kind, part) in parts {
            part.alphaValue = pressed != nil && kind != pressed ? 0.4 : 1
        }
    }

    func frame(of kind: MenuBarSegment.Kind) -> NSRect? { parts[kind]?.frame }

    /// Everything the row shows, where it is in the row, as the views draw it.
    func drawing() -> MenuBarDrawing {
        var elements: [MenuBarDrawing.Element] = []
        for kind in order {
            guard let part = parts[kind] else { continue }
            elements += part.elements(offset: part.frame.origin, alpha: part.alphaValue)
        }
        for divider in dividers where divider.superview != nil && divider.style != .none {
            elements.append(.divider(divider.style, rect: divider.frame))
        }
        return MenuBarDrawing(size: frame.size, elements: elements)
    }

    /// The part under the point. On a divider or beside the row, the part
    /// whose edge is nearest: by centres, a wide part (the recording, with its
    /// time) lost clicks well inside it to a narrow neighbour.
    func kind(at x: CGFloat) -> MenuBarSegment.Kind? {
        if let hit = order.first(where: { parts[$0].map { $0.frame.minX <= x && x < $0.frame.maxX } ?? false }) { return hit }
        func distance(_ kind: MenuBarSegment.Kind) -> CGFloat {
            guard let frame = parts[kind]?.frame else { return .infinity }
            return x < frame.minX ? frame.minX - x : x - frame.maxX
        }
        return order.min { distance($0) < distance($1) }
    }

    private static func sameTool(_ a: MenuBarSegment.Kind, _ b: MenuBarSegment.Kind) -> Bool {
        if case .stat = a, case .stat = b { return true }
        return false
    }

    /// Positions the parts; tells the item only if the width changed.
    func layoutParts() {
        var x: CGFloat = 0
        for (index, kind) in order.enumerated() {
            guard let part = parts[kind] else { continue }
            if index > 0 {
                let divider = dividers[index - 1]
                divider.style = Self.sameTool(order[index - 1], kind) ? toolSeparator : separator
                let size = switch divider.style {
                case .none: NSSize.zero
                case .dot: NSSize(width: 2, height: 2)
                case .pipe: NSSize(width: 1, height: 12)
                }
                divider.frame = NSRect(x: x, y: (Self.height - size.height) / 2, width: size.width, height: size.height)
                x += size.width
            }
            let insets = (leading: index == 0 ? 0 : padding, trailing: index == order.count - 1 ? 0 : padding)
            if part.insets != insets { part.insets = insets }
            let width = part.contentWidth + insets.leading + insets.trailing
            part.frame = NSRect(x: x, y: 0, width: width, height: Self.height)
            x += width
        }
        let width = max(x, 1)
        guard width != frame.width else { return }
        setFrameSize(NSSize(width: width, height: Self.height))
        onResize?()
    }
}

/// One part: the coloured dot (recording), the icon, and the text, each a
/// view of its own, changed only when what it shows changes.
final class MenuBarPartView: NSView {
    private let dot = MenuBarImage()
    private let icon = MenuBarImage()
    private let label = MenuBarText()
    private var columns: [MenuBarText] = []
    private var shown: MenuBarSegment?
    private(set) var contentWidth: CGFloat = 0
    /// Set by the row: its padding, but none at the item's ends.
    var insets: (leading: CGFloat, trailing: CGFloat) = (6, 6) {
        // Straight away: the item's row isn't in a window to lay it out later.
        didSet { layoutContent() }
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let labelInset: CGFloat = 2
    /// Between an icon and its text; the label's own inset adds to it.
    private static let textGap: CGFloat = 2
    /// Between columns of small text.
    private static let columnGap: CGFloat = 6

    init() {
        super.init(frame: .zero)
        addSubview(dot)
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ segment: MenuBarSegment) {
        guard segment != shown else { return }
        let before = shown
        shown = segment
        if before?.colored !== segment.colored { dot.image = segment.colored }
        if before?.glyph !== segment.glyph { icon.image = segment.glyph }
        if before?.text != segment.text || before?.dimText != segment.dimText || before?.tint != segment.tint || before?.widthOf != segment.widthOf
            || before?.fitted != segment.fitted {
            let style = NSMutableParagraphStyle()
            style.alignment = segment.widthOf == nil ? .left : .right
            label.text = NSAttributedString(string: segment.text ?? "", attributes: [
                .font: Self.font, .foregroundColor: segment.tint ?? (segment.dimText ? NSColor.secondaryLabelColor : .labelColor),
                .paragraphStyle: style, .kern: Self.overflows(segment) ? Self.fittedKern : 0,
            ])
        }
        if before?.tint != segment.tint { icon.tint = segment.tint }
        if before?.columns != segment.columns { showColumns(segment.columns ?? []) }
        dot.isHidden = segment.colored == nil
        icon.isHidden = segment.glyph == nil
        label.isHidden = segment.text == nil
        let width = Self.width(of: segment)
        guard width != contentWidth || before == nil else { return layoutContent() }
        contentWidth = width
        layoutContent()
        (superview as? MenuBarRow)?.layoutParts()
    }

    private func showColumns(_ texts: [NSAttributedString]) {
        while columns.count < texts.count {
            let column = MenuBarText()
            addSubview(column)
            columns.append(column)
        }
        while columns.count > texts.count { columns.removeLast().removeFromSuperview() }
        for (column, text) in zip(columns, texts) { column.text = text }
    }

    /// As wide as the text with every digit at its widest, so a number
    /// changing doesn't change the width; only a digit more or less does.
    private static func width(of segment: MenuBarSegment) -> CGFloat {
        var width: CGFloat = 0
        for image in [segment.colored, segment.glyph].compactMap({ $0 }) { width += image.size.width }
        if let text = segment.text {
            // A label keeps a couple of points inside each edge.
            let widest = segment.fitted ? widest(segment.widthOf ?? text, nil, font) : widest(text, segment.widthOf, font)
            width += (width > 0 ? textGap : 0) + widest + labelInset * 2
        }
        if let columns = segment.columns, !columns.isEmpty {
            width += (width > 0 ? textGap : 0) + columns.map(columnWidth).reduce(0, +) + columnGap * CGFloat(columns.count - 1)
        }
        return ceil(width)
    }

    /// How much tighter fitted text is set when it's wider than its template.
    private static let fittedKern: CGFloat = -0.5

    /// Fitted text wider than its template: "100%" where "99%" is the widest
    /// that has room.
    private static func overflows(_ segment: MenuBarSegment) -> Bool {
        guard segment.fitted, let text = segment.text, let template = segment.widthOf else { return false }
        return widest(text, nil, font) > widest(template, nil, font)
    }

    /// Text as wide as it can get: its digits at their widest, and no
    /// narrower than its template.
    static func widest(_ text: String, _ template: String?, _ font: NSFont) -> CGFloat {
        [text, template].compactMap { $0 }.map { string in
            NSAttributedString(string: String(string.map { $0.isNumber ? "8" : $0 }), attributes: [.font: font]).size().width
        }.max() ?? 0
    }

    /// The widest line of a column, each as wide as its template.
    private static func columnWidth(_ text: NSAttributedString) -> CGFloat {
        let font = text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        var widest: CGFloat = 0
        // Runs with the same template come as one; each line is measured alone.
        text.enumerateAttribute(MenuBarArt.widthOfKey, in: NSRange(location: 0, length: text.length)) { template, range, _ in
            for line in (text.string as NSString).substring(with: range).split(separator: "\n") {
                widest = max(widest, Self.widest(String(line), template as? String, font ?? MenuBarArt.smallFont))
            }
        }
        return ceil(widest) + labelInset * 2
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    /// Laid out again straight away: the item's row isn't in a window, which
    /// would otherwise do it on the next pass. Sized by the row after `show`,
    /// its content was placed for a height of nothing, nine points low.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { layoutContent() }
    }

    /// What the part shows, moved by `offset`, at its opacity.
    func elements(offset: NSPoint, alpha: CGFloat) -> [MenuBarDrawing.Element] {
        func moved(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: offset.x, dy: offset.y) }
        var elements: [MenuBarDrawing.Element] = []
        for view in [dot, icon] where !view.isHidden {
            if let image = view.image { elements.append(.image(image, tint: view.tint, rect: moved(view.frame), alpha: alpha)) }
        }
        for text in [label] + columns where !text.isHidden && text.text.length > 0 {
            elements.append(.text(text.text, rect: moved(text.frame), alpha: alpha))
        }
        return elements
    }

    private func layoutContent() {
        guard let segment = shown else { return }
        var x = insets.leading
        let height = bounds.height
        if let image = segment.colored {
            dot.frame = NSRect(x: x, y: ((height - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
            x += image.size.width
        }
        if let image = segment.glyph {
            icon.frame = NSRect(x: x, y: ((height - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
            x += image.size.width
        }
        if segment.text != nil {
            // Fitted text that's too wide takes the gap as well as its margins.
            if segment.colored != nil || segment.glyph != nil, !Self.overflows(segment) { x += Self.textGap }
            let size = label.size
            label.frame = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: bounds.width - x - insets.trailing, height: size.height)
            x += size.width
        }
        if let texts = segment.columns, !texts.isEmpty {
            if segment.colored != nil || segment.glyph != nil || segment.text != nil { x += Self.textGap }
            for (column, text) in zip(columns, texts) {
                let width = Self.columnWidth(text)
                let size = column.size
                column.frame = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: width, height: size.height)
                x += width + Self.columnGap
            }
        }
    }
}

/// An image in the item, a template one in the text colour or a colour of its
/// own. Drawn by `draw(_:tint:in:template:)`, for the item's image and for
/// this view in a snapshot alike.
final class MenuBarImage: NSView {
    var image: NSImage? {
        didSet { if image !== oldValue { needsDisplay = true } }
    }
    /// For a template image: a colour of its own, or nil for the text's.
    var tint: NSColor? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    /// Not vibrant, as for the text.
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        Self.draw(image, tint: tint, in: bounds, template: false)
    }

    /// In the middle of `bounds`, on whole points. Into a template drawing as
    /// it is, black; otherwise a template image is filled with its colour.
    static func draw(_ image: NSImage, tint: NSColor?, in bounds: NSRect, template: Bool) {
        let rect = NSRect(x: bounds.minX + ((bounds.width - image.size.width) / 2).rounded(),
                          y: bounds.minY + ((bounds.height - image.size.height) / 2).rounded(),
                          width: image.size.width, height: image.size.height)
        guard !template, image.isTemplate, let context = NSGraphicsContext.current?.cgContext else { return image.draw(in: rect) }
        // The template's shape, filled with the colour at the colour's own
        // opacity: the label colour lets a touch of the menu bar through, as
        // macOS's icons do. Over the template's black (source-atop) it came
        // out an opaque grey.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        (tint ?? .labelColor).setFill()
        rect.fill(using: .sourceIn)
        context.endTransparencyLayer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Text in the item. Drawn by `draw(_:size:template:)`, for the item's image
/// and for this view in a snapshot alike. Never a text field: one in the
/// item, even hidden, kept macOS 27 redrawing it without end.
final class MenuBarText: NSView {
    var text = NSAttributedString() {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
        }
    }

    /// A couple of points of room on each side, as a text field has.
    static let inset: CGFloat = 2

    var size: NSSize {
        let bounds = text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin])
        return NSSize(width: ceil(bounds.width) + Self.inset * 2, height: ceil(bounds.height))
    }

    /// Not vibrant: macOS draws template icons, its own and other apps', in
    /// the plain label colour, and vibrancy blended ours with what's behind
    /// the menu bar, a blue cast on a blue desktop (measured), and red pink.
    override var allowsVibrancy: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Self.draw(text, size: bounds.size, template: false)
    }

    /// From the top left of a flipped context `size` big. Into a template
    /// drawing, the label colours become black at their opacity.
    static func draw(_ text: NSAttributedString, size: NSSize, template: Bool) {
        // Fitted text too wide for its margins (MenuBarSegment.fitted) uses them.
        let inset = ceil(text.size().width) > size.width - Self.inset * 2 ? 0 : Self.inset
        (template ? MenuBarDrawing.black(text) : text)
            .draw(with: NSRect(x: inset, y: 0, width: size.width - inset * 2, height: size.height), options: [.usesLineFragmentOrigin])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// What goes between two parts of the menu bar item.
enum MenuBarSeparator: String, Codable, CaseIterable {
    case none
    case dot
    /// A hairline.
    case pipe
}

/// What goes between one tool's own parts: its own choice, or the one between tools.
enum MenuBarToolSeparator: String, Codable, CaseIterable {
    case same
    case none
    case dot
    case pipe

    func resolved(_ between: MenuBarSeparator) -> MenuBarSeparator {
        switch self {
        case .same: return between
        case .none: return .none
        case .dot: return .dot
        case .pipe: return .pipe
        }
    }
}

/// The separator between parts, in the menu bar's text colour, faint: a dot
/// or a hairline, the same faintness either way. Not vibrant, like the icons and text.
final class MenuBarDivider: NSView {
    override var allowsVibrancy: Bool { false }

    var style = MenuBarSeparator.pipe {
        didSet { if style != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.draw(style, in: bounds, template: false)
    }

    static func draw(_ style: MenuBarSeparator, in rect: NSRect, template: Bool) {
        (template ? NSColor.black : .labelColor).withAlphaComponent(0.35).setFill()
        switch style {
        case .none: break
        case .dot: NSBezierPath(ovalIn: rect).fill()
        case .pipe: rect.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// What the item shows, as plain data: the images, text and dividers, each
/// where it is in the row. Compared with the last to skip an image that would
/// be the same, and kept by the image, which macOS may draw again later for
/// another display, so it can't read from views that have changed since.
struct MenuBarDrawing: Equatable {
    enum Element: Equatable {
        case image(NSImage, tint: NSColor?, rect: NSRect, alpha: CGFloat)
        case text(NSAttributedString, rect: NSRect, alpha: CGFloat)
        case divider(MenuBarSeparator, rect: NSRect)

        static func == (a: Element, b: Element) -> Bool {
            switch (a, b) {
            case let (.image(i, t, r, o), .image(j, u, s, p)): return i === j && t == u && r == s && o == p
            case let (.text(t, r, o), .text(u, s, p)): return t == u && r == s && o == p
            case let (.divider(d, r), .divider(e, s)): return d == e && r == s
            default: return false
            }
        }
    }

    var size: NSSize
    var elements: [Element]

    /// A template when everything is in the label colours: then macOS colours
    /// it like its own icons, and dims it on a display that isn't active. A
    /// colour of its own (the recording's dot, memory under pressure) can't
    /// be a template, so then it's drawn in its colours.
    var isTemplate: Bool {
        elements.allSatisfy { element in
            switch element {
            case let .image(image, tint, _, _): return tint == nil && image.isTemplate
            case let .text(text, _, _): return Self.plain(text)
            case .divider: return true
            }
        }
    }

    /// `lower` moves everything down in the image.
    func image(lower: CGFloat) -> NSImage {
        let elements = self.elements, template = isTemplate
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: -lower)
            for element in elements {
                context.saveGState()
                switch element {
                case let .image(image, tint, rect, alpha):
                    context.setAlpha(alpha)
                    MenuBarImage.draw(image, tint: tint, in: rect, template: template)
                case let .text(text, rect, alpha):
                    context.setAlpha(alpha)
                    // Text is laid out from the top, as in its flipped view.
                    context.translateBy(x: rect.minX, y: rect.maxY)
                    context.scaleBy(x: 1, y: -1)
                    let flipped = NSGraphicsContext(cgContext: context, flipped: true)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = flipped
                    MenuBarText.draw(text, size: rect.size, template: template)
                    NSGraphicsContext.restoreGraphicsState()
                case let .divider(style, rect):
                    MenuBarDivider.draw(style, in: rect, template: template)
                }
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "MacOS Toolkit"
        return image
    }

    private static func plain(_ text: NSAttributedString) -> Bool {
        var plain = true
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, _, stop in
            if let color = color as? NSColor, color != .labelColor, color != .secondaryLabelColor {
                plain = false
                stop.pointee = true
            }
        }
        return plain
    }

    /// The text in black, as a template has it: the secondary colour at half.
    static func black(_ text: NSAttributedString) -> NSAttributedString {
        let black = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, range, _ in
            let secondary = (color as? NSColor) == .secondaryLabelColor
            black.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(secondary ? 0.5 : 1), range: range)
        }
        return black
    }
}

/// The glyphs the menu bar item is made of.
enum MenuBarArt {
    /// Made once each: drawing a symbol is the costly part of an update, and
    /// the same image also means the view showing it has nothing to redraw.
    private static var cache: [String: NSImage] = [:]

    private static func cached(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let image = cache[key] { return image }
        let image = make()
        cache[key] = image
        return image
    }

    /// For images whose text keeps changing, a time or a reading: only the
    /// last one of each is kept. Kept them all, a countdown left one behind
    /// every minute, without end when it counts up. The same reading again is
    /// still the same image, so it has nothing to redraw.
    private static var latest: [String: (key: String, image: NSImage)] = [:]

    private static func latest(_ slot: String, _ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let last = latest[slot], last.key == key { return last.image }
        let image = make()
        latest[slot] = image.map { (key, $0) }
        return image
    }

    /// The toolkit's own glyph, the app icon's four tools: one filled, the
    /// others outlined, so it still reads as a kit in one colour.
    static let toolkit: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 18), flipped: false) { rect in
            // Whole points, so every edge falls on a pixel of a 1x display too;
            // the app icon's proportions, near enough.
            let side: CGFloat = 7, gap: CGFloat = 2
            for i in 0..<4 {
                let square = NSRect(x: rect.midX - side - gap / 2 + CGFloat(i % 2) * (side + gap),
                                    y: rect.midY - side - gap / 2 + CGFloat(1 - i / 2) * (side + gap),
                                    width: side, height: side)
                NSColor.black.set()
                if i == 0 {
                    NSBezierPath(roundedRect: square, xRadius: 1.8, yRadius: 1.8).fill()
                } else {
                    let outline = NSBezierPath(roundedRect: square.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.4, yRadius: 1.4)
                    outline.lineWidth = 1
                    outline.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacOS Toolkit"
        return image
    }()

    /// A menu bar glyph at the size macOS draws its own status symbols, as
    /// wide as the glyph. Squeezing symbols into the square 18pt box shrank
    /// the wide ones to a fraction of the menu bar's other icons.
    static func glyph(_ symbol: String, description: String? = nil) -> NSImage {
        cached("glyph \(symbol)") { image(symbol, widthOf: [symbol], description: description) } ?? NSImage()
    }

    /// Every symbol is drawn at the same size, in an image as wide as the
    /// widest of `widthOf`, so a glyph that switches between them doesn't
    /// change width. The glyph sits at the left, like macOS's Sound icon.
    static func image(_ symbol: String, widthOf symbols: [String], description: String? = nil, alignRight: Bool = false) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        func symbolImage(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        guard let glyph = symbolImage(symbol) else { return nil }
        let width = ceil(([glyph.size.width] + symbols.compactMap { symbolImage($0)?.size.width }).max() ?? glyph.size.width)
        let height: CGFloat = 18
        // Only symbols taller than the menu bar allows are scaled down.
        let fit = min(1, height / glyph.size.height)
        let size = NSSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            // On whole points, sharp on a 1x display as well.
            glyph.draw(in: NSRect(x: alignRight ? (rect.maxX - size.width).rounded() : 0, y: (rect.midY - size.height / 2).rounded(),
                                  width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description ?? symbol
        return image
    }

    // Outline, as every icon in the item is unless it says something is on.
    static let volumeSymbols = ["speaker.slash", "speaker.wave.1", "speaker.wave.2", "speaker.wave.3"]

    /// The speaker without waves, for beside the percentage, which already
    /// says how loud: as wide as its muted version, so neither leaves a gap.
    static func plainSpeaker(muted: Bool) -> NSImage? {
        let symbol = muted ? "speaker.slash" : "speaker"
        // Against the number, whichever is shown.
        return cached("plain speaker \(symbol)") { image(symbol, widthOf: ["speaker", "speaker.slash"], alignRight: true) }
    }

    /// The speaker macOS's own Sound item uses: more waves as the volume goes
    /// up, crossed out when muted.
    static func speaker(volume: Float, muted: Bool) -> NSImage? {
        let symbol: String
        if muted || volume <= 0 {
            symbol = "speaker.slash"
        } else {
            symbol = volume < 0.34 ? "speaker.wave.1" : volume < 0.67 ? "speaker.wave.2" : "speaker.wave.3"
        }
        return cached("speaker \(symbol)") { image(symbol, widthOf: volumeSymbols) }
    }

    /// The volume as a pill: filled up to the volume, like the battery's
    /// charge, with the speaker and the number cut out. Muted, it's empty, with
    /// the speaker crossed out and the volume kept, as with the percentage, so
    /// you can see what unmuting brings back. `small` leaves the number out.
    static func volumeBadge(volume: Float, muted: Bool, small: Bool = false) -> NSImage {
        // By whole percent, which is all it shows.
        let percent = Int((min(1, max(0, volume)) * 100).rounded())
        return pill("volume", symbol: muted ? "speaker.slash.fill" : "speaker.fill", fraction: muted ? nil : Double(percent) / 100,
                    content: small ? nil : .text("\(percent)"))
    }

    /// Keep Awake's icon: sleep while off, wake while on, in the room of
    /// either. Against the time when there is one, which would otherwise sit after a gap.
    static func awakeIcon(on: Bool, beforeText: Bool = false) -> NSImage? {
        let symbol = AwakeController.symbol(on: on)
        return cached("awake \(symbol) \(beforeText)") { image(symbol, widthOf: [false, true].map(AwakeController.symbol), alignRight: beforeText) }
    }

    /// Keep Awake as a pill: filled with the time left, macOS's wake symbol
    /// and the time cut out. With no end it's full with ∞ (or the time it's
    /// been on); off, it's empty, with macOS's sleep symbol, the same one in
    /// its other state, and zzz, since the Mac sleeps as usual. `small` leaves
    /// the time out: the fill alone tells it. `fraction` is nil while it's off.
    static func awakeBadge(fraction: Double?, time: String?, small: Bool = false) -> NSImage {
        let content: PillContent? = small ? nil : fraction == nil ? .symbol("zzz") : .text(time ?? "∞")
        return pill("awake", symbol: AwakeController.symbol(on: fraction != nil), fraction: fraction, content: content)
    }

    // MARK: - Pills

    /// What a pill shows after its symbol.
    enum PillContent: Equatable {
        case text(String)
        case symbol(String)
    }

    /// The pill System Stats, Keep Awake and the mixer share, so they look
    /// alike side by side: 16pt high, filled up to a share in the label colour
    /// over a faint track, the symbol and text cut out. Every pill is one
    /// width, whatever it shows, so the menu bar never shifts and pills line
    /// up; without content it's the small pill, one width too. Each part is
    /// centred by its ink, measured, not by its box: a symbol's box and a
    /// font's metrics leave the ink up to a point off. `fraction` nil is
    /// empty: off, muted, or nothing read.
    static func pill(_ slot: String, symbol: String, fraction: Double?, content: PillContent?) -> NSImage {
        // By whole percent: finer than anything it fills with.
        let percent = fraction.map { Int((min(1, max(0, $0)) * 100).rounded()) }
        let key = "\(symbol) \(percent.map(String.init) ?? "empty") \(String(describing: content))"
        return latest("pill \(slot)", key) {
            makePill(symbol: symbol, fraction: percent.map { Double($0) / 100 }, content: content)
        } ?? NSImage()
    }

    private enum Pill {
        static let height: CGFloat = 16
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        // From the left end to the symbol's ink, from it to the text's, and
        // from that to the right end. The symbol's side has a point more: a
        // symbol is taller than the digits, so its corners come nearer the round end.
        static let lead: CGFloat = 4.5, gap: CGFloat = 2.75, trail: CGFloat = 3.25
        static let smallMargin: CGFloat = 4.5
        /// The text's room: Keep Awake's longest time, which holds "100" too.
        static let template = "8:88"
        /// The symbol's room: the widest of these. A wider one (the disk)
        /// grows toward the text rather than the edge.
        static let slotSymbols = ["cpu", "memorychip", "cube", "wake"]
        static let slot: CGFloat = slotSymbols.compactMap { name in MenuBarArt.pillSymbol(name).map { MenuBarArt.ink(of: $0, key: name).width } }.max() ?? 10
    }

    private static func pillSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(Pill.symbolConfiguration)
    }

    /// Where an image's ink is, in points within it: drawn once at 2x and
    /// measured. Kept by `key`, which names one of a fixed set of symbols.
    private static var inks: [String: CGRect] = [:]
    private static func ink(of image: NSImage, key: String) -> CGRect {
        if let ink = inks[key] { return ink }
        let ink = measureInk(size: image.size) { image.draw(in: NSRect(origin: .zero, size: image.size)) }
        inks[key] = ink
        return ink
    }

    private static func measureInk(size: NSSize, _ draw: () -> Void) -> CGRect {
        let scale = 2
        let width = Int(ceil(size.width)) * scale, height = Int(ceil(size.height)) * scale
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.bitmapData else { return NSRect(origin: .zero, size: size) }
        rep.size = NSSize(width: ceil(size.width), height: ceil(size.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where data[y * rep.bytesPerRow + x * 4 + 3] > 100 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return NSRect(origin: .zero, size: size) }
        // Rows run top down; points up.
        let s = CGFloat(scale)
        return NSRect(x: CGFloat(minX) / s, y: CGFloat(height - 1 - maxY) / s, width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    /// Text's ink across, from the glyphs' outlines: where it starts after the pen, and how wide.
    private static func textInk(_ text: NSAttributedString) -> (minX: CGFloat, width: CGFloat) {
        let bounds = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
        return (bounds.minX, bounds.width)
    }

    /// The template's ink, from where `draw(at:)` puts it: its width is the
    /// text's room, and every text sits on its baseline, so "1:24" and "100" line up.
    private static let templateRows: CGRect = {
        let text = NSAttributedString(string: Pill.template, attributes: [.font: Pill.font, .foregroundColor: NSColor.black])
        return measureInk(size: text.size()) { text.draw(at: .zero) }
    }()

    private static func makePill(symbol: String, fraction: Double?, content: PillContent?) -> NSImage {
        let small = content == nil
        let slot = Pill.slot
        let rows = templateRows
        let templateWidth = rows.width
        let exact = small ? Pill.smallMargin * 2 + slot : Pill.lead + slot + Pill.gap + templateWidth + Pill.trail
        let width = ceil(exact)
        // What rounding up adds goes half to each end.
        let extra = (width - exact) / 2
        let slotX = (small ? Pill.smallMargin : Pill.lead) + extra
        let textCentre = width - Pill.trail - extra - templateWidth / 2
        let glyph = pillSymbol(symbol)
        let glyphInk = glyph.map { ink(of: $0, key: symbol) } ?? .zero
        let pill = NSRect(x: 0, y: 1, width: width, height: Pill.height)
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            // On the display's pixels, so a half point rounds away on a 1x display rather than blurring.
            let scale = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2
            func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
            let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            NSColor.black.withAlphaComponent(0.4).setFill()
            shape.fill()
            if let fraction {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                // Two lots of 40% would show where they overlap, so the fill replaces it.
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.black.setFill()
                NSRect(x: pill.minX, y: pill.minY, width: pill.width * CGFloat(fraction), height: pill.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if let glyph {
                var x = slotX + (slot - glyphInk.width) / 2
                if !small { x = max(x, slotX) }
                glyph.draw(in: NSRect(x: snap(x - glyphInk.minX), y: snap(pill.midY - glyphInk.height / 2 - glyphInk.minY),
                                      width: glyph.size.width, height: glyph.size.height), from: .zero, operation: .destinationOut, fraction: 1)
            }
            switch content {
            case .symbol(let name):
                if let mark = pillSymbol(name) {
                    let markInk = ink(of: mark, key: name)
                    mark.draw(in: NSRect(x: snap(textCentre - markInk.width / 2 - markInk.minX), y: snap(pill.midY - markInk.height / 2 - markInk.minY),
                                         width: mark.size.width, height: mark.size.height), from: .zero, operation: .destinationOut, fraction: 1)
                }
            case .text(let string):
                let text = NSAttributedString(string: string, attributes: [.font: Pill.font, .foregroundColor: NSColor.black])
                let across = textInk(text)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                text.draw(at: NSPoint(x: snap(textCentre - across.width / 2 - across.minX), y: snap(pill.midY - rows.height / 2 - rows.minY)))
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case nil:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }


    // MARK: - System Stats

    static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)

    /// A line of small text, in the menu bar's colour or a tint of its own,
    /// as wide as its template, so the column doesn't shift.
    struct Line: Equatable {
        var text: String
        var tint: NSColor?
        var widthOf: String?
    }

    /// Where a column keeps each line's template.
    static let widthOfKey = NSAttributedString.Key("dev.jalves.macos-toolkit.widthOf")

    /// Up to two lines, tight enough to fill the menu bar's height together.
    static func column(_ lines: [Line]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 10.5
        style.maximumLineHeight = 10.5
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: line.tint ?? NSColor.labelColor, .paragraphStyle: style]
            attributes[widthOfKey] = line.widthOf
            text.append(NSAttributedString(string: (index > 0 ? "\n" : "") + line.text, attributes: attributes))
        }
        return text
    }

    /// A stat as a pill, filled to its share, its symbol and number cut out;
    /// `small` leaves the number out.
    static func fillBadge(symbol: String, fraction: Double, text: String, small: Bool = false) -> NSImage {
        pill("stat \(symbol)", symbol: symbol, fraction: fraction, content: small ? nil : .text(text))
    }


    /// The last readings as a small chart after the stat's own small symbol,
    /// so two charts side by side can be told apart: a faint area under a
    /// line, and a second series as a dashed line. Up to `ceiling`, or the
    /// highest reading. Made anew with each reading, so not cached; it's a few
    /// dozen points.
    static func sparkline(_ values: [Double], symbol: String, ceiling: Double? = nil, second: [Double]? = nil, count: Int = 30) -> NSImage {
        let mark = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        let markWidth = ceil(mark?.size.width ?? 0)
        let size = NSSize(width: markWidth + 3 + 30, height: 18)
        let top = max(ceiling ?? max(values.max() ?? 0, second?.max() ?? 0), 1e-9)
        let image = NSImage(size: size, flipped: false) { _ in
            if let mark {
                mark.draw(in: NSRect(x: 0, y: ((size.height - mark.size.height) / 2).rounded(), width: mark.size.width, height: mark.size.height))
            }
            let frame = NSRect(x: markWidth + 3.5, y: 2.5, width: 29, height: 13)
            // A baseline, so an idle chart still reads as one.
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSRect(x: frame.minX, y: frame.minY - 0.5, width: frame.width, height: 1).fill()
            func path(_ values: [Double]) -> NSBezierPath? {
                guard values.count > 1 else { return nil }
                let step = frame.width / CGFloat(max(count - 1, 1))
                let start = frame.maxX - step * CGFloat(values.count - 1)
                let path = NSBezierPath()
                for (index, value) in values.enumerated() {
                    let point = NSPoint(x: start + step * CGFloat(index), y: frame.minY + frame.height * CGFloat(min(1, max(0, value / top))))
                    index == 0 ? path.move(to: point) : path.line(to: point)
                }
                return path
            }
            if let line = path(values) {
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: frame.maxX, y: frame.minY))
                area.line(to: NSPoint(x: frame.maxX - frame.width / CGFloat(max(count - 1, 1)) * CGFloat(values.count - 1), y: frame.minY))
                area.close()
                NSColor.black.withAlphaComponent(0.35).setFill()
                area.fill()
                NSColor.black.setStroke()
                line.lineWidth = 1.2
                line.lineJoinStyle = .round
                line.stroke()
            }
            if let second, let line = path(second) {
                NSColor.black.withAlphaComponent(0.6).setStroke()
                line.lineWidth = 1
                line.setLineDash([2, 1.5], count: 2, phase: 0)
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 1:05, or 1:02:05 past the hour.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// The recording's dot: red while it records, orange while paused.
    static func recordingDot(paused: Bool) -> NSImage? {
        cached("dot \(paused)") { makeDot(paused: paused) }
    }

    private static func makeDot(paused: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "stop.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.white, paused ? .systemOrange : .systemRed])))
        image?.isTemplate = false
        return image
    }
}

extension MenuBarRow {
    /// `--test-menu-bar`: what an update costs. A real item in the menu bar
    /// gets a new recording time and volume ten times a second for ten
    /// seconds; the CPU time spent is reported. Real, because most of the cost
    /// is macOS taking a new picture of the item for the menu bar: a row in a
    /// window of its own came to a quarter of it.
    static func selfTest() {
        _ = NSApplication.shared
        let item = MenuBarItem()
        func segments(_ tick: Int) -> [MenuBarSegment] {
            let volume = Float(tick % 100) / 100
            return [
                MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit"),
                MenuBarSegment(kind: .recording, colored: MenuBarArt.recordingDot(paused: false),
                               text: MenuBarArt.duration(TimeInterval(tick)) + " · " + MenuBarArt.bytes(Int64(tick) * 120_000), label: "Recording"),
                MenuBarSegment(kind: .mixer, glyph: MenuBarArt.speaker(volume: volume, muted: false), text: "\(Int(volume * 100))%", label: "Audio Mixer"),
            ]
        }
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        item.show(segments(0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // The same loop with nothing changing, to take out what waking up costs.
        func measure(_ update: (Int) -> Void) -> Double {
            let start = cpu()
            for tick in 1...100 {
                update(tick)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            return cpu() - start
        }
        let idle = measure { _ in }
        let busy = measure { item.show(segments($0)) }
        item.remove()
        let each = (busy - idle) * 10
        print(String(format: "an update: %.2f ms of CPU (%.1f ms for 100, %.1f ms of that the loop itself); once a second that's %.3f%% of one core",
                     each, busy * 1000, idle * 1000, each / 10))
    }
}

extension MenuBarRow {
    /// `--test-menu-bar-idle`: a row showing each kind of part, left alone,
    /// should cost nothing; a part whose layout keeps asking for another
    /// layout shows here as CPU spent with nothing changing.
    static func idleTest() {
        _ = NSApplication.shared
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let stats = StatsController.preview()
        let cases: [(String, [MenuBarSegment])] = [
            ("toolkit only", [MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit")]),
            ("text", [MenuBarSegment(kind: .stat(.cpu), glyph: MenuBarArt.glyph("cpu"), text: "23%", label: "CPU")]),
            ("tinted text", [MenuBarSegment(kind: .stat(.memory), glyph: MenuBarArt.glyph("memorychip"), text: "59%", tint: .systemYellow, label: "Memory")]),
            ("columns", [MenuBarSegment(kind: .stat(.network), columns: [MenuBarArt.column([.init(text: "↑ 48 KB/s"), .init(text: "↓ 1.2 MB/s")])], label: "Network")]),
            ("pill", [MenuBarSegment(kind: .stat(.cpu), glyph: MenuBarArt.fillBadge(symbol: "cpu", fraction: 0.2, text: "20"), label: "CPU")]),
            ("chart", [MenuBarSegment(kind: .stat(.cpu), glyph: MenuBarArt.sparkline([0.1, 0.3, 0.2], symbol: "cpu", ceiling: 1), text: "20%", label: "CPU")]),
            ("all stats", stats.segments()),
        ]
        for (name, segments) in cases {
            let row = MenuBarRow()
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 500, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView?.addSubview(row)
            window.orderFrontRegardless()
            row.show(segments)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let start = cpu()
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            print(String(format: "%@: %.1f%% of a core, left alone", name, (cpu() - start) / 2 * 100))
            window.orderOut(nil)
        }
        // A real item in the menu bar, as the app has it, with each kind of part.
        let toolkit = MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit")
        for (name, segments) in cases.dropFirst() + [("toolkit only", [])] {
            let item = MenuBarItem()
            item.show([toolkit] + segments.filter { $0.kind != .toolkit })
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let start = cpu()
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            print(String(format: "in the menu bar, %@: %.1f%% of a core", name, (cpu() - start) / 3 * 100))
            item.remove()
        }
    }
}

extension MenuBarRow {
    /// `--test-menu-bar-tint <png>`: memory under pressure, yellow and red,
    /// in a real menu bar item, captured to check the colours survive the
    /// menu bar's vibrancy. Run with `open -n` for Screen Recording.
    static func tintTest(into path: String) {
        _ = NSApplication.shared
        let item = MenuBarItem()
        item.show([
            MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit"),
            MenuBarSegment(kind: .stat(.cpu), glyph: MenuBarArt.glyph("cpu"), text: "23%", widthOf: "99%", label: "CPU"),
            MenuBarSegment(kind: .stat(.memory), glyph: MenuBarArt.glyph("memorychip"), text: "81%", tint: .systemYellow, widthOf: "99%", label: "Memory"),
            MenuBarSegment(kind: .stats, columns: [MenuBarArt.column([.init(text: "CPU 23%", widthOf: "CPU 99%"), .init(text: "MEM 96%", tint: .systemRed, widthOf: "MEM 99%")])], label: "Stats"),
        ])
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let window = item.button?.window else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let frame = window.frame, top = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY
        task.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", path]
        try? task.run()
        task.waitUntilExit()
        item.remove()
    }
}

extension MenuBarRow {
    /// `--test-menu-bar-widths`: a part keeps its width as its figure changes,
    /// a digit more or less included, so the menu bar doesn't shift.
    static func widthTest() {
        _ = NSApplication.shared
        var failures = 0
        func widths(_ name: String, _ segments: [MenuBarSegment]) {
            let row = MenuBarRow()
            let found = segments.map { segment -> CGFloat in
                row.show([segment])
                return row.frame.width
            }
            let same = Set(found).count == 1
            if !same { failures += 1 }
            print((same ? "ok    " : "FAIL  ") + "\(name): " + found.map { "\(Int($0))" }.joined(separator: ", "))
        }
        func percent(_ kind: StatKind, _ symbol: String) -> [MenuBarSegment] {
            [0.05, 0.42, 1].map { MenuBarSegment(kind: .stat(kind), glyph: MenuBarArt.glyph(symbol), text: StatsController.percent($0), widthOf: StatsController.widest(kind), label: "") }
        }
        widths("cpu", percent(.cpu, "cpu"))
        widths("memory", percent(.memory, "memorychip"))
        widths("power", ["7.4 W", "12 W", "120 W"].map { MenuBarSegment(kind: .stat(.power), glyph: MenuBarArt.glyph("bolt"), text: $0, widthOf: StatsController.widest(.power), label: "") })
        widths("disk", ["9 GB", "312 GB", "1.2 TB"].map { MenuBarSegment(kind: .stat(.disk), glyph: MenuBarArt.glyph("internaldrive"), text: $0, widthOf: StatsController.widest(.disk), label: "") })
        widths("network", [("0 KB/s", "8 KB/s"), ("48 KB/s", "1.2 MB/s"), ("120 MB/s", "888 KB/s")].map { up, down in
            MenuBarSegment(kind: .stat(.network), columns: [MenuBarArt.column([.init(text: "↑ " + up, widthOf: "↑ 888 MB/s"), .init(text: "↓ " + down, widthOf: "↓ 888 MB/s")])], label: "")
        })
        widths("compact", [(0.05, 0.09), (0.42, 0.61), (1, 1)].map { cpu, memory in
            MenuBarSegment(kind: .stats, columns: [MenuBarArt.column([.init(text: "CPU " + StatsController.percent(cpu), widthOf: "CPU 99%"),
                                                                      .init(text: "MEM " + StatsController.percent(memory), widthOf: "MEM 99%")])], label: "")
        })
        // Two lines with the same template are still measured one at a time.
        let same = MenuBarArt.column([.init(text: "A 1", widthOf: "A 888"), .init(text: "A 2", widthOf: "A 888")])
        let alone = MenuBarArt.column([.init(text: "A 1", widthOf: "A 888")])
        widths("a column of two like lines", [MenuBarSegment(kind: .stats, columns: [same], label: ""), MenuBarSegment(kind: .stats, columns: [alone], label: "")])
        widths("keep awake, 10 h", ["10:00", "9:59", "0:05"].map { MenuBarSegment(kind: .awake, glyph: MenuBarArt.awakeIcon(on: true, beforeText: true), text: $0, widthOf: "10:00", label: "") })
        widths("volume and percentage", [(0.0, true), (0.05, false), (0.62, false), (1.0, false)].map { volume, muted in
            MenuBarSegment(kind: .mixer, glyph: MenuBarArt.plainSpeaker(muted: muted), text: "\(Int(volume * 100))%", widthOf: "99%", fitted: true, label: "")
        })
        // Every pill one width, whatever tool, figure or state, and every small pill another.
        widths("pills", [
            MenuBarArt.fillBadge(symbol: "cpu", fraction: 0.05, text: "5"), MenuBarArt.fillBadge(symbol: "memorychip", fraction: 1, text: "100"),
            MenuBarArt.fillBadge(symbol: "internaldrive", fraction: 0.69, text: "69"), MenuBarArt.fillBadge(symbol: "cube", fraction: 0, text: "–"),
            MenuBarArt.awakeBadge(fraction: nil, time: nil), MenuBarArt.awakeBadge(fraction: 0.5, time: "12h"), MenuBarArt.awakeBadge(fraction: 0.5, time: "0:05"),
            MenuBarArt.awakeBadge(fraction: 1, time: nil), MenuBarArt.volumeBadge(volume: 0.6, muted: false), MenuBarArt.volumeBadge(volume: 1, muted: false),
            MenuBarArt.volumeBadge(volume: 0.6, muted: true),
        ].map { MenuBarSegment(kind: .awake, glyph: $0, label: "") })
        widths("small pills", [
            MenuBarArt.fillBadge(symbol: "cpu", fraction: 0.4, text: "40", small: true), MenuBarArt.fillBadge(symbol: "internaldrive", fraction: 1, text: "100", small: true),
            MenuBarArt.awakeBadge(fraction: nil, time: nil, small: true), MenuBarArt.awakeBadge(fraction: 0.5, time: nil, small: true),
            MenuBarArt.volumeBadge(volume: 0.6, muted: false, small: true), MenuBarArt.volumeBadge(volume: 0.6, muted: true, small: true),
        ].map { MenuBarSegment(kind: .awake, glyph: $0, label: "") })
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }
}

extension MenuBarRow {
    /// `--test-menu-bar-clicks`: every point across a row, toolkit and a wide
    /// recording part and the mixer, goes to the part it's over, and points on
    /// the dividers and beyond the ends to the nearest edge.
    static func clickTest() {
        _ = NSApplication.shared
        let row = MenuBarRow()
        row.show([
            MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit"),
            MenuBarSegment(kind: .recording, colored: MenuBarArt.recordingDot(paused: false), text: "0:42 · 3.1 MB", label: "Recording"),
            MenuBarSegment(kind: .mixer, glyph: MenuBarArt.speaker(volume: 0.6, muted: false), text: "60%", label: "Audio Mixer"),
        ])
        var wrong: [String] = []
        for x in stride(from: -10, through: row.frame.width + 10, by: 0.5) {
            let expected: MenuBarSegment.Kind? = [MenuBarSegment.Kind.toolkit, .recording, .mixer].first { kind in
                guard let frame = row.frame(of: kind) else { return false }
                return frame.minX <= x && x < frame.maxX
            }
            let got = row.kind(at: x)
            if let expected, got != expected { wrong.append("x \(x): \(String(describing: got)) instead of \(expected)") }
            if expected == nil, x < 0, got != .toolkit { wrong.append("x \(x) before the row: \(String(describing: got))") }
            if expected == nil, x >= row.frame.width, got != .mixer { wrong.append("x \(x) after the row: \(String(describing: got))") }
        }
        let frames = [MenuBarSegment.Kind.toolkit, .recording, .mixer].compactMap { row.frame(of: $0) }.map { "\(Int($0.minX))–\(Int($0.maxX))" }
        print("parts at \(frames.joined(separator: ", ")); " + (wrong.isEmpty ? "ok: every point went to its part" : "FAIL:\n" + wrong.prefix(10).joined(separator: "\n")))
    }
}
