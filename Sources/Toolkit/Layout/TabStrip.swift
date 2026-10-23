import AppKit
import SwiftUI

/// Where a slot's windows and its tabs go, by the slot's frame (Core
/// Graphics coordinates).
enum TabGeometry {
    /// Twice macOS 27's window corner radius (17, measured), with round
    /// ends: its corners are the window's above it, and its tabs sit
    /// concentric inside.
    static let stripHeight: CGFloat = 34
    /// Around the tabs, inside the strip.
    static let inset: CGFloat = 4
    /// Between the strip and the windows.
    static let spacing: CGFloat = 4
    // static let pillHeight: CGFloat = 34
    // static let pillIcon: CGFloat = 30

    /// The windows: the slot less the strip's band (all of it under a pill).
    static func member(in slot: CGRect, style: TabsStyle, position: TabsPosition) -> CGRect {
        // guard style == .strip else { return slot }
        let band = stripHeight + spacing
        return CGRect(x: slot.minX, y: position == .top ? slot.minY + band : slot.minY,
                      width: slot.width, height: max(slot.height - band, 1))
    }

    /// The strip along the slot's edge (or the pill floating over the
    /// window's edge, as wide as its icons).
    static func tabs(in slot: CGRect, style: TabsStyle, position: TabsPosition, count: Int) -> CGRect {
        switch style {
        case .strip:
            return CGRect(x: slot.minX, y: position == .top ? slot.minY : slot.maxY - stripHeight,
                          width: slot.width, height: stripHeight)
        // case .pill:
        //     let width = CGFloat(count) * pillIcon + 12
        //     let y = position == .top ? slot.minY + 10 : slot.maxY - pillHeight - 10
        //     return CGRect(x: (slot.midX - width / 2).rounded(), y: y, width: width, height: pillHeight)
        }
    }

    /// Each tab's width in a strip `width` wide.
    static func tabWidth(_ width: CGFloat, count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        return min(240, (width - 8 - 4 * (n - 1)) / n)
    }

    /// The tab under `x`, from the strip's left edge.
    static func index(at x: CGFloat, width: CGFloat, count: Int, style: TabsStyle) -> Int? {
        let position: Int
        switch style {
        case .strip:
            let w = tabWidth(width, count: count)
            guard x >= 4 else { return nil }
            position = Int((x - 4) / (w + 4))
        // case .pill:
        //     guard x >= 6 else { return nil }
        //     position = Int((x - 6) / pillIcon)
        }
        return (0..<count).contains(position) ? position : nil
    }
}

/// One tab: a window in the slot.
struct TabItem: Identifiable, Equatable {
    let id: CGWindowID
    var title: String
    var appName: String
    var icon: NSImage?
}

final class TabStripModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var shown: CGWindowID?
    @Published var style = TabsStyle.strip
}

/// The tabs of one slot, as a strip (or a pill).
struct TabStripView: View {
    @ObservedObject var model: TabStripModel

    var body: some View {
        strip
        // if model.style == .strip { strip } else { pill }
    }

    private var strip: some View {
        GeometryReader { geometry in
            let width = TabGeometry.tabWidth(geometry.size.width, count: model.tabs.count)
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    let shown = tab.id == model.shown
                    HStack(spacing: 6) {
                        if let icon = tab.icon {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                        }
                        Text(tab.title.isEmpty ? tab.appName : tab.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: shown ? .semibold : .regular))
                    .foregroundStyle(shown ? Color.white : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(width: width, height: TabGeometry.stripHeight - 2 * TabGeometry.inset)
                    .background(shown ? Color.accentColor : Color.primary.opacity(0.06),
                                in: Capsule(style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    // private var pill: some View {
    //     HStack(spacing: 0) {
    //         ForEach(model.tabs) { tab in
    //             let shown = tab.id == model.shown
    //             Group {
    //                 if let icon = tab.icon {
    //                     Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
    //                 } else {
    //                     Circle().fill(Color.secondary).frame(width: 8, height: 8)
    //                 }
    //             }
    //             .frame(width: TabGeometry.pillIcon, height: TabGeometry.pillHeight - 2 * TabGeometry.inset)
    //             .background(shown ? Color.accentColor.opacity(0.3) : Color.clear, in: Capsule(style: .continuous))
    //             .opacity(shown ? 1 : 0.6)
    //         }
    //     }
    //     .padding(.horizontal, 6)
    //     .frame(height: TabGeometry.pillHeight)
    //     .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: Capsule(style: .continuous))
    //     .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    // }
}

/// The window the tabs are in: an ordinary one, kept just above the slot's
/// shown window, so a window of another app in front of the slot covers the
/// tabs too. It never takes the keyboard or makes the toolkit active.
final class TabStrip {
    let model = TabStripModel()
    var onSelect: (CGWindowID) -> Void = { _ in }
    /// Right-click on a tab: take it out, or close its window.
    var onTakeOut: (CGWindowID) -> Void = { _ in }
    var onClose: (CGWindowID) -> Void = { _ in }

    private lazy var panel = makePanel()

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        let host = NSHostingView(rootView: TabStripView(model: model))
        let catcher = TabMouseCatcher()
        catcher.strip = self
        let root = NSView()
        for view in [host, catcher] {
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        panel.contentView = root
        return panel
    }

    var windowNumber: Int { panel.windowNumber }

    /// At `frame` (Core Graphics coordinates), right above `window`, among
    /// the ordinary windows: it's beside the window, and covered by whatever
    /// covers the slot.
    func show(at frame: CGRect, above window: CGWindowID) {
        let appKit = Coordinates.toAppKit(frame)
        if panel.frame != appKit { panel.setFrame(appKit, display: true) }
        for view in panel.contentView?.subviews ?? [] { view.frame = panel.contentView?.bounds ?? .zero }
        panel.order(.above, relativeTo: Int(window))
        // For a pill, which sits on its window: floating over every ordinary
        // window, and left out while something else covers its spot.
        // if floating {
        //     if panel.level != .floating { panel.level = .floating }
        //     if !inSight {
        //         panel.orderOut(nil)
        //     } else if !panel.isVisible {
        //         panel.orderFrontRegardless()
        //     }
        // }
    }

    func hide() {
        panel.orderOut(nil)
    }

    fileprivate func index(at x: CGFloat) -> Int? {
        TabGeometry.index(at: x, width: panel.frame.width, count: model.tabs.count, style: model.style)
    }

    fileprivate func menu(for index: Int, at point: NSPoint, in view: NSView) {
        let id = model.tabs[index].id
        let menu = NSMenu()
        let takeOut = NSMenuItem(title: String(localized: "Take Out of Stack"), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        let close = NSMenuItem(title: String(localized: "Close Window"), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        let target = MenuTarget { [weak self] item in
            if item === takeOut { self?.onTakeOut(id) } else { self?.onClose(id) }
        }
        for item in [takeOut, close] {
            item.target = target
            menu.addItem(item)
        }
        objc_setAssociatedObject(menu, &MenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

private final class MenuTarget: NSObject {
    static var key = 0
    let action: (NSMenuItem) -> Void
    init(_ action: @escaping (NSMenuItem) -> Void) { self.action = action }
    @objc func fire(_ sender: NSMenuItem) { action(sender) }
}

/// Turns clicks into tabs. SwiftUI's own needs a key window, which the strip
/// never is.
private final class TabMouseCatcher: NSView {
    weak var strip: TabStrip?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let strip, let index = strip.index(at: point.x) else { return }
        strip.onSelect(strip.model.tabs[index].id)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let strip, let index = strip.index(at: point.x) else { return }
        strip.menu(for: index, at: point, in: self)
    }
}
