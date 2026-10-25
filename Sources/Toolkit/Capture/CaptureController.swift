import AVFoundation
import AppKit
import ScreenCaptureKit

/// Screenshots and screen recordings: the ⇧⌘3/4/5 shortcuts, the selection
/// overlay, the toolbar, and what happens with the result.
final class CaptureController: ObservableObject {
    @Published var config: CaptureConfig {
        didSet {
            guard config != oldValue else { return }
            if persists { config.save() }
            apply()
        }
    }

    @Published private(set) var screenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var recording: RecordingState?
    @Published private(set) var hasArea = false
    /// ⌃ is down while the toolbar is open, so Capture reads Copy.
    @Published private(set) var controlHeld = false

    struct RecordingState {
        var paused = false
        var elapsed: TimeInterval = 0
        var bytes: Int64 = 0
    }

    /// Opens this tool's settings page.
    var onOpenSettings: (() -> Void)?

    private let keys = CaptureKeys()
    private let overlay = SelectionOverlay()
    private lazy var toolbar = CaptureToolbar(capture: self)
    private let thumbnails = ThumbnailStack()
    private var recorder: Recorder?
    private var recordingScreen: NSScreen?
    private var frame: CapturePanel?
    private var countdown: CapturePanel?
    /// Ends the countdown in progress without capturing.
    private var cancelCountdown: (() -> Void)?
    private var ticker: Timer?
    private var flagMonitors: [Any] = []
    private var recordingObserver: NSObjectProtocol?
    /// Wall-clock time recorded before the current stretch, and when that began.
    private var recordedBefore: TimeInterval = 0
    private var stretchStart: Date?

    private var persists = true
    private(set) var isPreview = false

    init() {
        config = CaptureConfig.load()
        keys.onAction = { [weak self] action in self?.handle(action) }
        recordingObserver = NotificationCenter.default.addObserver(forName: ShortcutRecording.changed, object: nil, queue: .main) { [weak self] _ in
            self?.keys.suspend(ShortcutRecording.active)
        }
        overlay.onCancel = { [weak self] in self?.cancelSelection() }
        overlay.onModeChange = { [weak self] mode in
            guard let self, self.toolbar.isVisible else { return }
            self.config.mode = CaptureMode(mode)
        }
        overlay.onAreaChange = { [weak self] rect in
            self?.config.lastArea = Coordinates.toCG(rect)
            self?.hasArea = true
        }
        overlay.onConfirm = { [weak self] event in self?.captureFromToolbar(event) }
    }

    /// For a snapshot of the page with Copy text from the screen on.
    static var previewText = false

    static func preview() -> CaptureController {
        let capture = CaptureController()
        capture.persists = false
        capture.isPreview = true
        capture.config = CaptureConfig()
        capture.config.textEnabled = previewText
        capture.screenPermission = true
        capture.micPermission = .authorized
        capture.hasArea = true
        return capture
    }

    // MARK: - Lifecycle

    func start() {
        // A crash while the shortcuts were ours would have left macOS's off.
        CaptureKeys.restoreSystem()
        apply()
    }

    func stop() {
        keys.stop()
        overlay.hide()
        toolbar.hide()
    }

    /// Finishes a recording in progress before quitting, so the file is usable.
    func finishBeforeQuit(_ done: @escaping () -> Void) {
        guard recorder != nil else { return done() }
        stopRecording(then: done)
    }

    var isRecording: Bool { recorder != nil }

