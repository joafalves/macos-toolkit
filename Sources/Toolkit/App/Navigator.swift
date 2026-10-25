import AppKit
import SwiftUI

/// Where the settings window is: a section, and on Mouse, the mouse whose
/// page is open.
struct Place: Equatable {
    var section: AppSection
    var mouse: String?
}

/// The window's history, as System Settings keeps it: every place shown,
/// however it was reached (the sidebar, a link, a panel in the menu bar),
/// so back and forward retrace it. Going somewhere new drops what was ahead.
final class Navigator: ObservableObject {
    @Published private(set) var back: [Place] = []
    @Published private(set) var forward: [Place] = []
    private var current: Place?
    /// Where back or forward is taking the window, so arriving there isn't
    /// taken for a new step.
    private var arriving: Place?
    /// Enough to retrace an afternoon's settings.
    private static let limit = 50

    /// Whenever the place shown changes, whatever changed it.
    func moved(to place: Place) {
        defer { current = place }
        guard let current, place != current else { return }
        if place == arriving {
            arriving = nil
            return
        }
        arriving = nil
        back.append(current)
        if back.count > Self.limit { back.removeFirst() }
        forward.removeAll()
    }

    func goBack() -> Place? {
        guard let current, let place = back.popLast() else { return nil }
        forward.append(current)
        arriving = place
        return place
    }

    func goForward() -> Place? {
        guard let current, let place = forward.popLast() else { return nil }
        back.append(current)
        arriving = place
        return place
    }
}

/// The settings window, as the app opens it and `--snapshot` draws it: the
/// sidebar running its full height, and the toolbar over the page with back,
/// forward and the page's title, all from SwiftUI.
enum MainWindow {
    static let identifier = NSUserInterfaceItemIdentifier("dev.jalves.macos-toolkit.main")

    static func make(_ view: MainView) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.identifier = identifier
        // The title is the page's, from SwiftUI, as System Settings names its window.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        return window
    }
}

/// Sets the title of the window it's in.
struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Once it's in its window, on the next pass.
        DispatchQueue.main.async { view.window?.title = title }
    }
}

/// Back and forward with a swipe, as in System Settings: two fingers on the
/// trackpad (or one on a Magic Mouse) to the right go back, to the left
/// forward. Also a mouse's back and forward buttons, as a browser takes them
/// (Mouse's Navigate only turns them into swipes for Apple's apps), and the
/// navigation swipe of three fingers or of Navigate. Only in the settings
/// window; scrolling up and down is never taken for one.
final class SwipeNavigation: ObservableObject {
    /// How far the fingers travel, in points, before it counts, as for Finder.
    private static let threshold = 80.0
    private var monitor: Any?
    private var tracking = false
    private var dx = 0.0
    private var dy = 0.0

    func start(back: @escaping () -> Void, forward: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown, .swipe]) { [weak self] event in
            guard event.window?.identifier == MainWindow.identifier else { return event }
            switch event.type {
            case .otherMouseDown where event.buttonNumber == 3 || event.buttonNumber == 4:
                event.buttonNumber == 3 ? back() : forward()
                return nil
            case .swipe where event.deltaX != 0:
                // Fingers to the right, as back in Safari.
                event.deltaX > 0 ? back() : forward()
                return nil
            case .scrollWheel:
                self?.handle(event, back: back, forward: forward)
            default:
                break
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }

    private func handle(_ event: NSEvent, back: () -> Void, forward: () -> Void) {
        // The fingers themselves, not the glide after they lift.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            tracking = true
            dx = 0
            dy = 0
        }
        guard tracking else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            tracking = false
            return
        }
        dx += event.scrollingDeltaX
        dy += event.scrollingDeltaY
        // Mostly up or down: a scroll, for the rest of this gesture.
        if abs(dy) > 12, abs(dy) > abs(dx) {
            tracking = false
            return
        }
        guard abs(dx) >= Self.threshold, abs(dx) > abs(dy) * 2 else { return }
        tracking = false
        // With natural scrolling the content follows the fingers.
        let fingersRight = event.isDirectionInvertedFromDevice ? dx > 0 : dx < 0
        fingersRight ? back() : forward()
    }
}
