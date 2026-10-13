import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var state: AppState!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Tiller")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NSApp.mainMenu = makeMainMenu()
        NSApp.applicationIconImage = Self.makeIcon()

        // Restore on `kill` too, not only on a regular quit.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        // A launch from the login item should stay in the background.
        if !Self.launchedAsLoginItem { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if state.config.restoreOnQuit { state.restoreAll() }
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let connected = state.devices.filter(\.connected)
        if connected.isEmpty {
            menu.addItem(withTitle: "No mouse connected", action: nil, keyEquivalent: "")
        }
        for device in connected {
            let custom = !(state.config.profiles[device.id]?.isAllMacOS ?? true)
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)
            item.subtitle = custom ? "Custom settings" : "macOS settings"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tiller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func showSettings() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(state: state)))
            window.title = "Tiller"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 780, height: 620))
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Menu bar shown while the settings window is open.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tiller", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Tiller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Tiller", action: nil, keyEquivalent: "").submenu = appMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    /// Draws the Dock icon: a mouse glyph on a rounded tile.
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            let tile = rect.insetBy(dx: 50, dy: 50)
            let path = NSBezierPath(roundedRect: tile, xRadius: 92, yRadius: 92)
            NSGradient(starting: NSColor(calibratedWhite: 0.28, alpha: 1), ending: NSColor(calibratedWhite: 0.12, alpha: 1))?
                .draw(in: path, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: 230, weight: .regular)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let origin = NSPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2)
                glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }
}