    private func apply() {
        // A snapshot must not take the shortcuts from macOS.
        guard !isPreview else { return }
        // Switched off while it reads: the reading stops, and gives its memory back.
        if !config.enabled || !config.textEnabled {
            TextReader.cancel()
        } else {
            // Not at once: launch has enough to do.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.config.enabled, self.config.textEnabled else { return }
                TextReader.prepare()
            }
        }
        if config.enabled {
            keys.start(config.bindings)
        } else {
            keys.stop()
            closeToolbar()
            overlay.hide()
        }
    }

    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenPermission { screenPermission = screen }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != micPermission { micPermission = mic }
    }

    func requestScreenPermission() {
        Permissions.shared.request(.screenRecording)
        refreshPermissions()
    }

    /// From the Permissions list: asks, or opens System Settings once it was refused.
    func requestMicrophonePermission() {
        Permissions.shared.request(.microphone)
    }

    func setMicrophone(_ on: Bool) {
        config.microphone = on
        guard on else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.refreshPermissions()
                    if !granted { self.config.microphone = false }
                }
            }
        case .denied, .restricted:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        default:
            break
        }
    }

    func openSettings() {
        closeToolbar()
        onOpenSettings?()
    }

    // MARK: - Shortcuts

    private func handle(_ action: CaptureKeys.Action) {
        // During the timer, a shortcut stops it: otherwise both the new
        // capture and the timed one would happen.
        if let cancel = cancelCountdown { return cancel() }
        switch action {
        case .screen(let copy):
            guard recorder == nil else { return }
            closeToolbar()
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let screen { takeScreenshot(.display(screen.displayID), copy: copy, screen: screen) }
        case .area(let copy):
            guard recorder == nil else { return }
            closeToolbar()
            startQuickSelection(copy: copy)
        case .text:
            guard recorder == nil, config.textEnabled else { return }
            closeToolbar()
            startQuickSelection(copy: false, text: true)
        case .toolbar:
            if recorder != nil { stopRecording() } else if toolbar.isVisible { closeToolbar() } else { openToolbar() }
        }
    }

    /// ⇧⌘4, or with `text` ⇧⌘2: T in the overlay switches between the two.
    private func startQuickSelection(copy: Bool, text: Bool = false) {
        overlay.onPick = { [weak self] target, held in
            guard let self else { return }
            let readsText = self.overlay.readsText
            self.overlay.hide()
            if readsText {
                self.copyText(target, screen: Self.screen(of: target))
            } else {
                self.takeScreenshot(target, copy: copy || held, screen: Self.screen(of: target))
            }
        }
        overlay.show(mode: .area, quick: true, text: text, allowsText: config.textEnabled)
    }

    private func cancelSelection() {
        if toolbar.isVisible { closeToolbar() } else { overlay.hide() }
    }

    // MARK: - Toolbar

    func openToolbar() {
        guard recorder == nil else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        overlay.onPick = { [weak self] target, held in self?.begin(target, copy: held) }
        var area = config.lastArea.map(Coordinates.toAppKit)
        // An area from a display that's gone, or was rearranged.
        if let rect = area, !NSScreen.screens.contains(where: { $0.frame.contains(rect) }) { area = nil }
        overlay.show(mode: SelectionOverlay.Mode(config.mode), quick: false, area: area)
        hasArea = area != nil
        toolbar.show(on: screen)
        watchControl()
    }

    func closeToolbar() {
        toolbar.hide()
        overlay.hide()
        flagMonitors.forEach(NSEvent.removeMonitor)
        flagMonitors.removeAll()
        controlHeld = false
    }

    /// Our panels have the keyboard, but the app isn't active, so both kinds
    /// of monitor are needed to see ⌃ wherever it's pressed.
    private func watchControl() {
        guard flagMonitors.isEmpty else { return }
        let update: (NSEvent) -> Void = { [weak self] event in
            let held = SelectionOverlay.controlDown(event)
            if self?.controlHeld != held { self?.controlHeld = held }
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { update($0); return $0 }) {
            flagMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: update) {
            flagMonitors.append(global)
        }
        controlHeld = SelectionOverlay.controlDown()
    }

    func setMode(_ mode: CaptureMode) {
        config.mode = mode
        overlay.setMode(SelectionOverlay.Mode(mode))
    }

    func toggleToolbar() {
        if let cancel = cancelCountdown { return cancel() }
        if recorder != nil { stopRecording() } else if toolbar.isVisible { closeToolbar() } else { openToolbar() }
    }

    /// The Capture button, or Return.
    func captureFromToolbar(_ event: NSEvent? = nil) {
        guard toolbar.isVisible, let target = overlay.currentTarget(toolbarScreen: toolbar.screen) else { return }
        begin(target, copy: controlHeld || SelectionOverlay.controlDown(event))
    }

    /// From the toolbar: after the timer, a screenshot or a recording.
    private func begin(_ target: CaptureTarget, copy: Bool) {
        closeToolbar()
        let screen = Self.screen(of: target)
        let go = { [weak self] in
            guard let self else { return }
            if self.config.kind == .photo {
                self.takeScreenshot(target, copy: copy, screen: screen)
            } else {
                self.startRecording(target, screen: screen)
            }
        }
        if config.timer > 0 { runCountdown(config.timer, on: screen, then: go) } else { go() }
    }

    private func runCountdown(_ seconds: Int, on screen: NSScreen?, then action: @escaping () -> Void) {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 140, height: 140)
        let panel = CapturePanel(frame: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                                               width: size.width, height: size.height), level: .screenSaver)
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 64, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.cornerRadius = 28
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.frame = NSRect(x: 0, y: (size.height - 80) / 2, width: size.width, height: 80)
        box.addSubview(label)
        panel.contentView = box
        var remaining = seconds
        var cancelled = false
        let cancel = { [weak self, weak panel] in
            cancelled = true
            panel?.orderOut(nil)
            self?.countdown = nil
            self?.cancelCountdown = nil
        }
        panel.onKey = { event in
            guard event.keyCode == 53 else { return false }
            cancel()
            return true
        }
        cancelCountdown = cancel
        label.stringValue = "\(remaining)"
        panel.orderFrontRegardless()
        panel.makeKey()
        countdown = panel
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard !cancelled else { return }
                remaining -= 1
                if remaining > 0 {
                    label.stringValue = "\(remaining)"
                    tick()
                } else {
                    panel.orderOut(nil)
                    self?.countdown = nil
                    self?.cancelCountdown = nil
                    action()
                }
            }
        }
        tick()
    }

    // MARK: - Screenshots

    /// Our capture windows, kept out of every capture: those on screen, and
    /// those just hidden, which may not be gone from it yet.
    private var ownWindows: Set<CGWindowID> {
        Set(NSApp.windows.compactMap { $0 is CapturePanel && $0.isVisible ? $0.windowID : nil }).union(CapturePanel.lingering)
    }

    private func takeScreenshot(_ target: CaptureTarget, copy: Bool, screen: NSScreen?) {
        guard ensurePermission() else { return }
        let config = config
        let excluded = ownWindows
        Task { @MainActor in
            do {
                let (image, scale) = try await Screenshotter.capture(target, config: config, excluding: excluded)
                self.deliver(image, scale: scale, copy: copy, screen: screen)
            } catch {
                self.report(error)
            }
        }
    }

    private func deliver(_ image: CGImage, scale: CGFloat, copy: Bool, screen: NSScreen?) {
        NSLog("Toolkit: screenshot \(image.width)×\(image.height), \(copy ? "to the clipboard" : "to a file")\(copy && config.saveWhenCopying ? " and a file" : "")")
        if config.shutterSound { SystemSound.shutter?.play() }
        var file: URL?
        if copy, let png = Screenshotter.encode(image, as: .png, scale: scale) {
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(png, forType: .png)
        }
        if !copy || config.saveWhenCopying {
            file = save(image, scale: scale, in: config.screenshotDirectory, format: config.format)
        }
        let format = config.format
        thumbnails.show(image: image, scale: scale, file: file, isVideo: false, on: screen) { [weak self] in
            // A clipboard-only shot gets a file when it's dragged or opened.
            self?.save(image, scale: scale, in: FileManager.default.temporaryDirectory, format: format)
        }
    }

    /// The text in the target, or what a code in it holds, to the clipboard.
    /// The clipboard is left alone when there's none.
    private func copyText(_ target: CaptureTarget, screen: NSScreen?) {
        guard config.textEnabled, ensurePermission() else { return }
        var config = config
        // The window as it is: a backdrop has no text in it.
        config.windowStyle = .plain
        let excluded = ownWindows
        Task { @MainActor in
            do {
                let (image, _) = try await Screenshotter.capture(target, config: config, excluding: excluded)
                // Usually well under a second. The first time ever it's much
                // longer, and the card says why rather than nothing happening.
                var putAway: (() -> Void)?
                let slow = DispatchWorkItem { putAway = self.thumbnails.show(text: .reading, on: screen) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: slow)
                let text = await TextReader.read(image)
                slow.cancel()
                putAway?()
                // Switched off meanwhile: nothing was read, and nothing to say.
                guard self.config.textEnabled else { return }
                NSLog("Toolkit: text from \(image.width)×\(image.height): \(text.map { "\($0.count) characters" } ?? "none")")
                if let text {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(text, forType: .string)
                }
                self.thumbnails.show(text: text.map(TextThumbnailView.State.copied) ?? .none, on: screen)
            } catch {
                self.report(error)
            }
        }
    }

    @discardableResult
    private func save(_ image: CGImage, scale: CGFloat, in folder: URL, format: ImageFormat) -> URL? {
        guard let data = Screenshotter.encode(image, as: format, scale: scale) else { return nil }
        let (date, time) = Self.now()
        let url = Self.uniqueURL(in: folder, stem: String(localized: "Screenshot \(date) at \(time)"), ext: format.fileExtension)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Recording

    func startRecording(_ target: CaptureTarget, screen: NSScreen?) {
        guard ensurePermission() else { return }
        let folder = config.recordingDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (date, time) = Self.now()
        let recorder = Recorder(url: Self.uniqueURL(in: folder, stem: String(localized: "Screen Recording \(date) at \(time)"), ext: "mp4"))
        recorder.onInterrupted = { [weak self, weak recorder] error in
            guard let self, self.recorder === recorder else { return }
            NSLog("Toolkit: recording stopped by the system: \(error?.localizedDescription ?? "")")
            self.stopRecording()
        }
        let options = Recorder.Options(quality: config.quality, frameRate: config.frameRate,
                                       showCursor: config.showCursor, showClicks: config.showClicks,
                                       systemAudio: config.systemAudio,
                                       microphone: config.microphone && micPermission == .authorized,
                                       microphoneID: config.microphoneID)
        self.recorder = recorder
        recordingScreen = screen
        recordedBefore = 0
        stretchStart = Date()
        recording = RecordingState()
        if case .area(let rect) = target { showFrame(around: Coordinates.toAppKit(rect)) }
        Task { @MainActor in
            // The outline is ours too, and stays out of the video (the stop
            // button is left out by the recorder, with our other menu bar items).
            let excluded = self.ownWindows
            do {
                try await recorder.start(target, options: options, excluding: excluded)
                // Stopped while it was starting: no clock for it.
                guard self.recorder === recorder else { return }
                self.startTicker()
            } catch {
                // Stopped while starting: nothing to report.
                guard self.recorder === recorder else { return }
                self.recorder = nil
                self.recording = nil
                self.hideFrame()
                self.report(error)
            }
        }
    }

    func togglePause() {
        guard let recorder, var state = recording else { return }
        state.paused.toggle()
        recorder.setPaused(state.paused)
        if state.paused {
            recordedBefore += Date().timeIntervalSince(stretchStart ?? Date())
            stretchStart = nil
        } else {
            stretchStart = Date()
        }
        recording = state
    }

    /// `keep` false throws the file away, without the clipboard or a thumbnail.
    func stopRecording(keep: Bool = true, then done: (() -> Void)? = nil) {
        guard let recorder else { done?(); return }
        self.recorder = nil
        ticker?.invalidate()
        ticker = nil
        hideFrame()
        recording = nil
        let screen = recordingScreen
        Task { @MainActor in
            let saved = await recorder.stop()
            if saved, !keep {
                try? FileManager.default.removeItem(at: recorder.url)
            } else if saved {
                let board = NSPasteboard.general
                board.clearContents()
                board.writeObjects([recorder.url as NSURL])
                ThumbnailStack.show(video: recorder.url, in: self.thumbnails, on: screen)
            }
            done?()
        }
    }

    /// Throws the recording away.
    func discardRecording() {
        stopRecording(keep: false)
    }

    private func startTicker() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let recorder, var state = recording else { return }
        state.elapsed = recordedBefore + (stretchStart.map { Date().timeIntervalSince($0) } ?? 0)
        state.bytes = (try? FileManager.default.attributesOfItem(atPath: recorder.url.path)[.size] as? Int64) ?? 0
        recording = state
    }

    /// A thin outline around the area being recorded, outside it so it never
    /// shows in the video.
    private func showFrame(around rect: NSRect) {
        let outer = rect.insetBy(dx: -3, dy: -3)
        let panel = CapturePanel(frame: outer, level: .screenSaver)
        panel.ignoresMouseEvents = true
        let view = NSView(frame: NSRect(origin: .zero, size: outer.size))
        view.wantsLayer = true
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
        view.layer?.cornerRadius = 3
        panel.contentView = view
        panel.orderFrontRegardless()
        frame = panel
    }

    private func hideFrame() {
        frame?.orderOut(nil)
        frame = nil
    }

    // MARK: - Helpers

    private func ensurePermission() -> Bool {
        refreshPermissions()
        guard !screenPermission else { return true }
        requestScreenPermission()
        onOpenSettings?()
        return false
    }

    private func report(_ error: Error) {
        NSLog("Toolkit: capture failed: \(error.localizedDescription)")
        refreshPermissions()
        if !screenPermission {
            onOpenSettings?()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The capture didn't work.")
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func screen(of target: CaptureTarget) -> NSScreen? {
        switch target {
        case .display(let id):
            return NSScreen.screens.first { $0.displayID == id }
        case .area(let rect):
            return NSScreen.screens.max { $0.cgFrame.intersection(rect).area < $1.cgFrame.intersection(rect).area }
        case .window(let id):
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return NSScreen.screens.max { $0.cgFrame.intersection(rect).area < $1.cgFrame.intersection(rect).area }
        }
    }

    /// "2026-10-20" and "14.03.22", for a name like macOS's own
    /// "Screenshot 2026-10-20 at 14.03.22".
    static func now() -> (date: String, time: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        formatter.dateFormat = "HH.mm.ss"
        return (date, formatter.string(from: Date()))
    }

    /// `stem` plus the extension, with " (2)" and so on when taken within the
    /// same second.
    static func uniqueURL(in folder: URL, stem: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

extension CaptureMode {
    init(_ mode: SelectionOverlay.Mode) {
        switch mode {
        case .area: self = .area
        case .window: self = .window
        case .screen: self = .screen
        }
    }
}

extension SelectionOverlay.Mode {
    init(_ mode: CaptureMode) {
        switch mode {
        case .area: self = .area
        case .window: self = .window
        case .screen: self = .screen
        }
    }
}
