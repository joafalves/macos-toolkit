import AppKit
import SwiftUI

/// Scrolls while the wheel button is held and the mouse moves, like autoscroll
/// in Windows browsers: the farther the pointer is from where the button went
/// down, the faster it scrolls that way. A press and release without moving
/// is still a normal middle click, so links still open in new tabs.
///
/// Lives on the wheel tap's thread, timer included; only the marker, being a
/// window, is shown and hidden on the main thread.
final class Autoscroller {
    /// Bundle IDs of the apps that keep the wheel button to themselves.
    /// Called on the tap's thread, so it must be safe there.
    var excludedApps: () -> Set<String> = { [] }
    /// Held while pressing, the app gets this press of the button itself.
    /// Called on the tap's thread, so it must be safe there.
    var bypassKey: () -> CGEventFlags = { .maskAlternate }

    private enum State { case idle, pending, scrolling }

    /// Movement while held that turns the press into autoscroll, in points.
    private static let startDistance = 6.0
    /// Around the anchor nothing scrolls, so a still hand doesn't drift.
    private static let deadZone = 10.0

    private var state = State.idle
    private var anchor = CGPoint.zero
    private var pointer = CGPoint.zero
    private var speed = 1.0
    private var flags: CGEventFlags = []
    private var timer: Timer?
    private var lastTick = 0.0
    private var carryX = 0.0
    private var carryY = 0.0
    /// Only touched on the main thread.
    private var indicator: NSPanel?

    /// Handles the wheel button (button 2). Returns true when the event was
    /// consumed; a drag passes on as a plain move. `profile` is the scrolling
    /// mouse's, read on the press only.
    func handle(type: CGEventType, event: CGEvent, profile: () -> Profile?) -> Bool {
        switch type {
        case .otherMouseDown:
            guard state == .idle, let profile = profile(), profile.autoscroll,
                  !event.flags.contains(bypassKey())
            else { return false }
            let excluded = excludedApps()
            if !excluded.isEmpty, let id = NSRunningApplication.owningWindow(at: event.location)?.bundleIdentifier,
               excluded.contains(id) {
                return false
            }
            // Held back until we know whether this is a click or autoscroll.
            state = .pending
            anchor = event.location
            pointer = anchor
            speed = profile.autoscrollSpeed
            flags = event.flags
            return true
        case .otherMouseDragged:
            guard state != .idle else { return false }
            pointer = event.location
            if state == .pending, hypot(pointer.x - anchor.x, pointer.y - anchor.y) >= Self.startDistance {
                start()
            }
            // A plain move rather than a drag the app never saw start. Not
            // dropped: then the cursor would stay where the button went down.
            event.type = .mouseMoved
            return false
        case .otherMouseUp:
            switch state {
            case .idle: return false
            case .pending:
                state = .idle
                Self.click(at: anchor, flags: flags)
            case .scrolling:
                stop()
            }
            return true
        default:
            return false
        }
    }

    /// The press we held back, delivered after all as a click.
    private static func click(at point: CGPoint, flags: CGEventFlags) {
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center)
            else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: WheelEngine.marker)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Scrolling

    private func start() {
        state = .scrolling
        carryX = 0
        carryY = 0
        showIndicator()
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        // On the tap's thread, with the rest of the state.
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    /// For when the event tap was switched off for a moment: the release may
    /// have gone by unseen, and scrolling would never end.
    func cancel() {
        if state == .scrolling { stop() } else { state = .idle }
    }

    private func stop() {
        state = .idle
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.async { [weak self] in self?.indicator?.orderOut(nil) }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        carryX += Self.velocity(pointer.x - anchor.x) * speed * dt
        carryY += Self.velocity(pointer.y - anchor.y) * speed * dt
        let stepX = carryX.rounded(.towardZero)
        let stepY = carryY.rounded(.towardZero)
        carryX -= stepX
        carryY -= stepY
        guard stepX != 0 || stepY != 0,
              // Negative deltas scroll toward the bottom and the right, where the pointer is.
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(-stepY), wheel2: Int32(-stepX), wheel3: 0)
        else { return }
        event.setIntegerValueField(.eventSourceUserData, value: WheelEngine.marker)
        // At the pointer, where a new event is made: one placed at the anchor
        // would move the cursor back there.
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }

    /// Points per second for a pointer `offset` points from the anchor: slow
    /// near it for reading, and quickly faster farther out.
    private static func velocity(_ offset: Double) -> Double {
        let excess = abs(offset) - deadZone
        guard excess > 0 else { return 0 }
        return (offset < 0 ? -1 : 1) * pow(excess, 1.4) * 3
    }

    // MARK: - Indicator

    private static let indicatorSize = NSSize(width: 30, height: 30)

    /// A marker at the anchor, so it's clear where scrolling is measured from.
    private func showIndicator() {
        let anchor = anchor
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let panel = indicator ?? Self.makeIndicator()
            indicator = panel
            // The event is in global coordinates from the top of the main
            // display; windows are placed from its bottom.
            let height = NSScreen.screens.first?.frame.height ?? 0
            let size = Self.indicatorSize
            panel.setFrameOrigin(NSPoint(x: anchor.x - size.width / 2, y: height - anchor.y - size.height / 2))
            panel.orderFrontRegardless()
        }
    }

    private static func makeIndicator() -> NSPanel {
        let size = indicatorSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // The blur ignores a rounded layer; only a mask image shapes it.
        effect.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let content = NSHostingView(rootView: AutoscrollIndicator())
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        panel.contentView = effect
        return panel
    }
}

private struct AutoscrollIndicator: View {
    var body: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
