import AVFoundation
import AppKit

/// The small preview after a capture, in the corner of the display it was
/// taken on. Drag it into an app, click to open it, or let it go away.
final class ThumbnailStack {
    private var shown: [ThumbnailPanel] = []

    /// `file` is nil for a screenshot that only went to the clipboard; one is
    /// written to the temporary folder if it is dragged or opened.
    func show(image: CGImage, scale: CGFloat, file: URL?, isVideo: Bool, on screen: NSScreen?, makeFile: (() -> URL?)? = nil) {
        add(ThumbnailPanel(image: image, file: file, isVideo: isVideo, makeFile: makeFile), on: screen)
    }

    /// What was copied from the screen, that nothing was, or that it's still
    /// being read. Returns what puts the card away.
    @discardableResult
    func show(text: TextThumbnailView.State, on screen: NSScreen?) -> () -> Void {
        let panel = ThumbnailPanel(content: TextThumbnailView(text))
        add(panel, on: screen)
        return { [weak panel] in panel?.onClose?() }
    }

    private func add(_ panel: ThumbnailPanel, on screen: NSScreen?) {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            self.shown.removeAll { $0 === panel }
            self.layout(on: screen)
        }
        shown.insert(panel, at: 0)
        // A few at most; older ones make way.
        while shown.count > 4 { shown.removeLast().orderOut(nil) }
        layout(on: screen)
        panel.orderFrontRegardless()
        if !panel.waits { panel.scheduleDismiss() }
    }

    static func show(video url: URL, in stack: ThumbnailStack, on screen: NSScreen?) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            guard let image else { return }
            DispatchQueue.main.async { stack.show(image: image, scale: 1, file: url, isVideo: true, on: screen) }
        }
    }

    private func layout(on screen: NSScreen) {
        var y = screen.visibleFrame.minY + 16
        for panel in shown {
            let size = panel.frame.size
            panel.setFrame(NSRect(x: screen.visibleFrame.maxX - size.width - 16, y: y, width: size.width, height: size.height), display: true, animate: false)
            y += size.height + 10
        }
    }
}

private final class ThumbnailPanel: CapturePanel {
    var onClose: (() -> Void)?
    private var dismiss: DispatchWorkItem?
    /// Stays until put away, for as long as the reading goes on.
    var waits: Bool { (contentView as? TextThumbnailView)?.state == .reading }

    convenience init(image: CGImage, file: URL?, isVideo: Bool, makeFile: (() -> URL?)?) {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let box: CGFloat = 200
        let size = aspect >= 1 ? NSSize(width: box, height: max(box / aspect, 48)) : NSSize(width: max(box * aspect, 64), height: box)
        let view = ThumbnailView(image: image, file: file, isVideo: isVideo, makeFile: makeFile)
        view.frame.size = size
        self.init(content: view)
    }

