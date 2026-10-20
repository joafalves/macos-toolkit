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
    private lazy var statusItem = CaptureStatusItem(capture: self)
    private var recorder: Recorder?
    private var recordingScreen: NSScreen?
    private var frame: CapturePanel?
    private var countdown: CapturePanel?
    private var ticker: Timer?
    private var flagMonitors: [Any] = []
    /// Wall-clock time recorded before the current stretch, and when that began.
    private var recordedBefore: TimeInterval = 0
    private var stretchStart: Date?

    private var persists = true
    private(set) var isPreview = false

    init() {
        config = CaptureConfig.load()
        keys.onAction = { [weak self] action in self?.handle(action) }
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

    static func preview() -> CaptureController {
        let capture = CaptureController()
        capture.persists = false
        capture.isPreview = true
        capture.config = CaptureConfig()
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
        if config.replaceShortcuts { keys.start() } else { keys.stop() }
        statusItem.update()
    }

    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenPermission { screenPermission = screen }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != micPermission { micPermission = mic }
    }

    func requestScreenPermission() {
        // Asks once; after that, only System Settings can change it.
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        refreshPermissions()
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
        case .toolbar:
            if recorder != nil { stopRecording() } else if toolbar.isVisible { closeToolbar() } else { openToolbar() }
        }
    }

    private func startQuickSelection(copy: Bool) {
        overlay.onPick = { [weak self] target, held in
            guard let self else { return }
            self.overlay.hide()
            self.takeScreenshot(target, copy: copy || held, screen: Self.screen(of: target))
        }
        overlay.show(mode: .area, quick: true)
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
        panel.onKey = { [weak self, weak panel] event in
            guard event.keyCode == 53 else { return false }
            cancelled = true
            panel?.orderOut(nil)
            self?.countdown = nil
            return true
        }
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
                    action()
                }
            }
        }
        tick()
    }

    // MARK: - Screenshots

    /// Our capture windows, kept out of every capture.
    private var ownWindows: Set<CGWindowID> {
        Set(NSApp.windows.compactMap { $0 is CapturePanel && $0.isVisible ? CGWindowID($0.windowNumber) : nil })
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
        if config.shutterSound { Self.shutter?.play() }
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

    @discardableResult
    private func save(_ image: CGImage, scale: CGFloat, in folder: URL, format: ImageFormat) -> URL? {
        guard let data = Screenshotter.encode(image, as: format, scale: scale) else { return nil }
        let url = Self.uniqueURL(in: folder, base: "Screenshot", ext: format.fileExtension)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    private static let shutter = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)

    // MARK: - Recording

    private func startRecording(_ target: CaptureTarget, screen: NSScreen?) {
        guard ensurePermission() else { return }
        let folder = config.recordingDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recorder = Recorder(url: Self.uniqueURL(in: folder, base: "Screen Recording", ext: "mp4"))
        recorder.onInterrupted = { [weak self, weak recorder] error in
            guard let self, self.recorder === recorder else { return }
            NSLog("Toolkit: recording stopped by the system: \(error?.localizedDescription ?? "")")
            self.stopRecording()
        }
        let options = Recorder.Options(nativeResolution: config.nativeResolution, frameRate: config.frameRate,
                                       showCursor: config.showCursor, showClicks: config.showClicks,
                                       systemAudio: config.systemAudio,
                                       microphone: config.microphone && micPermission == .authorized,
                                       microphoneID: config.microphoneID)
        self.recorder = recorder
        recordingScreen = screen
        recordedBefore = 0
        stretchStart = Date()
        recording = RecordingState()
        statusItem.update()
        if case .area(let rect) = target { showFrame(around: Coordinates.toAppKit(rect)) }
        // The menu bar button and the frame are ours too, and stay out of the video.
        var excluded = ownWindows
        if let number = statusItem.windowNumber { excluded.insert(number) }
        Task { @MainActor in
            do {
                try await recorder.start(target, options: options, excluding: excluded)
                self.startTicker()
            } catch {
                self.recorder = nil
                self.recording = nil
                self.hideFrame()
                self.statusItem.update()
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
        statusItem.update()
    }

    func stopRecording(then done: (() -> Void)? = nil) {
        guard let recorder else { done?(); return }
        self.recorder = nil
        ticker?.invalidate()
        ticker = nil
        hideFrame()
        recording = nil
        statusItem.update()
        let screen = recordingScreen
        Task { @MainActor in
            let saved = await recorder.stop()
            if saved {
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
        guard let recorder else { return }
        let url = recorder.url
        stopRecording { try? FileManager.default.removeItem(at: url) }
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
        statusItem.update()
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
        alert.messageText = "The capture didn't work."
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

    /// "Screenshot 2026-10-20 at 14.03.22.png", with " (2)" and so on when taken
    /// within the same second.
    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "\(base) \(formatter.string(from: Date()))"
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
