import AVFoundation
import AppKit

/// The small preview after a capture, in the corner of the display it was
/// taken on. Drag it into an app, click to open it, or let it go away.
final class ThumbnailStack {
    private var shown: [ThumbnailPanel] = []

    /// `file` is nil for a screenshot that only went to the clipboard; one is
    /// written to the temporary folder if it is dragged or opened.
    func show(image: CGImage, scale: CGFloat, file: URL?, isVideo: Bool, on screen: NSScreen?, makeFile: (() -> URL?)? = nil) {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = ThumbnailPanel(image: image, file: file, isVideo: isVideo, makeFile: makeFile)
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
        panel.scheduleDismiss()
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

    init(image: CGImage, file: URL?, isVideo: Bool, makeFile: (() -> URL?)?) {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let box: CGFloat = 200
        let size = aspect >= 1 ? NSSize(width: box, height: max(box / aspect, 48)) : NSSize(width: max(box * aspect, 64), height: box)
        super.init(frame: NSRect(origin: .zero, size: size), level: .popUpMenu)
        hasShadow = true
        let view = ThumbnailView(image: image, file: file, isVideo: isVideo, makeFile: makeFile)
        view.onClose = { [weak self] in self?.onClose?() }
        view.onHover = { [weak self] inside in
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

private final class ThumbnailView: NSView, NSDraggingSource {
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?

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

    private static func button(_ symbol: String, help: String, action: @escaping () -> Void) -> NSButton {
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
    private let handler: () -> Void

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
