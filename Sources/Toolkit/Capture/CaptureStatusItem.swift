import AppKit

/// Screen Capture's own menu bar item: an icon that opens the toolbar when the
/// setting is on, and always, while recording, a stop button with the time and
/// size so far. Right-click it for Pause.
final class CaptureStatusItem: NSObject {
    unowned let capture: CaptureController
    private var item: NSStatusItem?

    init(capture: CaptureController) {
        self.capture = capture
    }

    var windowNumber: CGWindowID? {
        item?.button?.window.map { CGWindowID($0.windowNumber) }
    }

    func update() {
        guard !capture.isPreview else { return }
        let state = capture.recording
        guard state != nil || capture.config.standaloneIcon else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? makeItem()
        self.item = item
        guard let button = item.button else { return }
        if let state {
            item.length = NSStatusItem.variableLength
            button.image = NSImage(systemSymbolName: state.paused ? "pause.circle.fill" : "stop.circle.fill", accessibilityDescription: "Stop Recording")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.white, state.paused ? .systemOrange : .systemRed])))
            button.image?.isTemplate = false
            button.imagePosition = .imageLeading
            button.title = " " + Self.time(state.elapsed) + (state.bytes > 0 ? " · " + Self.size(state.bytes) : "")
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = "Click to stop recording. Right-click to pause."
        } else {
            item.length = NSStatusItem.squareLength
            button.title = ""
            button.image = AppDelegate.makeStatusIcon(symbol: AppSection.capture.symbol, description: "Screen Capture")
            button.toolTip = "Screen Capture"
        }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return item
    }

    @objc private func clicked() {
        let right = NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        guard capture.isRecording else { return capture.toggleToolbar() }
        guard right, let item, let button = item.button else { return capture.stopRecording() }
        let menu = NSMenu()
        let paused = capture.recording?.paused == true
        menu.addItem(withTitle: paused ? "Resume Recording" : "Pause Recording", action: #selector(pause), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Stop Recording", action: #selector(stop), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Discard Recording", action: #selector(discard), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func pause() { capture.togglePause() }
    @objc private func stop() { capture.stopRecording() }
    @objc private func discard() { capture.discardRecording() }

    static func time(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
