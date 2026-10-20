import AVFoundation
import Combine
import SwiftUI

/// The ⇧⌘5 bar: what to capture, photo or video, options, and Capture.
final class CaptureToolbar {
    private var panel: CapturePanel?
    private var host: NSView?
    private var changes: AnyCancellable?
    unowned let capture: CaptureController

    init(capture: CaptureController) {
        self.capture = capture
    }

    var isVisible: Bool { panel != nil }
    var screen: NSScreen? { panel?.screen }

    func show(on screen: NSScreen) {
        if panel == nil {
            let host = NSHostingView(rootView: CaptureToolbarView(capture: capture))
            let size = host.fittingSize
            let panel = CapturePanel(frame: NSRect(origin: .zero, size: size), level: NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1))
            let container = ArrowCursorView(frame: NSRect(origin: .zero, size: size))
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            panel.contentView = container
            panel.isMovableByWindowBackground = true
            panel.onKey = { [weak self] event in
                switch event.keyCode {
                case 53: self?.capture.closeToolbar(); return true
                case 36, 76: self?.capture.captureFromToolbar(event); return true
                default: return false
                }
            }
            self.panel = panel
            self.host = host
            // The Capture button's label changes width ("Click a Window",
            // "Copy"); the panel follows, keeping its centre.
            changes = capture.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.fit() }
            }
        }
        guard let panel, let host else { return }
        let size = host.fittingSize
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func fit() {
        guard let panel, let host else { return }
        let size = host.fittingSize
        guard size != panel.frame.size, size.width > 0 else { return }
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
    }

    func hide() {
        changes = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }
}

struct CaptureToolbarView: View {
    @ObservedObject var capture: CaptureController

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIcon(symbol: "xmark.circle.fill", help: "Close (esc)", selected: false, muted: true) { capture.closeToolbar() }
            Separator()
            ToolbarIcon(symbol: "menubar.dock.rectangle", help: "Capture the whole display", selected: capture.config.mode == .screen) { capture.setMode(.screen) }
            ToolbarIcon(symbol: "macwindow", help: "Capture a window", selected: capture.config.mode == .window) { capture.setMode(.window) }
            ToolbarIcon(symbol: "rectangle.dashed", help: "Capture an area", selected: capture.config.mode == .area) { capture.setMode(.area) }
            Separator()
            ToolbarIcon(symbol: "camera", help: "Screenshot", selected: capture.config.kind == .photo) { capture.config.kind = .photo }
            ToolbarIcon(symbol: "record.circle", help: "Recording", selected: capture.config.kind == .video) { capture.config.kind = .video }
            Separator()
            OptionsMenu(capture: capture)
            Text(captureTitle)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .foregroundStyle(.white)
                .background(Color.accentColor.opacity(captureEnabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                // Not a Button: those take ⌃-click as a right click and do nothing.
                .overlay(ClickArea { event in if captureEnabled { capture.captureFromToolbar(event) } })
                .help(capture.config.mode == .window ? "Click the window to capture it" : "Hold ⌃ to copy instead of saving")
                .padding(.leading, 4)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize()
    }

    private var captureTitle: String {
        let copy = capture.controlHeld && capture.config.kind == .photo
        if capture.config.mode == .window {
            return capture.config.kind == .video ? "Click a Window to Record" : copy ? "Click a Window to Copy" : "Click a Window"
        }
        return capture.config.kind == .video ? "Record" : copy ? "Copy" : "Capture"
    }

    private var captureEnabled: Bool {
        switch capture.config.mode {
        case .window: return false
        case .screen: return true
        case .area: return capture.hasArea
        }
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }
}

private struct ToolbarIcon: View {
    let symbol: String
    let help: String
    let selected: Bool
    var muted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 34, height: 30)
                .foregroundStyle(muted ? Color.secondary : selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct OptionsMenu: View {
    @ObservedObject var capture: CaptureController

    var body: some View {
        Menu {
            Picker("Timer", selection: $capture.config.timer) {
                Text("None").tag(0)
                Text("3 Seconds").tag(3)
                Text("5 Seconds").tag(5)
                Text("10 Seconds").tag(10)
            }
            Picker("Window", selection: $capture.config.windowStyle) {
                Text("Content Only").tag(WindowStyle.content)
                Text("Plain").tag(WindowStyle.plain)
                Text("With Backdrop").tag(WindowStyle.nice)
            }
            Divider()
            Picker("Recording Quality", selection: $capture.config.quality) {
                ForEach(RecordingQuality.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show Cursor", isOn: $capture.config.showCursor)
            Toggle("Show Clicks", isOn: $capture.config.showClicks)
            Toggle("System Audio", isOn: $capture.config.systemAudio)
            Toggle("Microphone", isOn: Binding(get: { capture.config.microphone }, set: { capture.setMicrophone($0) }))
            if capture.config.microphone {
                Picker("Microphone Input", selection: $capture.config.microphoneID) {
                    Text("Default").tag("")
                    ForEach(Microphones.all(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            Divider()
            Button("Screen Capture Settings…") { capture.openSettings() }
        } label: {
            Text("Options")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
    }
}

/// Takes plain clicks and ⌃-clicks alike.
private struct ClickArea: NSViewRepresentable {
    let action: (NSEvent) -> Void

    func makeNSView(context: Context) -> ClickView { ClickView(action: action) }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }

    final class ClickView: NSView {
        var action: (NSEvent) -> Void

        init(action: @escaping (NSEvent) -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { release(event) }
        override func rightMouseUp(with event: NSEvent) { release(event) }

        private func release(_ event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { action(event) }
        }
    }
}

/// The toolbar sits over the overlay's crosshair. A background app's cursor
/// rects don't apply, so the arrow is set by hand.
private final class ArrowCursorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

enum Microphones {
    static func all() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
}
