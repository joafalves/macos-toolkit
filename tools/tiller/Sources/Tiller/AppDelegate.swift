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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
