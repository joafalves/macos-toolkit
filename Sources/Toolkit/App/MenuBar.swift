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
/// bar gets a segment of it, side by side, so they move together, can't be
/// split up by other apps' icons, and look alike: the same size, spacing and
/// highlight. The strip is a single image, so macOS tints it like its own.
final class MenuBarItem: NSObject {
    /// A segment was clicked: which, where in the item's button, and whether
    /// it was a right-click (or a click with ⌃).
    var onClick: ((MenuBarSegment.Kind, NSRect, Bool) -> Void)?

    private let item: NSStatusItem
    private var segments: [MenuBarSegment] = []
    /// Where each segment sits in the image, left to right.
    private var spans: [(kind: MenuBarSegment.Kind, range: ClosedRange<CGFloat>)] = []
    private var imageWidth: CGFloat = 0
    /// Shown pressed while its menu or panel is open.
    private var pressed: MenuBarSegment.Kind?

    private static let height: CGFloat = 22
    /// Space on each side of a segment's content: a little less than between
    /// the menu bar's items, so the group reads as one.
    private static let padding: CGFloat = 5
    /// The hairline between segments.
    private static let divider: CGFloat = 1

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Remembers where it was dragged to with ⌘.
        item.autosaveName = "MacOS Toolkit"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageOnly
        // macOS draws its own highlight behind the whole item; the item adds
        // none of its own on top.
        (item.button?.cell as? NSButtonCell)?.highlightsBy = []
    }

    var button: NSStatusBarButton? { item.button }

    func show(_ segments: [MenuBarSegment]) {
        guard segments != self.segments else { return }
        self.segments = segments
        draw()
    }

    func setPressed(_ kind: MenuBarSegment.Kind?) {
        guard kind != pressed else { return }
        pressed = kind
        draw()
    }

    /// Where a segment is in the button, for a popover or menu to hang from.
    func rect(of kind: MenuBarSegment.Kind) -> NSRect? {
        guard let button, let span = spans.first(where: { $0.kind == kind }) else { return nil }
        let offset = (button.bounds.width - imageWidth) / 2
        return NSRect(x: offset + span.range.lowerBound, y: 0, width: span.range.upperBound - span.range.lowerBound, height: button.bounds.height)
    }

    @objc private func clicked() {
        guard let button, let window = button.window else { return }
        let event = NSApp.currentEvent
        // From the pointer's place on screen: macOS hands the button every
        // click as if it landed in its middle.
        let point = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let x = point.x - (button.bounds.width - imageWidth) / 2
        // Between or beside the segments counts as the nearest one.
        guard let span = spans.first(where: { $0.range.contains(x) })
                ?? spans.min(by: { abs(($0.range.lowerBound + $0.range.upperBound) / 2 - x) < abs(($1.range.lowerBound + $1.range.upperBound) / 2 - x) }),
              let rect = rect(of: span.kind)
        else { return }
        let right = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        onClick?(span.kind, rect, right)
    }

    // MARK: - Drawing

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private func draw() {
        guard let button else { return }
        var tint = NSColor.black
        // A coloured piece means the image can't be a template: then the rest
        // is drawn in the menu bar's text colour, worked out here.
        button.effectiveAppearance.performAsCurrentDrawingAppearance { tint = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor }
        let (image, spans) = Self.render(segments, pressed: pressed, textColor: tint)
        imageWidth = image.size.width
        self.spans = spans
        button.image = image
        button.toolTip = segments.count == 1 ? segments[0].label : nil
        item.length = NSStatusItem.variableLength
    }

    /// The strip and where each segment sits in it. A template, which macOS
    /// colours, unless a segment has a coloured piece; then it's drawn in
    /// `textColor`.
    static func render(_ segments: [MenuBarSegment], pressed: MenuBarSegment.Kind?, textColor: NSColor)
        -> (NSImage, [(kind: MenuBarSegment.Kind, range: ClosedRange<CGFloat>)]) {
        let template = !segments.contains { $0.colored != nil }
        let tint = template ? NSColor.black : textColor
        var x: CGFloat = 0
        var spans: [(kind: MenuBarSegment.Kind, range: ClosedRange<CGFloat>)] = []
        var pieces: [(MenuBarSegment, CGFloat, CGFloat)] = []
        for (index, segment) in segments.enumerated() {
            if index > 0 { x += divider }
            let width = contentWidth(segment) + padding * 2
            pieces.append((segment, x, width))
            spans.append((segment.kind, x...(x + width)))
            x += width
        }
        let image = NSImage(size: NSSize(width: max(x, 1), height: height), flipped: false) { _ in
            for (index, (segment, left, _)) in pieces.enumerated() {
                if index > 0 {
                    // A hairline between segments, like a grouped control's.
                    tint.withAlphaComponent(0.3).setFill()
                    NSRect(x: left - divider, y: (height - 12) / 2, width: divider, height: 12).fill()
                }
                // With one segment's menu or panel open, the others step back:
                // macOS's own highlight is the only background.
                let alpha: CGFloat = pressed != nil && segment.kind != pressed ? 0.4 : 1
                drawContent(segment, at: left + padding, tint: template ? nil : tint, alpha: alpha)
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = segments.map(\.label).joined(separator: ", ")
        return (image, spans)
    }

    private static func contentWidth(_ segment: MenuBarSegment) -> CGFloat {
        var width: CGFloat = 0
        for image in [segment.colored, segment.glyph].compactMap({ $0 }) { width += image.size.width }
        if let text = segment.text {
            width += (width > 0 ? 4 : 0) + NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        return ceil(width)
    }

    /// The pieces left to right, centred on the strip. `tint` nil means a
    /// template, drawn in black for macOS to colour.
    private static func drawContent(_ segment: MenuBarSegment, at left: CGFloat, tint: NSColor?, alpha: CGFloat) {
        var x = left
        if let colored = segment.colored {
            colored.draw(in: NSRect(x: x, y: (height - colored.size.height) / 2, width: colored.size.width, height: colored.size.height),
                         from: .zero, operation: .sourceOver, fraction: alpha)
            x += colored.size.width
        }
        if let glyph = segment.glyph {
            let rect = NSRect(x: x, y: (height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
            (tint.map { tinted(glyph, $0) } ?? glyph).draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            x += glyph.size.width
        }
        if let text = segment.text {
            if segment.colored != nil || segment.glyph != nil { x += 4 }
            let color = (tint ?? .black).withAlphaComponent((segment.dimText ? 0.5 : 1) * alpha)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            string.draw(at: NSPoint(x: x, y: (height - string.size().height) / 2))
        }
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// The glyphs the menu bar item is made of.
enum MenuBarArt {
    /// A menu bar glyph at the size macOS draws its own status symbols, as
    /// wide as the glyph. Squeezing symbols into the square 18pt box shrank
    /// the wide ones to a fraction of the menu bar's other icons.
    static func glyph(_ symbol: String, description: String? = nil) -> NSImage {
        image(symbol, widthOf: [symbol], description: description) ?? NSImage()
    }

    /// Every symbol is drawn at the same size, in an image as wide as the
    /// widest of `widthOf`, so a glyph that switches between them doesn't
    /// change width. The glyph sits at the left, like macOS's Sound icon.
    static func image(_ symbol: String, widthOf symbols: [String], description: String? = nil) -> NSImage? {
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
            glyph.draw(in: NSRect(x: 0, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description ?? symbol
        return image
    }

    static let volumeSymbols = ["speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]

    /// The speaker macOS's own Sound item uses: more waves as the volume goes
    /// up, crossed out when muted.
    static func speaker(volume: Float, muted: Bool) -> NSImage? {
        let symbol: String
        if muted || volume <= 0 {
            symbol = "speaker.slash.fill"
        } else {
            symbol = volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
        return image(symbol, widthOf: volumeSymbols)
    }

    /// A pill filled up to the volume, with the speaker and the number cut out
    /// of it, like the battery's icon with its percentage inside. Always as wide as "100", so
    /// the menu bar doesn't shift as the number changes.
    static func volumeBadge(volume: Float, muted: Bool) -> NSImage {
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
        let image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "stop.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.white, paused ? .systemOrange : .systemRed])))
        image?.isTemplate = false
        return image
    }
}
