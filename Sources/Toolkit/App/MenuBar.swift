import AppKit

/// One piece of the toolkit's menu bar item.
struct MenuBarSegment: Equatable {
    enum Kind: Equatable { case toolkit, capture, recording, mixer }

    let kind: Kind
    /// Drawn in the menu bar's own colour, like macOS's icons.
    var glyph: NSImage?
    /// Drawn as it is: the recording's red dot.
    var colored: NSImage?
    var text: String?
    /// The text greyed, as for a muted volume.
    var dimText = false
    /// For VoiceOver and the tooltip.
    var label: String

    static func == (a: MenuBarSegment, b: MenuBarSegment) -> Bool {
        a.kind == b.kind && a.glyph === b.glyph && a.colored === b.colored && a.text == b.text && a.dimText == b.dimText && a.label == b.label
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

    func show(_ segments: [MenuBarSegment]) {
        row.show(segments)
        button?.setAccessibilityLabel(segments.map(\.label).joined(separator: ", "))
        button?.toolTip = segments.count == 1 ? segments[0].label : nil
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
    /// Space on each side of a part's content: a little less than between the
    /// menu bar's items, so the group reads as one.
    static let padding: CGFloat = 5

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
            let width = part.contentWidth + Self.padding * 2
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
/// standard view, changed only when what it shows changes.
final class MenuBarPartView: NSView {
    private let dot = NSImageView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var shown: MenuBarSegment?
    private(set) var contentWidth: CGFloat = 0

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let labelInset: CGFloat = 2
    /// Between an icon and its text; the label's own inset adds to it.
    private static let textGap: CGFloat = 2

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
        label.font = Self.font
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ segment: MenuBarSegment) {
        guard segment != shown else { return }
        let before = shown
        shown = segment
        if before?.colored !== segment.colored { dot.image = segment.colored }
        if before?.glyph !== segment.glyph { icon.image = segment.glyph }
        if before?.text != segment.text { label.stringValue = segment.text ?? "" }
        if before?.dimText != segment.dimText { label.textColor = segment.dimText ? .secondaryLabelColor : .labelColor }
        dot.isHidden = segment.colored == nil
        icon.isHidden = segment.glyph == nil
        label.isHidden = segment.text == nil
        let width = Self.width(of: segment)
        guard width != contentWidth || before == nil else { return layoutContent() }
        contentWidth = width
        layoutContent()
        (superview as? MenuBarRow)?.layoutParts()
    }

    /// As wide as the text with every digit at its widest, so a number
    /// changing doesn't change the width; only a digit more or less does.
    private static func width(of segment: MenuBarSegment) -> CGFloat {
        var width: CGFloat = 0
        for image in [segment.colored, segment.glyph].compactMap({ $0 }) { width += image.size.width }
        if let text = segment.text {
            let widest = String(text.map { $0.isNumber ? "8" : $0 })
            // A label keeps a couple of points inside each edge.
            width += (width > 0 ? textGap : 0) + NSAttributedString(string: widest, attributes: [.font: font]).size().width + labelInset * 2
        }
        return ceil(width)
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        guard let segment = shown else { return }
        var x = MenuBarRow.padding
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
            let size = label.intrinsicContentSize
            label.frame = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: bounds.width - x - MenuBarRow.padding, height: size.height)
        }
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
                MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.glyph("wrench.and.screwdriver.fill"), label: "MacOS Toolkit"),
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
    /// `--test-menu-bar-clicks`: every point across a row, toolkit and a wide
    /// recording part and the mixer, goes to the part it's over, and points on
    /// the dividers and beyond the ends to the nearest edge.
    static func clickTest() {
        _ = NSApplication.shared
        let row = MenuBarRow()
        row.show([
            MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.glyph("wrench.and.screwdriver.fill"), label: "MacOS Toolkit"),
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
