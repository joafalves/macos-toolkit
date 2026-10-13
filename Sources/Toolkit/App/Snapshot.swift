import AppKit
import SwiftUI

enum Snapshot {
    static func write(to path: String, section: AppSection, light: Bool) {
        _ = NSApplication.shared
        let model = AppModel()
        model.section = section
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: MouseController())))
        window.title = "MacOS Toolkit"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(NSSize(width: 780, height: 760))
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
