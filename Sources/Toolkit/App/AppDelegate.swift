import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var mouse: MouseController!
    private var switcher: SwitcherController!
    private var layout: LayoutController!
    private var mixer: MixerController!
    private var finder: FinderController!
    private var capture: CaptureController!
    private var awake: AwakeController!
    private var mixerPopover: NSPopover?
    private var popoverMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    /// The toolkit's one menu bar item, with a segment for each tool that has
    /// a place there.
    private var menuBar: MenuBarItem!
    private var menuBarUpdates: [AnyCancellable] = []
    private var window: NSWindow?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the tools: their taps read it from their own threads.
        FrontApp.start()
        mouse = MouseController()
        switcher = SwitcherController()
        switcher.start()
        layout = LayoutController()
        layout.start()
        mixer = MixerController()
        mixer.start()
        finder = FinderController()
        finder.start()
        capture = CaptureController()
        capture.onOpenSettings = { [weak self] in self?.show(.capture) }
        capture.start()
        awake = AwakeController()
        awake.start()

        menuBar = MenuBarItem()
        menuBar.onClick = { [weak self] kind, rect, right in self?.menuBarClicked(kind, at: rect, right: right) }
        // Published values arrive before they're stored, so the item is drawn
        // again on the next pass, from the stored ones.
        let redraw: () -> Void = { [weak self] in DispatchQueue.main.async { self?.updateMenuBar() } }
        menuBarUpdates = [
            mixer.$config.sink { _ in redraw() },
            mixer.$mainVolume.sink { _ in redraw() },
            mixer.$mainMuted.sink { _ in redraw() },
            capture.$config.sink { _ in redraw() },
            capture.$recording.sink { _ in redraw() },
            awake.$config.sink { _ in redraw() },
            awake.$session.sink { _ in redraw() },
            awake.$minute.sink { _ in redraw() },
            model.$general.sink { [weak self] general in self?.menuBar.spacing = general.menuBarSpacing },
        ]
        updateMenuBar()

        NSApp.mainMenu = makeMainMenu()

        // Restore on `kill` too, not only on a regular quit.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        // A launch from the login item should stay in the background.
        if let path = measureIdlePath {
            measureIdle(into: path)
        } else if !Self.launchedAsLoginItem {
            show(.mouse)
        }
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
        layout.stop()
        mixer.stop()
        mixer.flush()
        finder.stop()
        capture.stop()
        awake.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: - Menus

    // MARK: - The menu bar item

    private func updateMenuBar() {
        var segments = [MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit")]
        if let state = capture.recording {
            let time = MenuBarArt.duration(state.elapsed) + (state.bytes > 0 ? " · " + MenuBarArt.bytes(state.bytes) : "")
            segments.append(MenuBarSegment(kind: .recording, colored: MenuBarArt.recordingDot(paused: state.paused), text: time,
                                           label: state.paused ? "Recording paused. Click to stop, right-click for more." : "Recording. Click to stop, right-click to pause."))
        } else if capture.config.enabled, capture.config.standaloneIcon {
            segments.append(MenuBarSegment(kind: .capture, glyph: MenuBarArt.glyph(AppSection.capture.symbol), label: "Screen Capture"))
        }
        if awake.config.enabled, awake.config.menuBarIcon != .none {
            let left = awake.isOn ? awake.session?.until.map { AwakeController.left($0.timeIntervalSinceNow) } : nil
            let label = "Keep Awake, " + awake.status.prefix(1).lowercased() + awake.status.dropFirst()
            if awake.config.menuBarIcon == .pill, awake.isOn, let session = awake.session {
                segments.append(MenuBarSegment(kind: .awake, glyph: MenuBarArt.awakeBadge(fraction: session.fractionLeft(), time: left), label: label))
            } else {
                segments.append(MenuBarSegment(kind: .awake, glyph: MenuBarArt.cup(on: awake.isOn, beforeText: left != nil), text: left, label: label))
            }
        }
        if mixer.config.enabled, mixer.config.menuBarIcon != .none {
            let volume = mixer.mainVolume, muted = mixer.mainMuted || mixer.mainVolume <= 0
            let label = mixer.mainMuted ? "Audio Mixer, muted" : "Audio Mixer, volume \(Int((volume * 100).rounded()))%"
            switch mixer.config.menuBarIcon {
            case .mixer:
                segments.append(MenuBarSegment(kind: .mixer, glyph: MenuBarArt.glyph(AppSection.mixer.symbol), label: "Audio Mixer"))
            case .volume:
                segments.append(MenuBarSegment(kind: .mixer, glyph: MenuBarArt.speaker(volume: volume, muted: muted), label: label))
            case .volumePercent:
                // The volume next to the speaker, like the battery's percentage.
                // Muted keeps the number, greyed, so you can see what unmuting brings back.
                segments.append(MenuBarSegment(kind: .mixer, glyph: MenuBarArt.plainSpeaker(muted: muted),
                                               text: "\(Int((volume * 100).rounded()))%", dimText: mixer.mainMuted, label: label))
            case .volumeBadge:
                segments.append(MenuBarSegment(kind: .mixer, glyph: MenuBarArt.volumeBadge(volume: volume, muted: muted), label: label))
            case .none:
                break
            }
        }
        menuBar.show(segments)
    }

    private func menuBarClicked(_ kind: MenuBarSegment.Kind, at rect: NSRect, right: Bool) {
        if kind != .mixer { mixerPopover?.performClose(nil) }
        switch kind {
        case .toolkit:
            let menu = NSMenu()
            fillMenu(menu)
            popUp(menu, from: .toolkit, at: rect)
        case .capture:
            // After this click is done, so the toolbar gets the keyboard.
            DispatchQueue.main.async { self.capture.toggleToolbar() }
        case .recording:
            guard right else { return capture.stopRecording() }
            let menu = NSMenu()
            let paused = capture.recording?.paused == true
            menu.addItem(withTitle: paused ? "Resume Recording" : "Pause Recording", action: #selector(pauseRecording), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Discard Recording", action: #selector(discardRecording), keyEquivalent: "").target = self
            popUp(menu, from: .recording, at: rect)
        case .awake:
            let menu = NSMenu()
            awake.menuItems { [weak self] in self?.show(.awake) }.forEach(menu.addItem)
            popUp(menu, from: .awake, at: rect)
        case .mixer:
            if mixerPopover?.isShown == true {
                mixerPopover?.performClose(nil)
            } else {
                showMixer(from: .mixer)
            }
        }
    }

    /// As the item's own menu, so macOS keeps the item lit while it's open.
    private func popUp(_ menu: NSMenu, from kind: MenuBarSegment.Kind, at rect: NSRect) {
        menuBar.open(menu, for: kind)
    }

    @objc private func pauseRecording() { capture.togglePause() }
    @objc private func discardRecording() { capture.discardRecording() }

    private func fillMenu(_ menu: NSMenu) {
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
        // With no part of its own, its menu is a submenu here.
        if awake.config.enabled, awake.config.menuBarIcon == .none {
            let item = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: awake.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer", accessibilityDescription: nil)
            item.state = awake.isOn ? .on : .off
            let submenu = NSMenu()
            awake.menuItems { [weak self] in self?.show(.awake) }.forEach(submenu.addItem)
            item.submenu = submenu
            menu.addItem(item)
            menu.addItem(.separator())
        }
        // Under a header, so the tools' own names don't read like the tools themselves.
        menu.addItem(.sectionHeader(title: "Settings"))
        for section in AppSection.allCases {
            if section == .general { menu.addItem(.separator()) }
            let item = NSMenuItem(title: section.title, action: #selector(openSection(_:)), keyEquivalent: "")
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

    /// From the toolkit's menu, when the mixer has no segment of its own.
    @objc private func openMixerFromMenu() {
        showMixer(from: .toolkit)
    }

    /// Opens on the next pass of the run loop, once any menu has closed,
    /// hanging from the segment it was opened from.
    private func showMixer(from kind: MenuBarSegment.Kind) {
        DispatchQueue.main.async { [self] in
            guard let button = menuBar.button, let rect = menuBar.rect(of: kind) else { return }
            // Before the panel, which takes a moment to build.
            menuBar.setPressed(kind)
            let popover = mixerPopover ?? makeMixerPopover()
            mixerPopover = popover
            mixer.refreshPermission()
            // Not activating the app: that brings every one of its windows to
            // the front, the settings window included. The popover works
            // without it, and closing is watched for below.
            popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
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
            // A click in one of our windows other than the popover. The menu
            // bar item is left to its own action, which toggles.
            if event.type == .leftMouseDown, let window = event.window,
               window != self?.mixerPopover?.contentViewController?.view.window,
               window != self?.menuBar.button?.window {
                close()
            }
            return event
        }) {
            popoverMonitors.append(monitor)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { _ in close() }
    }

    /// As it starts closing, not once its fade is over.
    func popoverWillClose(_ notification: Notification) {
        menuBar.setPressed(nil)
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture, awake: awake)))
            window.title = "MacOS Toolkit"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 780, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // Made anew each time it opens, so it comes back where it was.
            window.setFrameAutosaveName("Main")
            self.window = window
        }
        // Behave like a regular app (Dock icon, Cmd-Tab) while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Let go of it: kept, its views held on to their memory while
        // nothing showed them. It's quick to make again.
        DispatchQueue.main.async { self.window = nil }
    }

    /// `--measure-idle <file>`: memory with no window, with the settings
    /// window open, and after closing it, written to the file.
    private func measureIdle(into path: String) {
        var report = ""
        func note(_ label: String) {
            report += String(format: "%@: %.1f MB\n", label, Double(processFootprint()) / 1_048_576)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            note("idle, no window")
            self.show(.mouse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                note("settings window open")
                weak var closed = self.window
                self.window?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    note("after closing it")
                    // Most of what the window cost stays: AppKit and SwiftUI keep
                    // their caches once loaded. The window itself should be gone.
                    report += "window freed: \(closed == nil)\n"
                    try? report.write(toFile: path, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
