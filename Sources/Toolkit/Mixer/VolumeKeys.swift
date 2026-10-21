import AppKit
import ApplicationServices
import SwiftUI

enum VolumeKey {
    case up, down, mute
}

/// Catches the keyboard's volume keys while the mixer is on, on every output,
/// so they always behave the same and always show the toolkit's bar: the
/// device's own volume where it has one, the software volume where it doesn't.
final class VolumeKeys {
    private unowned let mixer: MixerController
    private let hud = VolumeHUD()
    private var tap: EventTap?
    /// Whether keys are taken now, kept by the main thread for the tap's.
    private let catching = Locked(false)

    /// Whether the keys are meant to be caught right now.
    private(set) var wanted = false

    /// Whether the event tap is in place; it needs Accessibility.
    private(set) var installed = false {
        didSet { if installed != oldValue { mixer.keysInstalledChanged(installed) } }
    }

    /// NX_SYSDEFINED, the event type media keys arrive as.
    private static let systemDefined: UInt32 = 14

    init(mixer: MixerController) {
        self.mixer = mixer
    }

    func setWanted(_ wanted: Bool) {
        self.wanted = wanted
        catching.value = wanted && mixer.handlesVolumeKeys
        sync()
    }

    /// Accessibility may be granted after the mixer started.
    func retryIfNeeded() {
        if wanted, !installed { sync() }
    }

    private func sync() {
        if wanted, !installed {
            installed = AXIsProcessTrusted() && install()
        } else if !wanted, installed {
            uninstall()
            installed = false
        }
    }

    private func install() -> Bool {
        tap = EventTap(name: "volume-keys", events: [CGEventType(rawValue: Self.systemDefined)!]) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
        }
        return tap != nil
    }

    private func uninstall() {
        tap?.stop()
        tap = nil
    }

    /// On the tap's thread: decides from `catching`, and leaves the volume and
    /// the bar to the main thread.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard type.rawValue == Self.systemDefined, catching.value,
              let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8
        else { return pass }

        // data1 holds the key in the high half and its state in the low half.
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let state = ns.data1 & 0xFFFF
        let key: VolumeKey
        switch code {
        case 0: key = .up
        case 1: key = .down
        case 7: key = .mute
        default: return pass
        }
        // Option alone opens Sound settings, which is macOS's to do.
        let flags = event.flags
        if flags.contains(.maskAlternate), !flags.contains(.maskShift) { return pass }

        let isDown = (state & 0xFF00) >> 8 == 0xA
        let isRepeat = state & 0x1 != 0
        // Both the press and the release are taken, or macOS would see half a key.
        guard isDown, !(key == .mute && isRepeat) else { return nil }
        // Shift and Option together: fine steps, like macOS.
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mixer.volumeKey(key, fine: fine)
            self.hud.show(volume: self.mixer.mainVolume, muted: self.mixer.mainMuted)
        }
        return nil
    }
}

// MARK: - HUD

private final class HUDModel: ObservableObject {
    @Published var volume: Float = 0
    @Published var muted = false
}

/// A small floating bar that shows the volume after a key press, in place of
/// the one macOS shows for outputs it controls.
final class VolumeHUD {
    private static let size = NSSize(width: 300, height: 56)

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// For `--show-hud`: puts the bar up for a few seconds.
    static func demo() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let hud = VolumeHUD()
        hud.show(volume: 0.65, muted: false)
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        _ = hud
    }

    func show(volume: Float, muted: Bool) {
        model.volume = volume
        model.muted = muted
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.minY + 90))
        }
        generation += 1
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // The shadow is cached from whatever the window looked like when it appeared.
            DispatchQueue.main.async { panel.invalidateShadow() }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A key pressed during the fade keeps the bar on screen.
            if self?.generation == current { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // The blur is drawn by the window server, which ignores a rounded layer;
        // only a mask image shapes it, and the window's shadow follows that too.
        // Rounding the layer instead leaves the blur as a faint square.
        effect.maskImage = Self.capsuleMask(size: Self.size)

        let content = NSHostingView(rootView: VolumeHUDView(model: model))
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        panel.contentView = effect
        return panel
    }

    private static func capsuleMask(size: NSSize) -> NSImage {
        let radius = size.height / 2
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private struct VolumeHUDView: View {
    @ObservedObject var model: HUDModel
    private static let segments = 20

    private var symbol: String {
        if model.muted || model.volume <= 0 { return "speaker.slash.fill" }
        return model.volume < 0.34 ? "speaker.wave.1.fill" : model.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        let filled = model.muted ? 0 : Int((model.volume * Float(Self.segments)).rounded())
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 26)
            HStack(spacing: 2.5) {
                ForEach(0..<Self.segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index < filled ? Color.primary : Color.primary.opacity(0.2))
                        .frame(height: 9)
                }
            }
            Text(model.muted ? "Muted" : "\(Int((model.volume * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(width: 300, height: 56)
    }
}
