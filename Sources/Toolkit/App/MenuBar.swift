import AppKit

/// One piece of the toolkit's menu bar item.
struct MenuBarSegment: Equatable {
    enum Kind: Hashable {
        case toolkit, capture, recording, awake, mixer
        /// One of System Stats' stats, or all of them in the compact layout.
        case stat(StatKind), stats
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
    /// For VoiceOver and the tooltip.
    var label: String

    static func == (a: MenuBarSegment, b: MenuBarSegment) -> Bool {
        a.kind == b.kind && a.glyph === b.glyph && a.colored === b.colored && a.text == b.text && a.dimText == b.dimText
            && a.tint == b.tint && a.columns == b.columns && a.widthOf == b.widthOf && a.label == b.label
    }
}

/// The toolkit's one menu bar item. Every tool that wants a place in the menu
/// bar gets a part of it, side by side, so they move together and can't be
/// split up by other apps' icons. The parts are ordinary views in a row
/// inside the item's button: a change touches only the view it changes, and
/// macOS colours their icons and text like its own.
final class MenuBarItem: NSObject {
    /// A part was clicked: which, where in the item's button, and whether it
    /// was a right-click (or a click with ⌃).
    var onClick: ((MenuBarSegment.Kind, NSRect, Bool) -> Void)?

    private let item: NSStatusItem
    private let row = MenuBarRow()

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
        button.image = nil
        button.addSubview(row)
        row.onResize = { [weak self] in self?.fit() }
    }

    var button: NSStatusBarButton? { item.button }

    /// Out of the menu bar, for tests.
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func show(_ segments: [MenuBarSegment]) {
        row.show(segments)
        button?.setAccessibilityLabel(segments.map(\.label).joined(separator: ", "))
        button?.toolTip = segments.count == 1 ? segments[0].label : nil
    }

    /// Points between two parts; half of it on each side of every part.
    var spacing: CGFloat {
        get { row.padding * 2 }
        set { row.padding = (newValue / 2).rounded() }
    }

    /// While a part's menu or panel is open, the other parts step back.
    func setPressed(_ kind: MenuBarSegment.Kind?) {
        row.setPressed(kind)
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
        return button.convert(frame, from: row)
    }

    /// The item as wide as the row, the row in the middle of it. Only when the
    /// row's width changes: a part added or removed, or a number growing a digit.
    private func fit() {
        item.length = row.frame.width + 4
        guard let button else { return }
        button.layoutSubtreeIfNeeded()
        row.setFrameOrigin(NSPoint(x: ((button.bounds.width - row.frame.width) / 2).rounded(),
                                   y: ((button.bounds.height - row.frame.height) / 2).rounded()))
    }

    @objc private func clicked() {
        guard let button, let window = button.window else { return }
        let event = NSApp.currentEvent
        // From the pointer's place on screen: macOS hands the button every
        // click as if it landed in its middle.
        let point = row.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard let kind = row.kind(at: point.x), let rect = rect(of: kind) else { return }
        // ⌃ from the keyboard as it is now: the click event macOS hands over
        // is made up, and its modifiers can't be trusted.
        let right = event?.type == .rightMouseUp || NSEvent.modifierFlags.contains(.control)
        onClick?(kind, rect, right)
    }
}