    /// Sized to the view.
    init(content view: ThumbnailContent) {
        super.init(frame: NSRect(origin: .zero, size: view.frame.size), level: .popUpMenu)
        hasShadow = true
        view.onClose = { [weak self] in self?.onClose?() }
        view.onHover = { [weak self] inside in
            guard self?.waits == false else { return }
            if inside { self?.dismiss?.cancel() } else { self?.scheduleDismiss() }
        }
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    func scheduleDismiss() {
        dismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onClose?() }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

/// What a thumbnail shows: its panel closes it and keeps it while hovered.
class ThumbnailContent: NSView {
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
}

private final class ThumbnailView: ThumbnailContent, NSDraggingSource {
    private let image: CGImage
    private var file: URL?
    private let isVideo: Bool
    private let makeFile: (() -> URL?)?
    private var downAt: NSPoint?
    private let buttons = NSStackView()

    init(image: CGImage, file: URL?, isVideo: Bool, makeFile: (() -> URL?)?) {
        self.image = image
        self.file = file
        self.isVideo = isVideo
        self.makeFile = makeFile
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let close = Self.button("xmark", help: String(localized: "Dismiss")) { [weak self] in self?.onClose?() }
        buttons.addArrangedSubview(close)
        if file != nil {
            let trash = Self.button("trash", help: String(localized: "Move to Trash")) { [weak self] in self?.trash() }
            buttons.addArrangedSubview(trash)
        }
        buttons.spacing = 6
        buttons.isHidden = true
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        let fit = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
        ctx.draw(image, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        if isVideo, let play = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .regular).applying(.init(paletteColors: [.white, .black.withAlphaComponent(0.45)]))) {
            play.draw(in: NSRect(x: bounds.midX - play.size.width / 2, y: bounds.midY - play.size.height / 2, width: play.size.width, height: play.size.height))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        buttons.isHidden = false
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        buttons.isHidden = true
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, hypot(event.locationInWindow.x - downAt.x, event.locationInWindow.y - downAt.y) > 4 else { return }
        self.downAt = nil
        guard let url = resolvedFile() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(cgImage: image, size: bounds.size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        if let url = resolvedFile() { NSWorkspace.shared.open(url) }
        onClose?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onClose?() }
    }

    private func resolvedFile() -> URL? {
        if file == nil { file = makeFile?() }
        return file
    }

    private func trash() {
        if let file { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
        onClose?()
    }

    static func button(_ symbol: String, help: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        button.bezelStyle = .circular
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.contentTintColor = .white
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}

private final class ClosureButton: NSButton {
    var handler: () -> Void

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(run)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func run() { handler() }
}

/// The text just copied, its first few lines, or that there was none. Drag it
/// into an app for the text again; a click puts it away.
final class TextThumbnailView: ThumbnailContent, NSDraggingSource {
    enum State: Equatable {
        case copied(String)
        case none
        /// Taking long: the first time ever, macOS readies its text
        /// recognition for the app, which takes it some 25 seconds.
        case reading
    }

    let state: State
    private var text: String? {
        if case .copied(let text) = state { return text }
        return nil
    }
    private var downAt: NSPoint?
    private let close: NSButton

    init(_ state: State) {
        self.state = state
        close = ThumbnailView.button("xmark", help: String(localized: "Dismiss")) {}
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        let symbol: String, heading: String, detail: String
        switch state {
        case .copied(let text): (symbol, heading, detail) = ("text.viewfinder", String(localized: "Text Copied"), Self.excerpt(text))
        case .none: (symbol, heading, detail) = ("text.badge.xmark", String(localized: "No Text Found"), String(localized: "Nothing was copied."))
        case .reading: (symbol, heading, detail) = ("hourglass", String(localized: "Reading Text…"),
                                                    String(localized: "The first time, macOS takes a while to get ready."))
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = text == nil ? .secondaryLabelColor : .controlAccentColor
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let header = NSStackView(views: [icon, title])
        header.spacing = 6
        let body = NSTextField(wrappingLabelWithString: detail)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 4
        body.lineBreakMode = .byWordWrapping
        body.cell?.truncatesLastVisibleLine = true
        body.preferredMaxLayoutWidth = 216
        let stack = NSStackView(views: [header, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        close.isHidden = true
        addSubview(close)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            widthAnchor.constraint(equalToConstant: 240),
        ])
        frame.size = fittingSize
        viewDidChangeEffectiveAppearance()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Layer colours are fixed when set, so they're set again whenever the
    /// card's appearance changes (and once at the start, when it hasn't).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override var onClose: (() -> Void)? {
        didSet { (close as? ClosureButton)?.handler = { [weak self] in self?.onClose?() } }
    }

    /// Lines as they are, blank ones dropped, tabs as spaces: it's a glance.
    private static func excerpt(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).prefix(6)
            .map { $0.replacingOccurrences(of: "\t", with: "   ") }
            .joined(separator: "\n")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        close.isHidden = false
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        close.isHidden = true
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let text, let downAt, hypot(event.locationInWindow.x - downAt.x, event.locationInWindow.y - downAt.y) > 4 else { return }
        self.downAt = nil
        let item = NSDraggingItem(pasteboardWriter: text as NSString)
        let picture = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            picture.addRepresentation(rep)
        }
        item.setDraggingFrame(bounds, contents: picture)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        onClose?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onClose?() }
    }
}
