import AppKit
import SwiftUI

enum Snapshot {
    static func write(to path: String, section: AppSection, light: Bool) {
        _ = NSApplication.shared
        let model = AppModel()
        model.section = section
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: MouseController.preview(), switcher: SwitcherController.preview(), mixer: MixerController.preview(), finder: FinderController.preview(), capture: CaptureController.preview())))
        window.title = "MacOS Toolkit"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(NSSize(width: 780, height: 760))
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        guard let view = window.contentView?.superview ?? window.contentView else { return }
        save(view, to: path)
    }

    /// The window switcher's list, or with `grid` its previews, filled with
    /// made-up rows and drawn stand-ins for windows: nothing from the screen.
    static func writeSwitcher(to path: String, light: Bool, grid: Bool = false) {
        _ = NSApplication.shared
        func icon(_ app: String) -> NSImage { NSWorkspace.shared.icon(forFile: "/System/Applications/\(app).app") }
        func row(_ id: Int, _ title: String, _ app: String, _ state: SwitcherItem.State = .window) -> SwitcherItem {
            SwitcherItem(id: "\(id)", window: state == .window || state == .minimized ? CGWindowID(id) : nil, pid: 0,
                         title: title, appName: app, icon: icon(app), state: state)
        }
        let model = SwitcherListModel()
        model.items = [
            row(1, "Inbox — 3 new messages", "Mail"),
            row(2, "macos-toolkit — zsh — 120×40", "Terminal"),
            row(3, "A very long window title that will not fit in the space the row has for it at all", "TextEdit"),
            row(4, "Notes", "Notes"),
            row(5, "October 2026", "Calendar"),
            row(6, "Untitled", "TextEdit", .minimized),
            row(7, "Music", "Music", .hiddenApp),
            row(8, "Calculator", "Calculator", .noWindows),
        ]
        model.selection = 1
        model.shown = model.items.count
        var size = NSSize(width: 620, height: CGFloat(model.shown) * SwitcherListView.rowHeight + SwitcherListView.padding * 2)
        if grid {
            model.style = .previews
            model.layout = GridLayout(count: model.items.count, maxTileWidth: PreviewSize.medium.maxTileWidth, area: CGSize(width: 1180, height: 760))
            let colors: [NSColor] = [.systemBlue, .darkGray, .systemOrange, .systemYellow, .systemRed, .systemGray]
            for (index, item) in model.items.enumerated() where item.state == .window || item.state == .minimized {
                guard let id = item.window, let image = fakeWindow(accent: colors[index % colors.count], dark: !light, wide: index % 3 != 2) else { continue }
                model.previews[id] = image
            }
            size = model.layout.size
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SwitcherView(model: model).background(Color(nsColor: .windowBackgroundColor))))
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(size)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    /// A drawn window: a title bar, a sidebar and a few lines of "text".
    private static func fakeWindow(accent: NSColor, dark: Bool, wide: Bool) -> CGImage? {
        let size = NSSize(width: wide ? 640 : 480, height: 400)
        let image = NSImage(size: size, flipped: true) { rect in
            let base = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.98, alpha: 1)
            let line = dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.85, alpha: 1)
            base.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: rect.width * 0.26, height: rect.height).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18 + CGFloat(i) * 22, y: 16, width: 13, height: 13)).fill()
            }
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.width * 0.3, y: 50, width: rect.width * 0.4, height: 26), xRadius: 6, yRadius: 6).fill()
            line.setFill()
            for row in 0..<8 {
                let width = rect.width * (0.62 - CGFloat(row % 3) * 0.12)
                NSBezierPath(roundedRect: NSRect(x: rect.width * 0.3, y: 100 + CGFloat(row) * 32, width: width, height: 12), xRadius: 6, yRadius: 6).fill()
            }
            for row in 0..<6 {
                NSBezierPath(roundedRect: NSRect(x: 18, y: 60 + CGFloat(row) * 30, width: rect.width * 0.18, height: 12), xRadius: 6, yRadius: 6).fill()
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The menu bar mixer, filled with made-up rows.
    static func writeMixer(to path: String, light: Bool, outputs: Bool, software: Bool, equalizer: Bool) {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: MixerPopoverView(mixer: .preview(software: software, equalizer: equalizer), showOutputs: outputs, showEqualizer: equalizer).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(host.view.fittingSize)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    /// The Screen Capture toolbar, as ⇧⌘5 shows it.
    static func writeCaptureToolbar(to path: String, light: Bool, video: Bool) {
        _ = NSApplication.shared
        let capture = CaptureController.preview()
        capture.config.kind = video ? .video : .photo
        let host = NSHostingController(rootView: CaptureToolbarView(capture: capture).padding(16))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.backgroundColor = light ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.16, alpha: 1)
        window.setContentSize(host.view.fittingSize)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    /// Images come out at the scale of the display the window is on, so the
    /// window goes to a Retina one when there is one.
    private static func onRetina(_ window: NSWindow) {
        if let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) {
            window.setFrameOrigin(screen.frame.origin)
        }
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
