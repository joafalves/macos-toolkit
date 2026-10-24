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
    private var stats: StatsController!
    /// The panel hanging from a part: the toolkit's, or System Stats'.
    private var panel: MenuBarPopover!
    /// The mixer while it's open; nil from the moment it starts closing, so
    /// a click during its fade opens a new one rather than closing it again.
    private var mixerPopover: NSPopover?
    /// One fading out, until it has closed.
    private var closingMixer: NSPopover?
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
        mixer.openMixer = { [weak self] in self?.showMixer(from: .mixer) }
        mixer.start()
        finder = FinderController()
        finder.start()
        capture = CaptureController()
        capture.onOpenSettings = { [weak self] in self?.show(.capture) }
        capture.start()
        awake = AwakeController()
        awake.start()
        stats = StatsController()
        // `--measure-idle` with `--without-stats`: the cost of the rest, with
        // nothing saved to the user's settings.
        if measureIdlePath != nil, CommandLine.arguments.contains("--without-stats") {
            stats.persists = false
            stats.config.enabled = false
        }
        stats.start()

        menuBar = MenuBarItem()
        menuBar.onClick = { [weak self] kind, rect, right in self?.menuBarClicked(kind, at: rect, right: right) }
        panel = MenuBarPopover(menuBar: menuBar)
        // Back to reading only what the menu bar shows.
        panel.onClose = { [weak self] in self?.stats.panel = [] }
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
            stats.$config.sink { _ in redraw() },
            stats.live.$tick.sink { _ in redraw() },
            model.$general.sink { [weak self] general in
                self?.menuBar.spacing = general.menuBarSpacing
                // Not for a `--measure-idle` run, which should do nothing.
                Updater.shared.automatic = general.checkForUpdates && measureIdlePath == nil
                redraw()
            },
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
            show(model.launchSection())
        }
    }

    /// Actions from the Finder extension's right-click menu.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "macos-toolkit" { finder.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(model.section ?? .welcome)
        return true
    }

    /// A recording in progress is finished first, or the file would be unplayable.
    /// Waited for ten seconds at most: a finish that hangs mustn't keep the
    /// toolkit, and with it logging out or shutting down, from ever ending.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard capture.isRecording else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        capture.finishBeforeQuit(reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: reply)
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
        stats.stop()
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
        segments += stats.segments()
        if let state = capture.recording {
            let time = MenuBarArt.duration(state.elapsed) + (state.bytes > 0 ? " · " + MenuBarArt.bytes(state.bytes) : "")
            segments.append(MenuBarSegment(kind: .recording, colored: MenuBarArt.recordingDot(paused: state.paused), text: time,
                                           label: state.paused ? String(localized: "Recording paused. Click to stop, right-click for more.")
                                                               : String(localized: "Recording. Click to stop, right-click to pause.")))
        } else if capture.config.enabled, capture.config.standaloneIcon {
            segments.append(MenuBarSegment(kind: .capture, glyph: MenuBarArt.glyph(AppSection.capture.symbol), label: AppSection.capture.title))
        }
        if awake.config.enabled, awake.config.menuBarIcon != .none {
            let time = awake.config.menuBarIcon == .cup ? nil : awake.menuBarTime
            let left = time?.text, widest = time?.widest
            let label = String(localized: "Keep Awake, \(awake.status.prefix(1).lowercased() + awake.status.dropFirst())")
            if awake.config.menuBarIcon == .pill, awake.isOn, let session = awake.session {
                segments.append(MenuBarSegment(kind: .awake, glyph: MenuBarArt.awakeBadge(fraction: session.fractionLeft(), time: left, widthOf: widest), label: label))
            } else {
                segments.append(MenuBarSegment(kind: .awake, glyph: MenuBarArt.cup(on: awake.isOn, beforeText: left != nil), text: left,
                                               widthOf: widest, label: label))
            }
        }
        if mixer.config.enabled, mixer.config.menuBarIcon != .none {
            let volume = mixer.mainVolume, muted = mixer.mainMuted || mixer.mainVolume <= 0
            let label = mixer.mainMuted ? String(localized: "Audio Mixer, muted") : String(localized: "Audio Mixer, volume \(Int((volume * 100).rounded()))%")
            switch mixer.config.menuBarIcon {
            case .mixer:
                segments.append(MenuBarSegment(kind: .mixer, glyph: MenuBarArt.glyph(AppSection.mixer.symbol), label: AppSection.mixer.title))
            case .volume:
                segments.append(MenuBarSegment(kind: .mixer, glyph: MenuBarArt.speaker(volume: volume, muted: muted), label: label))
            case .volumePercent:
                // The volume next to the speaker, like the battery's percentage.
                // Muted keeps the number, greyed, so you can see what unmuting brings back.
                // As wide as two digits whatever the volume: room for "100%" left a
                // gap after "50%", so "100%" is fitted into the room of "99%".
                segments.append(MenuBarSegment(kind: .mixer, glyph: MenuBarArt.plainSpeaker(muted: muted),
                                               text: "\(Int((volume * 100).rounded()))%", dimText: mixer.mainMuted, widthOf: "99%", fitted: true, label: label))
            case .volumeBadge:
                segments.append(MenuBarSegment(kind: .mixer, glyph: MenuBarArt.volumeBadge(volume: volume, muted: muted), label: label))
            case .none:
                break
            }
        }
        // In the order set in Settings; each tool's own parts stay together.
        let order = model.general.menuBarOrder
        segments = order.flatMap { tool in segments.filter { $0.kind.tool == tool } }
        menuBar.show(segments)
        // A panel whose part was just turned off has nothing to hang from.
        if let kind = panel?.kind, !segments.contains(where: { $0.kind == kind }) { panel.close() }
        panel?.follow()
    }

    private func menuBarClicked(_ kind: MenuBarSegment.Kind, at rect: NSRect, right: Bool) {
        if kind != .mixer { mixerPopover?.performClose(nil) }
        // A second click on the same part closes its panel.
        if panel.isShown {
            let same = panel.kind == kind
            panel.close()
            if same { return }
        }
        switch kind {
        case .stat(let stat):
            showStats([stat], from: kind)
        case .stats:
            showStats(stats.config.shown, from: kind)
        case .toolkit:
            showToolkitPanel()
        case .capture:
            // After this click is done, so the toolbar gets the keyboard.
            DispatchQueue.main.async { self.capture.toggleToolbar() }
        case .recording:
            guard right else { return capture.stopRecording() }
            let menu = NSMenu()
            let paused = capture.recording?.paused == true
            menu.addItem(withTitle: paused ? String(localized: "Resume Recording") : String(localized: "Pause Recording"), action: #selector(pauseRecording), keyEquivalent: "").target = self
            menu.addItem(withTitle: String(localized: "Stop Recording"), action: #selector(stopRecording), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Discard Recording"), action: #selector(discardRecording), keyEquivalent: "").target = self
            popUp(menu, from: .recording, at: rect)
        case .awake:
            showAwake(from: .awake)
        case .mixer:
            if mixerPopover != nil {
                mixerPopover?.performClose(nil)
            } else {
                showMixer(from: .mixer)
            }
        }
    }

    /// Its panel reads everything it shows while it's open, from now.
    private func showStats(_ kinds: [StatKind], from kind: MenuBarSegment.Kind) {
        stats.panel = kinds
        panel.show(from: kind) {
            StatsPanelView(stats: stats, kinds: kinds, close: { [weak self] in self?.panel.close() }) { [weak self] in
                self?.panel.close()
                self?.show(.stats)
            }
        }
    }

    /// Keep Awake's panel, from its own part or, with none, the toolkit's.
    private func showAwake(from kind: MenuBarSegment.Kind) {
        panel.show(from: kind) {
            AwakePanelView(awake: awake) { [weak self] in
                self?.panel.close()
                self?.show(.awake)
            }
        }
    }

    /// As the item's own menu, so macOS keeps the item lit while it's open.
    private func popUp(_ menu: NSMenu, from kind: MenuBarSegment.Kind, at rect: NSRect) {
        menuBar.open(menu, for: kind)
    }

    @objc private func pauseRecording() { capture.togglePause() }
    @objc private func discardRecording() { capture.discardRecording() }

    private func showToolkitPanel() {
        let actions = ToolkitPanelActions(
            open: { [weak self] section in
                self?.panel.close()
                self?.show(section)
            },
            openCapture: { [weak self] in
                self?.panel.close()
                self?.openCaptureToolbar()
            },
            stopRecording: { [weak self] in self?.capture.stopRecording() },
            openMixer: { [weak self] in
                self?.panel.close()
                self?.showMixer(from: .toolkit)
            },
            openAwake: { [weak self] in self?.showAwake(from: .toolkit) })
        panel.show(from: .toolkit) {
            ToolkitPanelView(mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder,
                             capture: capture, awake: awake, stats: stats, actions: actions)
        }
    }

    /// After the panel has closed, so the toolbar gets the keyboard.
    private func openCaptureToolbar() {
        DispatchQueue.main.async { self.capture.openToolbar() }
    }

    @objc private func stopRecording() {
        capture.stopRecording()
    }

    /// Opens on the next pass of the run loop, once any menu has closed,
    /// hanging from the segment it was opened from.
    private func showMixer(from kind: MenuBarSegment.Kind) {
        DispatchQueue.main.async { [self] in
            guard let button = menuBar.button, let rect = menuBar.rect(of: kind) else { return }
            // Before the panel, which takes a moment to build.
            menuBar.setPressed(kind)
            // One still closing (a quick second click) isn't reused: it's on its
            // way out, and a new one opens beside it.
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
        // Not a click on the menu bar item, which toggles the mixer itself:
        // closing here too made that click close it and open it again.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            if self?.menuBar.contains(screenPoint: NSEvent.mouseLocation) != true { close() }
        }) {
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

    /// As it starts closing, not once its fade is over, it's no longer the
    /// open one: the next click opens.
    func popoverWillClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === mixerPopover else { return }
        closingMixer = popover
        mixerPopover = nil
        menuBar.setPressed(nil)
    }

    /// Done closing. If a new one opened meanwhile, it keeps the listening
    /// and the watching for clicks elsewhere.
    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === closingMixer else { return }
        // Let go of rather than kept for next time: a closed popover keeps its
        // SwiftUI view alive, and the playing bars went on animating unseen.
        closingMixer = nil
        guard mixerPopover == nil else { return }
        mixer.panelOpen = false
        popoverMonitors.forEach(NSEvent.removeMonitor)
        popoverMonitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func makeMixerPopover() -> NSPopover {
        let popover = NSPopover()
        // Closed by us (clicks elsewhere, Esc, switching apps), not by AppKit:
        // its transient closing took the click on the menu bar item too, which
        // then toggled it open again, and a quick click to reopen was lost.
        popover.behavior = .applicationDefined
        popover.delegate = self
        let host = NSHostingController(rootView: MixerPopoverView(mixer: mixer, close: { [weak self] in
            self?.mixerPopover?.performClose(nil)
        }) { [weak self] in
            self?.mixerPopover?.performClose(nil)
            self?.show(.mixer)
        })
        // Grows and shrinks with the list of apps.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        return popover
    }

    @objc private func openSettings() {
        show(.general)
    }

    @objc private func openAbout() {
        show(.about)
    }

    /// Menu bar shown while the main window is open.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About MacOS Toolkit"), action: #selector(openAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide MacOS Toolkit"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit MacOS Toolkit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "MacOS Toolkit", action: nil, keyEquivalent: "").submenu = appMenu

        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: String(localized: "Window"), action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    // MARK: - Window

    private func show(_ section: AppSection) {
        model.section = section
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture, awake: awake, stats: stats)))
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
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        var start = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { start = cpu() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 68) {
            report += String(format: "CPU idle, no window: %.2f%% of a core over a minute\n", (cpu() - start) / 60 * 100)
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
