import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var mouse: MouseController!
    private var switcher: SwitcherController!
    private var mixer: MixerController!
    private var finder: FinderController!
    private var capture: CaptureController!
    private var mixerPopover: NSPopover?
    private var popoverMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem!
    /// The mixer's own menu bar icon, when that setting is on.
    private var mixerItem: NSStatusItem?
    private var mixerItemSetting: AnyCancellable?
    private var mixerVolumeIcon: AnyCancellable?
    private var mixerItemKind = MixerMenuBarIcon.none
    private var window: NSWindow?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mouse = MouseController()
        switcher = SwitcherController()
        switcher.start()
        mixer = MixerController()
        mixer.start()
        finder = FinderController()
        finder.start()
        capture = CaptureController()
        capture.onOpenSettings = { [weak self] in self?.show(.capture) }
        capture.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.makeStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NSApp.mainMenu = makeMainMenu()

        mixerItemSetting = mixer.$config
            .map { $0.enabled ? $0.menuBarIcon : .none }
            .removeDuplicates()
            .sink { [weak self] icon in self?.setMixerItem(icon) }
        // The volume icon follows the main volume. Published values arrive
        // before they're stored, so the new ones are passed along.
        mixerVolumeIcon = mixer.$mainVolume
            .combineLatest(mixer.$mainMuted)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] volume, muted in self?.updateVolumeIcon(volume: volume, muted: muted) }

        // Restore on `kill` too, not only on a regular quit.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        // A launch from the login item should stay in the background.
        if !Self.launchedAsLoginItem { show(.mouse) }
    }

    /// Actions from the Finder extension's right-click menu.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "macos-toolkit" { finder.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(model.section ?? .mouse)
        return true
    }

    /// A recording in progress is finished first, or the file would be unplayable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard capture.isRecording else { return .terminateNow }
        capture.finishBeforeQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if mouse.config.restoreOnQuit { mouse.restoreAll() }
        switcher.stop()
        mixer.stop()
        mixer.flush()
        finder.stop()
        capture.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// A menu bar glyph at the size macOS draws its own status symbols, in an
    /// item as wide as the glyph. Squeezing symbols into the square 18pt box
    /// shrank the wide ones to a fraction of the menu bar's other icons.
    static func makeStatusIcon(symbol: String = "wrench.and.screwdriver.fill", description: String = "MacOS Toolkit") -> NSImage {
        menuBarImage(symbol, widthOf: [symbol], description: description) ?? NSImage()
    }

    /// Every symbol is drawn at the same size, in an image as wide as the
    /// widest of `widthOf`, so an icon that switches between them doesn't
    /// change width. The glyph sits at the left, like macOS's Sound icon.
    static func menuBarImage(_ symbol: String, widthOf symbols: [String], description: String? = nil) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        func symbolImage(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        guard let glyph = symbolImage(symbol) else { return nil }
        let width = ceil(([glyph.size.width] + symbols.compactMap { symbolImage($0)?.size.width }).max() ?? glyph.size.width)
        let height: CGFloat = 18
        // Only symbols taller than the menu bar allows are scaled down.
        let fit = min(1, height / glyph.size.height)
        let size = NSSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            glyph.draw(in: NSRect(x: 0, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description ?? symbol
        return image
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        mixerPopover?.performClose(nil)
        menu.removeAllItems()
        // With an icon of its own, the mixer opens from there instead.
        if mixer.config.enabled, mixer.config.menuBarIcon == .none {
            let item = NSMenuItem(title: "Audio Mixer", action: #selector(openMixerFromMenu), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: AppSection.mixer.symbol, accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if capture.isRecording {
            let item = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        } else if capture.config.enabled, !capture.config.standaloneIcon {
            let item = NSMenuItem(title: "Screen Capture", action: #selector(openCaptureToolbar), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: AppSection.capture.symbol, accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for section in AppSection.allCases {
            if section == .general { menu.addItem(.separator()) }
            // "Audio Mixer…" would read like the mixer itself.
            let title = section == .mixer || section == .capture ? "\(section.title) Settings…" : "\(section.title)…"
            let item = NSMenuItem(title: title, action: #selector(openSection(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
            item.representedObject = section.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacOS Toolkit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// After the menu has closed, so the toolbar gets the keyboard.
    @objc private func openCaptureToolbar() {
        DispatchQueue.main.async { self.capture.openToolbar() }
    }

    @objc private func stopRecording() {
        capture.stopRecording()
    }

    @objc private func openSection(_ sender: NSMenuItem) {
        show((sender.representedObject as? String).flatMap(AppSection.init) ?? .mouse)
    }

    private func setMixerItem(_ kind: MixerMenuBarIcon) {
        mixerItemKind = kind
        if kind != .none {
            let item = mixerItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(toggleMixer)
            item.button?.toolTip = "Audio Mixer"
            mixerItem = item
            if kind == .mixer {
                item.button?.title = ""
                item.button?.image = Self.makeStatusIcon(symbol: AppSection.mixer.symbol, description: "Audio Mixer")
            } else {
                updateVolumeIcon(volume: mixer.mainVolume, muted: mixer.mainMuted)
            }
        } else {
            mixerPopover?.performClose(nil)
            if let mixerItem { NSStatusBar.system.removeStatusItem(mixerItem) }
            mixerItem = nil
        }
    }

    /// The speaker macOS's own Sound item uses: more waves as the volume goes
    /// up, crossed out when muted.
    private func updateVolumeIcon(volume: Float, muted: Bool) {
        guard [.volume, .volumePercent, .volumeBadge].contains(mixerItemKind), let button = mixerItem?.button else { return }
        let symbol: String
        if muted || volume <= 0 {
            symbol = "speaker.slash.fill"
        } else {
            symbol = volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
        let percent = "\(Int((volume * 100).rounded()))%"
        if mixerItemKind == .volumeBadge {
            button.title = ""
            button.image = Self.makeVolumeBadge(volume: volume, muted: muted || volume <= 0)
            button.image?.accessibilityDescription = muted ? "Audio Mixer, muted" : "Audio Mixer, volume \(percent)"
            return
        }
        button.image = Self.makeVolumeIcon(symbol: symbol)
        button.image?.accessibilityDescription = muted ? "Audio Mixer, muted" : "Audio Mixer, volume \(percent)"
        guard mixerItemKind == .volumePercent else {
            button.title = ""
            return
        }
        // The volume next to the speaker, like the battery's percentage. Muted
        // keeps the number, greyed, so you can see what unmuting brings back.
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: " " + percent, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: muted ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
    }

    /// A pill filled up to the volume, with the speaker and the number cut out
    /// of it, like the battery's icon with its percentage inside. Always as wide as "100", so
    /// the menu bar doesn't shift as the number changes.
    static func makeVolumeBadge(volume: Float, muted: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        let text = NSAttributedString(string: muted ? "off" : "\(Int((volume * 100).rounded()))",
                                      attributes: [.font: font, .foregroundColor: NSColor.black])
        let widest = NSAttributedString(string: "100", attributes: [.font: font]).size().width
        let cone = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        let coneWidth = cone?.size.width ?? 8
        // As tall as the other menu bar symbols, about 16pt of the 18pt box.
        let pill = NSRect(x: 0, y: 1, width: ceil(3 + coneWidth + 1 + widest + 3), height: 16)
        let image = NSImage(size: NSSize(width: pill.width, height: 18), flipped: false) { _ in
            // Filled up to the volume like the battery's charge, the rest faint.
            let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            NSColor.black.withAlphaComponent(0.4).setFill()
            shape.fill()
            if !muted {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                // Two lots of 40% would show where they overlap, so the fill replaces it.
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.black.setFill()
                NSRect(x: pill.minX, y: pill.minY, width: pill.width * CGFloat(min(1, max(0, volume))), height: pill.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if let cone {
                cone.draw(in: NSRect(x: 3, y: pill.midY - cone.size.height / 2, width: cone.size.width, height: cone.size.height),
                          from: .zero, operation: .destinationOut, fraction: 1)
            }
            // The number is cut out too, centred in the space after the speaker.
            let size = text.size()
            let area = NSRect(x: 3 + coneWidth + 1, y: pill.minY, width: widest, height: pill.height)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let volumeSymbols = ["speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]

    static func makeVolumeIcon(symbol: String) -> NSImage? {
        menuBarImage(symbol, widthOf: volumeSymbols)
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
            // Not activating the app: that brings every one of its windows to
            // the front, the settings window included. The popover works
            // without it, and closing is watched for below.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            watchForDismissal()
            // After showing, so creating the listening taps doesn't hold up the panel.
            DispatchQueue.main.async { self.mixer.panelOpen = true }
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
        // Esc while another app has the keyboard, which is the usual case now
        // that opening the mixer doesn't activate the toolkit.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { event in
            if event.keyCode == 53 { close() }
        }) {
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
        mixer.panelOpen = false
        // Dropped rather than kept for next time: a closed popover keeps its
        // SwiftUI view alive, and the playing bars went on animating unseen.
        mixerPopover = nil
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: mouse, switcher: switcher, mixer: mixer, finder: finder, capture: capture)))
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
