import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var mouse: MouseController!
    private var switcher: SwitcherController!
    private var mixer: MixerController!
    private var mixerPopover: NSPopover?
    private var popoverMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem!
    /// The mixer's own menu bar icon, when that setting is on.
    private var mixerItem: NSStatusItem?
    private var mixerItemSetting: AnyCancellable?
    private var window: NSWindow?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mouse = MouseController()
        switcher = SwitcherController()
        switcher.start()
        mixer = MixerController()
        mixer.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.makeStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NSApp.mainMenu = makeMainMenu()

        mixerItemSetting = mixer.$config
            .map { $0.enabled && $0.standaloneIcon }
            .removeDuplicates()
            .sink { [weak self] shown in self?.setMixerItem(shown: shown) }

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
        switcher.stop()
        mixer.stop()
        mixer.flush()
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
    static func makeStatusIcon(symbol: String = "wrench.and.screwdriver.fill", description: String = "MacOS Toolkit") -> NSImage {
        let box = NSSize(width: 18, height: 18)
        let image = NSImage(size: box, flipped: false) { rect in
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            else { return false }
            let area = rect.insetBy(dx: 1, dy: 1)
            let fit = min(area.width / glyph.size.width, area.height / glyph.size.height, 1)
            let size = NSSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
            glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        mixerPopover?.performClose(nil)
        menu.removeAllItems()
        // With an icon of its own, the mixer opens from there instead.
        if mixer.config.enabled, !mixer.config.standaloneIcon {
            let item = NSMenuItem(title: "Audio Mixer", action: #selector(openMixerFromMenu), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: AppSection.mixer.symbol, accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for section in AppSection.allCases {
            // "Audio Mixer…" would read like the mixer itself.
            let title = section == .mixer ? "Audio Mixer Settings…" : "\(section.title)…"
            let item = NSMenuItem(title: title, action: #selector(openSection(_:)), keyEquivalent: "")
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

    private func setMixerItem(shown: Bool) {
        guard shown != (mixerItem != nil) else { return }
        if shown {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.makeStatusIcon(symbol: AppSection.mixer.symbol, description: "Audio Mixer")
            item.button?.target = self
            item.button?.action = #selector(toggleMixer)
            item.button?.toolTip = "Audio Mixer"
            mixerItem = item
        } else {
            mixerPopover?.performClose(nil)
            if let mixerItem { NSStatusBar.system.removeStatusItem(mixerItem) }
            mixerItem = nil
        }
    }

    /// The mixer's own icon opens and closes the mixer with one click.
    @objc private func toggleMixer() {
        if mixerPopover?.isShown == true {
            mixerPopover?.performClose(nil)
        } else if let button = mixerItem?.button {
            showMixer(under: button)
        }
    }

    @objc private func openMixerFromMenu() {
        guard let button = statusItem.button else { return }
        showMixer(under: button)
    }

    /// Opens on the next pass of the run loop, once any menu has closed.
    private func showMixer(under button: NSStatusBarButton) {
        DispatchQueue.main.async { [self] in
            let popover = mixerPopover ?? makeMixerPopover()
            mixerPopover = popover
            mixer.refreshPermission()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            watchForDismissal()
        }
    }

    /// A transient popover only closes by itself while the app is active, and
    /// a menu bar app often isn't, so outside clicks and Esc are watched here.
    private func watchForDismissal() {
        guard popoverMonitors.isEmpty else { return }
        let close: () -> Void = { [weak self] in self?.mixerPopover?.performClose(nil) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { _ in close() }) {
            popoverMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 {
                close()
                return nil
            }
            // A click in one of our windows other than the popover. The mixer's
            // own icon is left to its action, which toggles.
            if event.type == .leftMouseDown, let window = event.window,
               window != self?.mixerPopover?.contentViewController?.view.window,
               window != self?.mixerItem?.button?.window {
                close()
            }
            return event
        }) {
            popoverMonitors.append(monitor)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { _ in close() }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverMonitors.forEach(NSEvent.removeMonitor)
        popoverMonitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func makeMixerPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: MixerPopoverView(mixer: mixer) { [weak self] in
            self?.mixerPopover?.performClose(nil)
            self?.show(.mixer)
        })
        // Grows and shrinks with the list of apps.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        return popover
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: mouse, switcher: switcher, mixer: mixer)))
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