/// The parts side by side with a hairline between each, laid out by hand:
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
    /// Space on each side of a part's content: by default a little less than
    /// between the menu bar's items, so the group reads as one. Set in General.
    var padding: CGFloat = 6 {
        didSet {
            guard padding != oldValue else { return }
            parts.values.forEach { $0.needsLayout = true }
            layoutParts()
        }
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

    /// Positions the parts; tells the item only if the width changed.
    func layoutParts() {
        var x: CGFloat = 0
        for (index, kind) in order.enumerated() {
            guard let part = parts[kind] else { continue }
            if index > 0 {
                dividers[index - 1].frame = NSRect(x: x, y: (Self.height - 12) / 2, width: 1, height: 12)
                x += 1
            }
            let width = part.contentWidth + padding * 2
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
    private let dot = NSImageView()
    private let icon = NSImageView()
    private let label = MenuBarText()
    private var columns: [MenuBarText] = []
    private var shown: MenuBarSegment?
    private(set) var contentWidth: CGFloat = 0

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let labelInset: CGFloat = 2
    /// Between an icon and its text; the label's own inset adds to it.
    private static let textGap: CGFloat = 2
    /// Between columns of small text.
    private static let columnGap: CGFloat = 6

    init() {
        super.init(frame: .zero)
        for view in [dot, icon] {
            view.imageScaling = .scaleNone
            view.isEditable = false
            addSubview(view)
        }
        // Template icons in the text colour, as macOS's own are; left alone,
        // an image view tints them fainter.
        icon.contentTintColor = .labelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ segment: MenuBarSegment) {
        guard segment != shown else { return }
        let before = shown
        shown = segment
        if before?.colored !== segment.colored { dot.image = segment.colored }
        if before?.glyph !== segment.glyph { icon.image = segment.glyph }
        if before?.text != segment.text || before?.dimText != segment.dimText || before?.tint != segment.tint || before?.widthOf != segment.widthOf {
            let style = NSMutableParagraphStyle()
            style.alignment = segment.widthOf == nil ? .left : .right
            label.text = NSAttributedString(string: segment.text ?? "", attributes: [
                .font: Self.font, .foregroundColor: segment.tint ?? (segment.dimText ? NSColor.secondaryLabelColor : .labelColor),
                .paragraphStyle: style,
            ])
        }
        if before?.tint != segment.tint { icon.contentTintColor = segment.tint ?? .labelColor }
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
            width += (width > 0 ? textGap : 0) + widest(text, segment.widthOf, font) + labelInset * 2
        }
        if let columns = segment.columns, !columns.isEmpty {
            width += (width > 0 ? textGap : 0) + columns.map(columnWidth).reduce(0, +) + columnGap * CGFloat(columns.count - 1)
        }
        return ceil(width)
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

    private func layoutContent() {
        guard let segment = shown else { return }
        let padding = (superview as? MenuBarRow)?.padding ?? 6
        var x = padding
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
            if segment.colored != nil || segment.glyph != nil { x += Self.textGap }
            let size = label.size
            label.frame = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: bounds.width - x - padding, height: size.height)
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

/// Text in the menu bar, drawn by the view itself. A text field there (even a
/// hidden one) kept macOS 27 redrawing the whole item without end, at most of
/// a core; a view that draws its own text costs nothing until it changes.
/// Vibrant, so its label colours follow the menu bar like the icons do.
final class MenuBarText: NSView {
    var text = NSAttributedString() {
        didSet {
            guard text != oldValue else { return }
            var colored = false
            text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, _, _ in
                if let color = color as? NSColor, color != .labelColor, color != .secondaryLabelColor { colored = true }
            }
            vibrant = !colored
            needsDisplay = true
        }
    }

    /// Off for a colour of its own: vibrancy blends it with what's behind the
    /// menu bar, and red came out pink.
    private var vibrant = true

    /// A couple of points of room on each side, as a text field has.
    static let inset: CGFloat = 2

    var size: NSSize {
        let bounds = text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin])
        return NSSize(width: ceil(bounds.width) + Self.inset * 2, height: ceil(bounds.height))
    }

    override var allowsVibrancy: Bool { vibrant }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(with: NSRect(x: Self.inset, y: 0, width: bounds.width - Self.inset * 2, height: bounds.height),
                  options: [.usesLineFragmentOrigin])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The hairline between parts, in the menu bar's text colour, faint. Vibrant
/// like the icons and text, so it follows the menu bar the same way.
final class MenuBarDivider: NSView {
    override var allowsVibrancy: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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

    /// The toolkit's own glyph, the app icon's four tools: one filled, the
    /// others outlined, so it still reads as a kit in one colour.
    static let toolkit: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 18), flipped: false) { rect in
            let side: CGFloat = 6.6, gap: CGFloat = 1.8
            for i in 0..<4 {
                let square = NSRect(x: rect.midX - side - gap / 2 + CGFloat(i % 2) * (side + gap),
                                    y: rect.midY - side - gap / 2 + CGFloat(1 - i / 2) * (side + gap),
                                    width: side, height: side)
                NSColor.black.set()
                if i == 0 {
                    NSBezierPath(roundedRect: square, xRadius: 1.8, yRadius: 1.8).fill()
                } else {
                    let outline = NSBezierPath(roundedRect: square.insetBy(dx: 0.65, dy: 0.65), xRadius: 1.3, yRadius: 1.3)
                    outline.lineWidth = 1.3
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
            glyph.draw(in: NSRect(x: alignRight ? rect.maxX - size.width : 0, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description ?? symbol
        return image
    }

    static let volumeSymbols = ["speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]

    /// The speaker without waves, for beside the percentage, which already
    /// says how loud: as wide as its muted version, so neither leaves a gap.
    static func plainSpeaker(muted: Bool) -> NSImage? {
        let symbol = muted ? "speaker.slash.fill" : "speaker.fill"
        // Against the number, whichever is shown.
        return cached("plain speaker \(symbol)") { image(symbol, widthOf: ["speaker.fill", "speaker.slash.fill"], alignRight: true) }
    }

    /// The speaker macOS's own Sound item uses: more waves as the volume goes
    /// up, crossed out when muted.
    static func speaker(volume: Float, muted: Bool) -> NSImage? {
        let symbol: String
        if muted || volume <= 0 {
            symbol = "speaker.slash.fill"
        } else {
            symbol = volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
        return cached("speaker \(symbol)") { image(symbol, widthOf: volumeSymbols) }
    }

    /// A pill filled up to the volume, with the speaker and the number cut out
    /// of it, like the battery's icon with its percentage inside. Always as wide as "100", so
    /// the menu bar doesn't shift as the number changes.
    static func volumeBadge(volume: Float, muted: Bool) -> NSImage {
        // By whole percent, which is all it shows.
        let percent = Int((min(1, max(0, volume)) * 100).rounded())
        return cached("badge \(percent) \(muted)") { makeBadge(volume: Float(percent) / 100, muted: muted) } ?? NSImage()
    }

    private static func makeBadge(volume: Float, muted: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        let text = NSAttributedString(string: muted ? "off" : "\(Int((volume * 100).rounded()))",
                                      attributes: [.font: font, .foregroundColor: NSColor.black])
        let widest = NSAttributedString(string: "100", attributes: [.font: font]).size().width
        let cone = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        let coneWidth = cone?.size.width ?? 8
        // As tall as the other menu bar symbols, about 16pt of the 18pt box.
        let pill = NSRect(x: 0, y: 1, width: ceil(3 + coneWidth + 1 + widest + 3), height: 16)
        let image = NSImage(size: NSSize(width: pill.width, height: 18), flipped: false) { _ in
            // Filled up to the volume like the battery's charge, the rest faint.
            let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            NSColor.black.withAlphaComponent(0.4).setFill()
            shape.fill()
            if !muted {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                // Two lots of 40% would show where they overlap, so the fill replaces it.
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.black.setFill()
                NSRect(x: pill.minX, y: pill.minY, width: pill.width * CGFloat(min(1, max(0, volume))), height: pill.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if let cone {
                cone.draw(in: NSRect(x: 3, y: pill.midY - cone.size.height / 2, width: cone.size.width, height: cone.size.height),
                          from: .zero, operation: .destinationOut, fraction: 1)
            }
            // The number is cut out too, centred in the space after the speaker.
            let size = text.size()
            let area = NSRect(x: 3 + coneWidth + 1, y: pill.minY, width: widest, height: pill.height)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }

    static let cupSymbols = ["cup.and.saucer", "cup.and.heat.waves.fill"]

    /// Keep Awake's cup: empty while off, steaming while on. Against the
    /// time when there is one, which would otherwise sit after a gap.
    static func cup(on: Bool, beforeText: Bool = false) -> NSImage? {
        let symbol = on ? cupSymbols[1] : cupSymbols[0]
        return cached("cup \(symbol) \(beforeText)") { image(symbol, widthOf: cupSymbols, alignRight: beforeText) }
    }

    /// Keep Awake while on, like the volume badge: a pill filled with the time
    /// left, the cup and the time cut out of it. With no end it's full and
    /// holds only the cup. As wide as "8:88" with a time, so the menu bar
    /// doesn't shift as it counts down.
    static func awakeBadge(fraction: Double, time: String?, widthOf: String? = nil) -> NSImage {
        // By whole percent: finer than the minutes it changes with.
        let percent = Int((min(1, max(0, fraction)) * 100).rounded())
        return cached("awake \(percent) \(time ?? "") \(widthOf ?? "")") {
            makeAwakeBadge(fraction: Double(percent) / 100, time: time, widthOf: widthOf)
        } ?? NSImage()
    }

    private static func makeAwakeBadge(fraction: Double, time: String?, widthOf: String?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
        let text = time.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.black]) }
        let widest = time.map { MenuBarPartView.widest($0, widthOf, font) } ?? 0
        let cup = NSImage(systemSymbolName: "cup.and.heat.waves.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        let cupWidth = cup?.size.width ?? 10
        let pill = NSRect(x: 0, y: 1, width: ceil(4 + cupWidth + (time == nil ? 0 : 2 + widest) + 4), height: 16)
        let image = NSImage(size: NSSize(width: pill.width, height: 18), flipped: false) { _ in
            let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            NSColor.black.withAlphaComponent(0.4).setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.black.setFill()
            NSRect(x: pill.minX, y: pill.minY, width: pill.width * CGFloat(fraction), height: pill.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            if let cup {
                cup.draw(in: NSRect(x: 4, y: pill.midY - cup.size.height / 2, width: cup.size.width, height: cup.size.height),
                         from: .zero, operation: .destinationOut, fraction: 1)
            }
            if let text {
                let size = text.size()
                let area = NSRect(x: 4 + cupWidth + 2, y: pill.minY, width: widest, height: pill.height)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                text.draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
                NSGraphicsContext.current?.compositingOperation = .sourceOver
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

    /// A pill filled to a share, the symbol and number cut out of it, like
    /// the volume badge. As wide as two digits, which System Stats' figures
    /// stop at, so it doesn't shift.
    static func fillBadge(symbol: String, fraction: Double, text: String) -> NSImage {
        let percent = Int((min(1, max(0, fraction)) * 100).rounded())
        return cached("fill \(symbol) \(percent) \(text)") { makeFillBadge(symbol: symbol, fraction: Double(percent) / 100, text: text) } ?? NSImage()
    }

    private static func makeFillBadge(symbol: String, fraction: Double, text: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let widest = NSAttributedString(string: "88", attributes: [.font: font]).size().width
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        let glyphWidth = glyph?.size.width ?? 10
        let pill = NSRect(x: 0, y: 1, width: ceil(4 + glyphWidth + 2 + widest + 4), height: 16)
        let image = NSImage(size: NSSize(width: pill.width, height: 18), flipped: false) { _ in
            let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            NSColor.black.withAlphaComponent(0.4).setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.black.setFill()
            NSRect(x: pill.minX, y: pill.minY, width: pill.width * CGFloat(fraction), height: pill.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            if let glyph {
                glyph.draw(in: NSRect(x: 4, y: pill.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height),
                           from: .zero, operation: .destinationOut, fraction: 1)
            }
            let size = string.size()
            let area = NSRect(x: 4 + glyphWidth + 2, y: pill.minY, width: widest, height: pill.height)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            string.draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
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
                mark.draw(in: NSRect(x: 0, y: (size.height - mark.size.height) / 2, width: mark.size.width, height: mark.size.height))
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
    /// `--test-menu-bar`: what an update costs. A row on screen (off to the
    /// side, in a window of its own) gets a new recording time and volume ten
    /// times a second for ten seconds; the CPU time spent is reported.
    static func selfTest() {
        _ = NSApplication.shared
        let row = MenuBarRow()
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        window.orderFrontRegardless()
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
        row.show(segments(0))
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
        let busy = measure { row.show(segments($0)) }
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
        widths("power", ["7.4 W", "12 W", "120 W"].map { MenuBarSegment(kind: .stat(.power), glyph: MenuBarArt.glyph("bolt.fill"), text: $0, widthOf: StatsController.widest(.power), label: "") })
        widths("disk", ["9 GB", "312 GB", "1.2 TB"].map { MenuBarSegment(kind: .stat(.disk), glyph: MenuBarArt.glyph("internaldrive"), text: $0, widthOf: StatsController.widest(.disk), label: "") })
        widths("network", [("0 KB/s", "8 KB/s"), ("48 KB/s", "1.2 MB/s"), ("120 MB/s", "888 KB/s")].map { up, down in
            MenuBarSegment(kind: .stat(.network), columns: [MenuBarArt.column([.init(text: "↑ " + up, widthOf: "↑ 888 MB/s"), .init(text: "↓ " + down, widthOf: "↓ 888 MB/s")])], label: "")
        })
        widths("compact", [(0.05, 0.09), (0.42, 0.61), (1, 1)].map { cpu, memory in
            MenuBarSegment(kind: .stats, columns: [MenuBarArt.column([.init(text: "CPU " + StatsController.percent(cpu), widthOf: "CPU 99%"),
                                                                      .init(text: "MEM " + StatsController.percent(memory), widthOf: "MEM 99%")])], label: "")
        })
        widths("cpu pill", [0.05, 0.42, 1].map { MenuBarSegment(kind: .stat(.cpu), glyph: MenuBarArt.fillBadge(symbol: "cpu", fraction: $0, text: "\(min(99, Int($0 * 100)))"), label: "") })
        // Two lines with the same template are still measured one at a time.
        let same = MenuBarArt.column([.init(text: "A 1", widthOf: "A 888"), .init(text: "A 2", widthOf: "A 888")])
        let alone = MenuBarArt.column([.init(text: "A 1", widthOf: "A 888")])
        widths("a column of two like lines", [MenuBarSegment(kind: .stats, columns: [same], label: ""), MenuBarSegment(kind: .stats, columns: [alone], label: "")])
        widths("volume", ["5%", "60%", "100%"].map { MenuBarSegment(kind: .mixer, glyph: MenuBarArt.plainSpeaker(muted: false), text: $0, widthOf: "100%", label: "") })
        widths("keep awake, 10 h", ["10:00", "9:59", "0:05"].map { MenuBarSegment(kind: .awake, glyph: MenuBarArt.cup(on: true, beforeText: true), text: $0, widthOf: "10:00", label: "") })
        widths("keep awake pill, 10 h", ["10:00", "9:59", "0:05"].map { MenuBarSegment(kind: .awake, glyph: MenuBarArt.awakeBadge(fraction: 0.5, time: $0, widthOf: "10:00"), label: "") })
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
