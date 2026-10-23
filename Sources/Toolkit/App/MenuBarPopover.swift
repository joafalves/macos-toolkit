import AppKit
import SwiftUI

/// A panel hanging from a part of the menu bar item, like the mixer's: the
/// part stays lit while it's open, and it closes on a click elsewhere, Esc,
/// or switching apps. It doesn't activate the app, so the settings window
/// stays where it is. The content is made each time it opens and let go of
/// when it closes, so a closed panel costs nothing.
/// The bottom of a panel from the menu bar, the same in each: on the left
/// the macOS app it goes with, by name, with an arrow for leaving the
/// toolkit; on the right the tool's own settings, under the toolkit's mark.
struct PanelFooter: View {
    let app: String
    let openApp: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Button(action: openApp) {
                HStack(spacing: 3) {
                    Text(app)
                    Image(systemName: "arrow.up.forward").font(.caption2.weight(.semibold))
                }
            }
            Spacer()
            Button(action: openSettings) {
                HStack(spacing: 5) {
                    Image(nsImage: MenuBarArt.toolkit).resizable().frame(width: 12, height: 13.5)
                    Text("Settings…")
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

final class MenuBarPopover: NSObject, NSPopoverDelegate {
    var onClose: (() -> Void)?
    private let menuBar: MenuBarItem
    private var popover: NSPopover?
    private var shownFor: MenuBarSegment.Kind?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    init(menuBar: MenuBarItem) {
        self.menuBar = menuBar
    }

    /// Open, and not on its way out: from the moment it starts closing, a
    /// click on its part opens it again rather than closing it once more.
    var isShown: Bool { popover != nil && shownFor != nil }
    var kind: MenuBarSegment.Kind? { isShown ? shownFor : nil }

    /// On the next pass of the run loop, once any menu has closed.
    func show<Content: View>(from kind: MenuBarSegment.Kind, @ViewBuilder content: () -> Content) {
        let host = NSHostingController(rootView: content())
        DispatchQueue.main.async { [self] in
            // The part may be gone by now; whoever opened it is told it's closed.
            guard let button = menuBar.button, let rect = menuBar.rect(of: kind) else {
                onClose?()
                return
            }
            // The last one closes on its own; it's no longer the one shown.
            popover?.performClose(nil)
            forget()
            menuBar.setPressed(kind)
            let popover = NSPopover()
            // Closed by us, not by AppKit, whose transient closing also took
            // the click on the item's part and so opened it again.
            popover.behavior = .applicationDefined
            popover.delegate = self
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            self.popover = popover
            shownFor = kind
            popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
            watch()
        }
    }

    func close() {
        popover?.performClose(nil)
    }

    /// Still hanging from its part, which moves as parts before it come or
    /// go: a switch in the toolkit panel adds or takes away a tool's part.
    func follow() {
        guard let popover, let kind = shownFor, let rect = menuBar.rect(of: kind), popover.positioningRect != rect else { return }
        popover.positioningRect = rect
    }

    private func watch() {
        guard monitors.isEmpty else { return }
        let close: () -> Void = { [weak self] in self?.close() }
        // Not a click on the menu bar item, which decides for itself what to do.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            if self?.menuBar.contains(screenPoint: NSEvent.mouseLocation) != true { close() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { event in
            if event.keyCode == 53 { close() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 {
                close()
                return nil
            }
            // A click in another of our windows; the item's own click toggles.
            if event.type == .leftMouseDown, let window = event.window,
               window != self?.popover?.contentViewController?.view.window,
               window != self?.menuBar.button?.window {
                close()
            }
            return event
        }) {
            monitors.append(monitor)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { _ in close() }
    }

    /// Only for the panel showing now: one closing as the next opens (a click
    /// on another part) mustn't put out or forget the new one.
    func popoverWillClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        shownFor = nil
        menuBar.setPressed(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        forget()
        onClose?()
    }

    private func forget() {
        popover = nil
        shownFor = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
