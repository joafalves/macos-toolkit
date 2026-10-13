import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var mouse: MouseController!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mouse = MouseController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.makeStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NSApp.mainMenu = makeMainMenu()

        // Restore on `kill` too, not only on a regular quit.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        // A launch from the login item should stay in the background.
        if !Self.launchedAsLoginItem { show(.mouse) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(model.section ?? .mouse)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if mouse.config.restoreOnQuit { mouse.restoreAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// The menu bar glyph, fitted into the standard 18pt box. Used as-is the
    /// symbol is taller than the menu bar allows and gets clipped.
    static func makeStatusIcon() -> NSImage {
        let box = NSSize(width: 18, height: 18)
        let image = NSImage(size: box, flipped: false) { rect in
            guard let glyph = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            else { return false }
            let area = rect.insetBy(dx: 1, dy: 1)
            let fit = min(area.width / glyph.size.width, area.height / glyph.size.height, 1)
            let size = NSSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
            glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacOS Toolkit"
        return image
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for section in AppSection.allCases {
            let item = NSMenuItem(title: "\(section.title)…", action: #selector(openSection(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
            item.representedObject = section.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacOS Toolkit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openSection(_ sender: NSMenuItem) {
        show((sender.representedObject as? String).flatMap(AppSection.init) ?? .mouse)
    }

    @objc private func openGeneral() {
        show(.general)
    }

    /// Menu bar shown while the main window is open.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openGeneral), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MacOS Toolkit", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit MacOS Toolkit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "MacOS Toolkit", action: nil, keyEquivalent: "").submenu = appMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    // MARK: - Window

    private func show(_ section: AppSection) {
        model.section = section
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: mouse)))
            window.title = "MacOS Toolkit"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 780, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // Behave like a regular app (Dock icon, Cmd-Tab) while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
