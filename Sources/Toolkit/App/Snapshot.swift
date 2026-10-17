import AppKit
import SwiftUI

enum Snapshot {
    static func write(to path: String, section: AppSection, light: Bool) {
        _ = NSApplication.shared
        let model = AppModel()
        model.section = section
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: MouseController(), switcher: SwitcherController(), mixer: MixerController.preview())))
        window.title = "MacOS Toolkit"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(NSSize(width: 780, height: 760))
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        guard let view = window.contentView?.superview ?? window.contentView else { return }
        save(view, to: path)
    }

    /// The window switcher's list, filled with made-up rows.
    static func writeSwitcher(to path: String, light: Bool) {
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
        let size = NSSize(width: 620, height: CGFloat(model.shown) * SwitcherListView.rowHeight + SwitcherListView.padding * 2)
        let window = NSWindow(contentViewController: NSHostingController(rootView: SwitcherListView(model: model).background(Color(nsColor: .windowBackgroundColor))))
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(size)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    /// The menu bar mixer, filled with made-up rows.
    static func writeMixer(to path: String, light: Bool, outputs: Bool) {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: MixerPopoverView(mixer: .preview(), showOutputs: outputs).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(host.view.fittingSize)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
