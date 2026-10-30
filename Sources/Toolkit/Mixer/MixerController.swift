import AppKit
import AudioToolbox
import CoreAudio
import DriverShared
import os

/// A row in the mixer: an app that has sound open, playing or not.
struct MixerApp: Identifiable {
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    let isPlaying: Bool

    var id: pid_t { pid }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    var transport: UInt32 = kAudioDeviceTransportTypeBuiltIn

    var symbol: String {
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return name.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "hifispeaker"
        }
    }
}

/// The output's own volume as last set here, and what the device read back
/// after it. Devices round to steps of their own (1 dB on a USB display: 60%
/// reads 59.3%), but the level is ours: while the device still reads what
/// that gave it, the level is the one set, so the keys step from 60% and not
/// from a rounding they'd land back on.
struct SetLevel {
    private var last: (output: AudioObjectID, level: Float, read: Float)?

    mutating func wrote(_ level: Float, on output: AudioObjectID, reads read: Float?) {
        last = read.map { (output, level, $0) }
    }

    mutating func level(on output: AudioObjectID, reading read: Float) -> Float {
        if let last, last.output == output, last.read == read { return last.level }
        // Set elsewhere (Control Center, the device's own buttons): that's the level now.
        last = nil
        return read
    }
}

/// Volume per app, on top of the main volume, the equalizer and the software
/// volume. While it's on, all sound goes through its taps (`applyTaps`).
final class MixerController: ObservableObject {
    @Published var config: MixerConfig {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
            if config.volumePerOutput != oldValue.volumePerOutput {
                // Nothing jumps either way: the volume in use is where both start.
                let now = currentVolume
                if config.volumePerOutput {
                    if softwareActive, let uid = currentOutput?.uid { config.software[uid] = now.isDefault ? nil : now }
                } else {
                    config.sharedVolume = now
                }
            }
            if config.enabled != oldValue.enabled {
                config.enabled ? start() : stop()
            } else if config.usesDriver != oldValue.usesDriver {
                // From one way of carrying the sound to the other. Not in a
                // picture, which only shows the setting.
                if persists {
                    stop()
                    start()
                }
            } else {
                pushEqualizer()
                // The software volume may have changed, which the taps depend on.
                refreshMainVolume()
                if config.ignored != oldValue.ignored || config.played != oldValue.played || config.hidden != oldValue.hidden {
                    refreshApps()
                } else {
                    applyTaps()
                }
            }
        }
    }

    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var outputs: [OutputDevice] = []
    @Published private(set) var output = AudioObjectID.unknown
    @Published private(set) var mainVolume: Float = 0
    @Published private(set) var mainMuted = false
    /// HDMI and some USB devices have no volume of their own.
    @Published private(set) var hasMainVolume = false
    /// The output has no volume of its own, so the main volume is applied in
    /// software by a tap on everything that plays to it.
    @Published private(set) var softwareActive = false
    /// The volume keys are being caught, which needs Accessibility.
    @Published private(set) var keysInstalled = false
    @Published private(set) var permission = AudioPermission.status
    /// Sound goes through the audio driver now, not taps.
    @Published private(set) var driverActive = false
    /// Why it doesn't, though it was asked to.
    @Published private(set) var driverProblem: DriverProblem?
    /// Being installed or removed, which takes as long as a password does.
    @Published private(set) var driverWork: DriverWork?
    /// Linked, and waiting for its device to show.
    @Published private(set) var driverStarting = false
    var driverBusy: Bool { driverWork != nil }
    @Published private(set) var driverInstall = DriverInstall.status

    /// The panel is on screen.
    var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            updateList()
        }
    }

    private var running = false
    private var persists = true
    /// False in a test run beside the installed app: its taps and the
    /// volume keys are left alone, and only these apps get taps.
    private var ownsSystem = true
    private var onlyApps: Set<String>?
    private var groups: [pid_t: AudioAppGroup] = [:]
    /// When each app last played, so recently heard apps sort above idle ones.
    private var lastPlayed: [pid_t: Date] = [:]
    /// When each tapped app last made an actual sound, by bundle ID.
    private var lastSound: [String: Date] = [:]
    /// Apps making sound right now, as last shown.
    private var audible: Set<pid_t> = []
    private var levelTimer: Timer?
    /// By bundle ID.
    private var taps: [String: AppTap] = [:]
    /// Plays everything else, at the software volume on outputs without a volume of their own.
    private var masterTap: AppTap?
    /// Apps running now, by bundle ID, so one with a volume of its own is tapped before it plays.
    private var runningBundles: Set<String> = []
    /// Processes the master still plays while their app's tap waits for a
    /// quiet moment to take them, each with a tap that only listens, to hear
    /// that moment. Many apps keep their output running in silence.
    private var listeners: [AudioObjectID: AppTap] = [:]
    /// When each listened process was last heard, or first listened to.
    private var heardAt: [AudioObjectID: Date] = [:]
    private var passPending = false
    /// App processes with their input running. On macOS 26 a process a
    /// waiting tap takes can't start an input, on any device, until a tap that
    /// takes it runs: a call app's preview froze for 14 s, macOS's timeout,
    /// each time. A running tap made while a start is held up doesn't let it
    /// go on (traced at 0.24.4), but no tap at all does (the mixer turned
    /// off, traced at 0.24.2). So the waiting tap goes first (`releasing`)
    /// and a running one follows. It goes back to waiting once the input has
    /// stopped and nothing it takes plays. The input of a process that already
    /// exists starts unannounced, and a held-up one runs nothing, so the flag
    /// is read every second (`checkRecording`). Empty where inputs aren't held up.
    private var recording: Set<AudioObjectID> = []
    /// Level ticks since the input flags were last read.
    private var ticksSinceRecordingCheck = 0
    /// Taps taken away for an input held up, by key, and when the next may be
    /// made. Their apps stay left out of the master meanwhile.
    private var releasing: [String: Date] = [:]
    /// When each process's input was first seen running, for the log.
    private var recordingSince: [AudioObjectID: Date] = [:]
    /// What was last logged, so each line says something changed.
    private var loggedPlaying: Set<AudioObjectID> = []
    private var loggedProcesses = ""
    private var loggedHolds: Set<String> = []
    /// The first pass after the mixer starts or the output changes, which
    /// reroutes everything anyway: every app goes to its own tap at once.
    /// After that, one that plays without a pause would move with a click.
    private var settling = true
    private var appsRead = false
    /// The output's channels for left and right, from 0.
    private var stereo = (0, 1)
    /// Processes that wait to move to an app's tap that couldn't be made:
    /// their quiet moment doesn't call for another pass.
    private var stranded: Set<AudioObjectID> = []
    private var hardwareVolume = false
    private var loggedMasterSkip = false
    private lazy var volumeKeys = VolumeKeys(mixer: self)
    /// Taps macOS refused, so they're not retried on every slider move.
    private var failed: Set<String> = []
    /// When to try the refused taps again. Never retried, a tap refused once
    /// left a muted app playing until its output changed. Soon at first, at
    /// the permission check's next round, then each miss waits twice as
    /// long, up to five minutes: making a tap can hold up the main thread.
    private var retryAt: Date?
    private var retryDelay: TimeInterval = 2

    private var systemListeners: [AudioListener] = []
    private var deviceListeners: [AudioListener] = []
    private var processListeners: [AudioObjectID: [AudioListener]] = [:]
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var pendingRefresh = false
    private var saveWork: DispatchWorkItem?

    /// What every tap that plays sound reads its equalizer from.
    private let equalizerState = EqualizerState()
    /// While the mixer is on the driver; nil on taps. Taps are made only without it.
    private var driver: MixerDriver?
    /// How long to wait for the driver's device, then back to taps.
    private var driverDeadline: DispatchWorkItem?
    /// Each process's bundle ID, for the driver's levels.
    private var driverBundles: [pid_t: String] = [:]
    /// Tries since the driver's device went, and that one's on the way: no
    /// taps meanwhile, which would only be taken down again.
    private var driverRetries = 0
    private var driverRetrying = false

    init() {
        config = MixerConfig.load()
        pushEqualizer()
    }

    // MARK: - Lifecycle

    func start() {
        guard config.enabled, !running else { return }
        running = true
        let info = Bundle.main.infoDictionary
        Log.mixer.notice("""
            mixer on, audio permission \(String(describing: self.permission), privacy: .public); \
            toolkit \(info?["CFBundleShortVersionString"] as? String ?? "?", privacy: .public) (\(info?["CFBundleVersion"] as? String ?? "?", privacy: .public)), \
            commit \(info?["ToolkitCommit"] as? String ?? "?", privacy: .public), \
            \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public), \
            inputs held up by waiting taps: \(Self.inputsHeldUp)
            """)
        settling = true
        appsRead = false
        if ownsSystem { AppTap.removeLeftovers() }
        startDriver()

        systemListeners = [
            AudioListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.scheduleRefresh() },
            AudioListener(.system, kAudioHardwarePropertyDevices) { [weak self] in self?.refreshDevices() },
            AudioListener(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.refreshDevices() },
        ]
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() })
        }
        // The permission can be granted in System Settings at any time.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshPermission()
            self?.retryFailed()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        let levels = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateLevels() }
        RunLoop.main.add(levels, forMode: .common)
        levelTimer = levels

        refreshDevices()
        refreshApps()
    }

    /// Puts every app back on its normal output.
    func stop() {
        guard running else { return }
        running = false
        Log.mixer.notice("mixer off")
        stopDriver()
        driverRetrying = false
        driverRetries = 0
        taps.removeAll()
        masterTap = nil
        listeners.removeAll()
        heardAt = [:]
        activity = [:]
        recording = []
        recordingSince = [:]
        releasing = [:]
        loggedPlaying = []
        loggedProcesses = ""
        loggedHolds = []
        softwareActive = false
        volumeKeys.setWanted(false)
        systemListeners.removeAll()
        deviceListeners.removeAll()
        processListeners.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        permissionTimer?.invalidate()
        permissionTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        lastSound = [:]
        audible = []
        groups = [:]
        lastPlayed = [:]
        apps = []
    }

    /// Writes a pending save now, for quitting.
    func flush() {
        saveWork?.perform()
        saveWork?.cancel()
        saveWork = nil
    }

    // MARK: - App volumes

    func volume(of app: MixerApp) -> AppVolume {
        config.apps[app.bundleID] ?? AppVolume(name: app.name)
    }

    /// The volume an app had when a drag on its slider began.
    private var dragStart: [String: Double] = [:]

    func beginAdjusting(_ app: MixerApp) {
        dragStart[app.bundleID] = volume(of: app).volume
    }

    func setVolume(_ volume: Double, of app: MixerApp) {
        update(app) { setting in
            setting.volume = volume >= 0.995 ? 1 : volume < 0.005 ? 0 : volume
            // Like the volume keys: turning an app up unmutes it.
            if setting.volume > 0 { setting.muted = false }
            if setting.volume == 0, let start = dragStart[app.bundleID], start > 0 { setting.restoreVolume = start }
        }
    }

    /// At 0% an app counts as muted, so this unmutes it back to where it was
    /// before it was turned all the way down.
    func toggleMute(_ app: MixerApp) {
        update(app) { setting in
            guard setting.isSilent else { return setting.muted = true }
            setting.muted = false
            if setting.volume == 0 { setting.volume = setting.restoreVolume ?? 1 }
        }
    }

    /// Every app back to 100% and unmuted, so all of them follow the main volume.
    func resetAll() {
        config.apps = [:]
    }

    var hasCustomVolumes: Bool { !config.apps.isEmpty }

    func forget(_ bundleID: String) {
        config.apps[bundleID] = nil
    }

    func ignore(bundleID: String, name: String) {
        config.apps[bundleID] = nil
        config.ignored[bundleID] = name
    }

    func unignore(_ bundleID: String) {
        config.ignored[bundleID] = nil
    }

    /// Takes a quiet app off the list until it plays again.
    func hide(_ app: MixerApp) {
        config.played.remove(app.bundleID)
        config.hidden.insert(app.bundleID)
    }

    private func update(_ app: MixerApp, _ change: (inout AppVolume) -> Void) {
        var setting = volume(of: app)
        change(&setting)
        setting.name = app.name
        config.apps[app.bundleID] = setting.isDefault ? nil : setting
    }

    // MARK: - Permission

    /// Shows the macOS prompt, or opens System Settings once it was denied.
    func requestPermission() {
        guard permission != .granted else { return }
        // The app delegate refreshes this when the state changes.
        Permissions.shared.request(.systemAudio)
    }

    func refreshPermission() {
        volumeKeys.retryIfNeeded()
        let status = AudioPermission.status
        guard status != permission else { return }
        permission = status
        failed.removeAll()
        applyTaps()
    }

    // MARK: - Main volume and output

    func setMainVolume(_ volume: Float) {
        if softwareActive {
            return updateSoftware { setting in
                setting.volume = volume >= 0.995 ? 1 : volume < 0.005 ? 0 : Double(volume)
                setting.muted = false
            }
        }
        shareVolume(Double(volume), muted: false)
        writeMainVolume(volume)
        // Like the volume keys: changing the volume unmutes.
        if mainMuted { output.write(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, UInt32(0)) }
        refreshMainVolume()
    }

    func toggleMainMute() {
        if softwareActive { return updateSoftware { $0.muted.toggle() } }
        shareVolume(Double(mainVolume), muted: !mainMuted)
        output.write(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, UInt32(mainMuted ? 0 : 1))
        refreshMainVolume()
    }

    /// A volume key, when the output has no volume of its own to change.
    /// Whether the volume keys have something to change on the current output.
    var handlesVolumeKeys: Bool { softwareActive || hardwareVolume }

    /// A volume key, on any output: the device's own volume where it has one,
    /// the software volume where it doesn't. The same steps either way.
    func volumeKey(_ key: VolumeKey, fine: Bool) {
        let size = fine ? Double(config.fineStep) / 100 : 1 / Double(config.keyStep.presses)
        if softwareActive {
            updateSoftware { setting in
                setting.volume = Self.step(setting.volume, muted: &setting.muted, key: key, size: size)
            }
        } else if hardwareVolume {
            var muted = mainMuted
            let volume = Self.step(Double(mainVolume), muted: &muted, key: key, size: size)
            if muted != mainMuted { toggleMainMute() }
            if !muted, volume != Double(mainVolume) { setMainVolume(Float(volume)) }
        }
    }

    /// A press lands on a whole number of steps of `size`, so a volume set with
    /// the slider moves to the next one. From muted, up unmutes before it
    /// raises anything.
    static func step(_ volume: Double, muted: inout Bool, key: VolumeKey, size: Double) -> Double {
        // Steps counted with a little slack, as Float volumes aren't exact.
        let steps = volume / size
        switch key {
        case .mute:
            muted.toggle()
            return volume
        case .up:
            if muted {
                muted = false
                return volume
            }
            return min(1, ((steps + 0.001).rounded(.down) + 1) * size)
        case .down:
            if muted { return volume }
            return max(0, ((steps - 0.001).rounded(.up) - 1) * size)
        }
    }

    private func updateSoftware(_ change: (inout SoftwareVolume) -> Void) {
        guard let uid = currentOutput?.uid else { return }
        var setting = softwareVolume
        change(&setting)
        if config.volumePerOutput {
            config.software[uid] = setting.isDefault ? nil : setting
        } else {
            config.sharedVolume = setting
        }
    }

    /// The software volume of the output in use: its own, or the one volume.
    private var softwareVolume: SoftwareVolume {
        let own = currentOutput.flatMap { config.software[$0.uid] }
        // Before there was one volume, each output had its own: the current one's is where it starts.
        return config.volumePerOutput ? own ?? SoftwareVolume() : config.sharedVolume ?? own ?? SoftwareVolume()
    }

    /// The volume in use now, where the slider is.
    private var currentVolume: SoftwareVolume {
        var volume = SoftwareVolume()
        volume.volume = Double(mainVolume)
        volume.muted = mainMuted
        return volume
    }

    /// Records a change to an output's own volume as the one volume, before
    /// it's made, so reading it back doesn't count as a change from elsewhere.
    private func shareVolume(_ volume: Double, muted: Bool) {
        guard !config.volumePerOutput else { return }
        var shared = SoftwareVolume()
        shared.volume = min(1, max(0, volume))
        shared.muted = muted
        if shared != config.sharedVolume { config.sharedVolume = shared }
    }

    /// Until then after a switch of output, a volume read that isn't the one
    /// volume is the output's own coming back (Bluetooth headphones set
    /// theirs as they connect): the one volume is set again, a few times at most.
    private var settleUntil = Date.distantPast
    private var settleTries = 0

    // MARK: - Equalizer

    /// The one in use: the shared one, or with one per output, the current
    /// output's own, or the shared one until it has one.
    var equalizer: EqualizerConfig { equalizer(for: nil) }

    /// With one per output, that output's (by UID), the settings page can
    /// set any output's; nil, or with one for all, the one in use.
    func equalizer(for output: String?) -> EqualizerConfig {
        guard config.equalizerPerOutput, let uid = output ?? currentOutput?.uid else { return config.equalizer }
        return config.equalizers[uid] ?? config.equalizer
    }

    func setEqualizerEnabled(_ enabled: Bool, for output: String? = nil) {
        updateEqualizer(for: output) { $0.enabled = enabled }
    }

    /// The bands as a drag began, for the ones beside it to follow from.
    private var bandDragStart: [Double]?

    func beginBandDrag(for output: String? = nil) {
        bandDragStart = equalizer(for: output).gains
    }

    /// `linked`: dragged with ⌥, the bands beside it follow (`EqualizerCurve.linked`).
    func setBand(_ band: Int, gain: Double, linked: Bool = false, for output: String? = nil) {
        let target = EqualizerCurve.clamped(gain, to: 0.5)
        updateEqualizer(for: output) { equalizer in
            if linked, let start = bandDragStart {
                equalizer.gains = EqualizerCurve.linked(start, band: band, to: target)
            } else {
                equalizer.gains[band] = target
            }
            equalizer.enabled = true
        }
    }

    /// One of Simple's handles, moving its region of the bands.
    func setRegion(_ region: EqualizerRegion, to level: Double, for output: String? = nil) {
        updateEqualizer(for: output) { equalizer in
            equalizer.gains = region.setting(equalizer.gains, to: level)
            equalizer.enabled = true
        }
    }

    func setPreamp(_ gain: Double, for output: String? = nil) {
        let range = EqualizerConfig.range
        updateEqualizer(for: output) { equalizer in
            equalizer.preamp = min(range, max(-range, (gain * 2).rounded() / 2))
            equalizer.enabled = true
        }
    }

    func applyPreset(_ preset: EqualizerPreset, for output: String? = nil) {
        updateEqualizer(for: output) { equalizer in
            equalizer.gains = preset.gains
            equalizer.enabled = true
        }
    }

    /// With one per output, a change is that output's own from then on.
    private func updateEqualizer(for output: String?, _ change: (inout EqualizerConfig) -> Void) {
        var equalizer = equalizer(for: output)
        change(&equalizer)
        if config.equalizerPerOutput, let uid = output ?? currentOutput?.uid {
            config.equalizers[uid] = equalizer
        } else {
            config.equalizer = equalizer
        }
    }

    /// What the taps' filters were last given, so a change elsewhere in the
    /// config doesn't work the curve out again.
    private var pushed: (EqualizerConfig, Double)?

    /// The current output's equalizer to the taps: the filters' gains that
    /// give its sliders, and its preamp.
    private func pushEqualizer() {
        let rate = output.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self).flatMap { $0 > 0 ? $0 : nil } ?? 48_000
        let equalizer = self.equalizer
        if let pushed, pushed.0 == equalizer, pushed.1 == rate { return }
        pushed = (equalizer, rate)
        let gains = EqualizerCurve.filterGains(for: equalizer.gains, sampleRate: rate)
        equalizerState.set(on: equalizer.isActive, gains: gains, preamp: equalizer.preamp)
    }

    /// Opens the mixer from its part of the menu bar; set by the app.
    var openMixer: (() -> Void)?

    func keysInstalledChanged(_ installed: Bool) {
        keysInstalled = installed
    }

    func requestAccessibility() {
        Permissions.shared.request(.accessibility)
    }

    func setOutput(_ device: OutputDevice) {
        if driver?.device != nil {
            driver?.setOutput(device.id)
            refreshDevices()
            return
        }
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, device.id)
    }

    var currentOutput: OutputDevice? { outputs.first { $0.id == output } }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshDevices() {
        outputs = AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, as: AudioObjectID.self).compactMap { id in
            guard !id.readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, as: AudioStreamID.self).isEmpty,
                  let uid = id.readString(kAudioDevicePropertyDeviceUID), !uid.hasPrefix(AppTap.uidPrefix), uid != DRIVER_DEVICE_UID,
                  (id.read(kAudioDevicePropertyIsHidden, as: UInt32.self) ?? 0) == 0,
                  let name = id.readString(kAudioObjectPropertyName)
            else { return nil }
            return OutputDevice(id: id, uid: uid, name: name,
                                transport: id.read(kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let current = realOutput(default: AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown)
        if current != output {
            // Not the first output read, at launch: the volume it has then stands.
            if output != .unknown {
                settleUntil = Date().addingTimeInterval(1.5)
                settleTries = 0
            }
            output = current
            Log.mixer.notice("output \(current.readString(kAudioDevicePropertyDeviceUID) ?? "none", privacy: .public)")
            let scope = kAudioObjectPropertyScopeOutput
            deviceListeners = [
                AudioListener(current, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) { [weak self] in self?.refreshMainVolume() },
                AudioListener(current, kAudioDevicePropertyMute, scope: scope) { [weak self] in self?.refreshMainVolume() },
                // Taps are built for one sample rate.
                AudioListener(current, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.rebuildTaps() },
                AudioListener(current, kAudioDevicePropertyPreferredChannelsForStereo, scope: scope) { [weak self] in self?.rebuildTaps() },
            ]
            // The taps depend on whether the new output needs a software volume.
            refreshMainVolume()
            rebuildTaps()
        }
        refreshMainVolume()
    }

    /// What the sound plays on, given macOS's default output: that, or on the
    /// driver, the output behind its device. macOS or anyone else making
    /// another output the default (headphones plugged in) is choosing the real
    /// one, and the device goes back in front of it.
    private func realOutput(default current: AudioObjectID) -> AudioObjectID {
        guard let driver else { return current }
        if driver.device == nil {
            // On the way up: sound still plays on the output it's on.
            let fallback = outputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn } ?? outputs.first
            guard driver.adopt(real: current, fallback: fallback?.id) else { return current }
            driverRetries = 0
            driverDeadline?.cancel()
            driverDeadline = nil
            driverActive = true
            driverStarting = false
            driverProblem = nil
            driver.onVolume = { [weak self] volume, muted in self?.deviceVolumeChanged(volume, muted: muted) }
            return driver.output
        }
        if driver.deviceIsGone {
            driverLost()
            return current
        }
        if current != driver.device, current != .unknown {
            Log.mixer.notice("driver: \(current.readString(kAudioDevicePropertyDeviceUID) ?? "?", privacy: .public) was made the default, so sound goes on to it")
            driver.setOutput(current)
            if let device = driver.device { AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, device) }
        }
        // The output it played on was unplugged, with nothing to tell macOS to
        // move, since the default never changed: the built-in one, or any.
        if !outputs.contains(where: { $0.id == driver.output }),
           let next = outputs.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) ?? outputs.first {
            Log.mixer.notice("driver: the output is gone, so sound goes on to \(next.uid, privacy: .public)")
            driver.setOutput(next.id)
        }
        return driver.output
    }

    private func refreshMainVolume() {
        let scope = kAudioObjectPropertyScopeOutput
        hardwareVolume = output.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        let software = running && !hardwareVolume && currentOutput != nil
        if software != softwareActive {
            softwareActive = software
            Log.mixer.notice("software volume \(software ? "on" : "off", privacy: .public) for \(self.currentOutput?.uid ?? "no output", privacy: .public) (permission \(String(describing: self.permission), privacy: .public))")
        }
        hasMainVolume = hardwareVolume || software
        if software {
            let setting = softwareVolume
            mainVolume = Float(setting.volume)
            mainMuted = setting.muted
        } else {
            mainVolume = readMainVolume()
            mainMuted = (output.read(kAudioDevicePropertyMute, scope: scope, as: UInt32.self) ?? 0) != 0
            followSharedVolume()
        }
        // Every output, so the keys always show the same bar while the mixer is on.
        if ownsSystem { volumeKeys.setWanted(running) }
        driver?.mirror(volume: mainVolume, muted: mainMuted)
    }

    /// macOS's slider or keys moved the driver's device: that's the main volume.
    private func deviceVolumeChanged(_ volume: Float, muted: Bool) {
        if abs(volume - mainVolume) >= 0.001 { setMainVolume(volume) }
        if muted != mainMuted { toggleMainMute() }
    }

    /// With one volume for every output, an output with a volume of its own
    /// is kept at it: just after a switch it's set to it, and after that a
    /// change made elsewhere (Control Center, another app) becomes it.
    private func followSharedVolume() {
        guard running, hardwareVolume, !config.volumePerOutput else { return }
        guard let shared = config.sharedVolume else { return shareVolume(Double(mainVolume), muted: mainMuted) }
        // Devices round the volume to their own steps.
        guard abs(shared.volume - Double(mainVolume)) > 0.01 || shared.muted != mainMuted else { return }
        if Date() < settleUntil, settleTries < 3 {
            settleTries += 1
            let scope = kAudioObjectPropertyScopeOutput
            writeMainVolume(Float(shared.volume))
            output.write(kAudioDevicePropertyMute, scope: scope, UInt32(shared.muted ? 1 : 0))
            mainVolume = readMainVolume()
            mainMuted = (output.read(kAudioDevicePropertyMute, scope: scope, as: UInt32.self) ?? 0) != 0
        } else {
            shareVolume(Double(mainVolume), muted: mainMuted)
        }
    }

    private var setLevel = SetLevel()

    private func writeMainVolume(_ level: Float) {
        let scope = kAudioObjectPropertyScopeOutput
        output.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, Float32(level))
        let read = output.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, as: Float32.self)
        setLevel.wrote(level, on: output, reads: read)
    }

    private func readMainVolume() -> Float {
        let read = output.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput,
                               as: Float32.self) ?? 0
        return setLevel.level(on: output, reading: read)
    }

    // MARK: - Apps and taps

    /// Coalesces the bursts of changes Core Audio sends when an app starts playing.
    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pendingRefresh = false
            self?.refreshApps()
        }
    }

    private func refreshApps() {
        guard running else { return }
        groups = AudioProcesses.groups()
        appsRead = true
        if let onlyApps { groups = groups.filter { onlyApps.contains($0.value.app.bundleIdentifier ?? "") } }
        runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        logProcesses()
        if Self.inputsHeldUp { updateRecording() }

        // Starting and stopping playback doesn't change the process list, so
        // each process is watched too. macOS 27 never announces a change of
        // running output, only of running at all, so both: a playing app went
        // unnoticed until some other change came along, often for many seconds.
        // The input too, where it decides whether a tap runs.
        let objects = Set(groups.values.flatMap(\.objects))
        processListeners = processListeners.filter { objects.contains($0.key) }
        let selectors = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunning] + (Self.inputsHeldUp ? [kAudioProcessPropertyIsRunningInput] : [])
        for object in objects where processListeners[object] == nil {
            processListeners[object] = selectors.map {
                AudioListener(object, $0) { [weak self] in self?.scheduleRefresh() }
            }
        }
        applyTaps()
        updateList()
    }

    /// An app counts as playing while its output runs and, when its tap has
    /// all of it, the tap heard something in the last moment. Many apps keep
    /// their output running in silence, so the running flag alone isn't enough.
    private func currentlyAudible() -> Set<pid_t> {
        let now = Date()
        let recent = { (date: Date?) in now.timeIntervalSince(date ?? .distantPast) < 1.5 }
        return Set(groups.compactMap { pid, group in
            guard group.isPlaying else { return nil }
            guard let bundleID = group.app.bundleIdentifier, measures(group) else { return pid }
            return recent(lastSound[bundleID]) || group.playing.contains { recent(heardAt[$0]) } ? pid : nil
        })
    }

    /// Whether every process of the app that's playing is heard, by its tap or a listener.
    private func measures(_ group: AudioAppGroup) -> Bool {
        // The driver measures every client it has.
        if driverActive { return true }
        let tap = group.app.bundleIdentifier.flatMap { taps[$0] }
        return group.playing.allSatisfy {
            listeners[$0] != nil || tap?.objects.contains($0) == true || (tap != nil && Self.byBundle && group.own.contains($0))
        }
    }

    private func updateLevels() {
        guard running else { return }
        let now = Date()
        if let driver {
            for (pid, peak) in driver.link.takePeaks() where peak > Self.silence {
                if let bundleID = driverBundles[pid] { lastSound[bundleID] = now }
            }
            driver.link.logNewGaps()
            if currentlyAudible() != audible { updateList() }
            return
        }
        var heard: [String: Bool] = [:]
        for (key, tap) in allTaps { heard[key] = tap.takePeak() > Self.silence }
        for (key, loud) in heard where loud && key != Self.masterKey { lastSound[key] = now }
        for (object, listener) in listeners where listener.takePeak() > Self.silence { heardAt[object] = now }
        if currentlyAudible() != audible { updateList() }
        if Self.inputsHeldUp {
            ticksSinceRecordingCheck += 1
            if ticksSinceRecordingCheck >= 4 {
                ticksSinceRecordingCheck = 0
                checkRecording()
            }
        }
        rearmIdle(heard, now)
        // A process waiting for a quiet moment to move has had one.
        let quiet = listeners.keys.contains { !stranded.contains($0) && now.timeIntervalSince(heardAt[$0] ?? now) >= Self.quietFor }
        let leaving = taps.contains { config.ignored[$0.key] != nil && now.timeIntervalSince(lastSound[$0.key] ?? .distantPast) >= Self.quietFor }
        if quiet || leaving { applyTaps() }
    }

    // MARK: - Taps

    /// macOS 26 and later take processes by bundle ID, before they have
    /// played anything: an app with a volume of its own is tapped as it
    /// opens, and its first sound is already at that volume.
    private static var byBundle: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The master's key where taps are keyed by bundle ID.
    private static let masterKey = ""
    /// Below this a buffer counts as silence (-80 dB).
    private static let silence: Float = 0.0001
    /// How long a process has to be silent before it moves between taps.
    private static let quietFor: TimeInterval = 0.5
    /// New taps for apps that can wait, per pass: each takes about 25 ms of the main thread.
    private static let tapsPerPass = 2
    /// How long a tap taken away for a held-up input stays away. A start went
    /// on about 0.1 s after the mixer turned off.
    private static let releaseGap: TimeInterval = 0.3

    private var allTaps: [(String, AppTap)] {
        taps.map { ($0.key, $0.value) } + (masterTap.map { [(Self.masterKey, $0)] } ?? [])
    }

    /// For each tap: its buffer count at the last look, when it last carried
    /// sound (or was idle), and when its apps were last checked.
    private var activity: [String: (callbacks: UInt32, sound: Date, checked: Date)] = [:]

    /// A tap's device keeps running after the sound stops, which keeps the
    /// output running and the Mac from sleeping, as if something still
    /// played. Two seconds into a silence, once nothing it takes still has its
    /// output running, it's put back to waiting. An app that keeps its output
    /// running in silence keeps it up, as it would keep the output up anyway.
    private func rearmIdle(_ heard: [String: Bool], _ now: Date) {
        var clients: [AudioClient]?
        for (key, tap) in allTaps {
            let count = tap.callbacks
            var state = activity[key] ?? (count, now, .distantPast)
            let moving = count != state.callbacks
            state.callbacks = count
            if !moving || heard[key] == true { state.sound = now }
            if moving, now.timeIntervalSince(state.sound) >= 2, now.timeIntervalSince(state.checked) >= 2 {
                state.checked = now
                if clients == nil { clients = AudioProcesses.clients() }
                if !(clients ?? []).contains(where: { $0.isPlaying && takes(key, $0) }) {
                    // In the wrong mode, a pass makes a new one; one running
                    // for an app's input stays up.
                    if tap.autoStart == takesRecording(key) {
                        schedulePass()
                    } else if tap.autoStart {
                        tap.rearm()
                    }
                    state.sound = now
                }
            }
            activity[key] = state
        }
        activity = activity.filter { key, _ in key == Self.masterKey ? masterTap != nil : taps[key] != nil }
    }

    /// Waiting taps hold up an input on macOS 26. Not on macOS 27, which never
    /// showed it with the same built-in microphone, so it pays nothing there.
    private static var inputsHeldUp: Bool {
        #if TOOLKIT_DEV
        if forceInputsHeldUp { return true }
        #endif
        if #available(macOS 27.0, *) { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// One read per app process, about 60 µs each, once a second. The set, not
    /// whether there is one: another app may already be recording.
    private func checkRecording() {
        let now = Set(groups.values.flatMap(\.objects).filter { ($0.read(kAudioProcessPropertyIsRunningInput, as: UInt32.self) ?? 0) != 0 })
        guard now != recording else { return }
        Log.mixer.notice("input check: processes \(now.sorted(), privacy: .public) have their input running, known \(self.recording.sorted(), privacy: .public)")
        scheduleRefresh()
    }

    /// Takes in what's recording now, and says who started and stopped.
    private func updateRecording() {
        let now = Set(groups.values.flatMap(\.recording))
        guard now != recording else { return }
        let date = Date()
        let inputs = AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)?.readString(kAudioDevicePropertyDeviceUID) ?? "none"
        for object in now.subtracting(recording) {
            recordingSince[object] = date
            let used = object.readArray(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput, as: AudioObjectID.self)
                .map { $0.readString(kAudioDevicePropertyDeviceUID) ?? "\($0)" }
            let flags = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput]
                .map { (object.read($0, as: UInt32.self) ?? 9) != 0 ? "1" : "0" }.joined(separator: "/")
            Log.mixer.notice("""
                input started: \(self.describe(object), privacy: .public), running/input/output \(flags, privacy: .public), \
                on \(used, privacy: .public), default input \(inputs, privacy: .public)
                """)
        }
        for object in recording.subtracting(now) {
            let lasted = date.timeIntervalSince(recordingSince.removeValue(forKey: object) ?? date)
            Log.mixer.notice("input stopped after \(String(format: "%.2f", lasted), privacy: .public) s: \(self.describe(object), privacy: .public)")
        }
        recording = now
        logTaps("recording changed")
    }

    private func describe(_ object: AudioObjectID) -> String {
        let bundle = object.readString(kAudioProcessPropertyBundleID) ?? "?"
        return "\(bundle) object \(object) pid \(object.read(kAudioProcessPropertyPID, as: pid_t.self) ?? -1)"
    }

    /// Every tap, for a trace, at each step of an input's start.
    private func logTaps(_ why: String) {
        let lines = allTaps.sorted { $0.0 < $1.0 }.filter { !$0.1.autoStart || $0.1.callbacks > 0 || takesRecording($0.0) }.map(\.1.trace)
        Log.mixer.notice("""
            \(why, privacy: .public): recording \(self.recording.sorted(), privacy: .public), \
            released \(self.releasing.keys.sorted(), privacy: .public), \(self.allTaps.count) taps, of interest: \(lines, privacy: .public)
            """)
    }

    /// What has sound open, and what's playing, each time that changes.
    private func logProcesses() {
        let processes = groups.values.map { "\($0.app.bundleIdentifier ?? "?") \($0.objects.sorted())" }.sorted().joined(separator: ", ")
        if processes != loggedProcesses {
            loggedProcesses = processes
            Log.mixer.notice("apps with sound open: \(processes, privacy: .public)")
        }
        let playing = Set(groups.values.flatMap(\.playing))
        if playing != loggedPlaying {
            loggedPlaying = playing
            Log.mixer.notice("output running: \(playing.sorted().map(self.describe), privacy: .public)")
        }
    }

    /// Says once why a tap that should run or wait is left as it is.
    private func logHold(_ key: String, _ why: String) {
        guard loggedHolds.insert(key + why).inserted else { return }
        Log.mixer.notice("\(key.isEmpty ? "master" : key, privacy: .public) tap left as it is: \(why, privacy: .public)")
    }

    /// Takes a waiting tap away with nothing in its place, which lets an input
    /// it held up go on. The next pass after the gap makes a running one.
    private func release(_ key: String, _ take: () -> Void) {
        let began = Date()
        let until = began.addingTimeInterval(Self.releaseGap)
        releasing[key] = until
        Log.mixer.notice("\(key.isEmpty ? "master" : key, privacy: .public) tap taken away for an input that may be held up")
        take()
        Log.mixer.notice("\(key.isEmpty ? "master" : key, privacy: .public) tap gone in \(Int(Date().timeIntervalSince(began) * 1000)) ms; next one in \(Int(Self.releaseGap * 1000)) ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseGap) { [weak self] in self?.applyTaps() }
    }

    /// Whether a released tap's gap is still on. As it ends, says so, and a
    /// second later what became of the tap made then.
    private func stillReleasing(_ key: String, _ now: Date) -> Bool {
        guard let until = releasing[key] else { return false }
        if now < until { return true }
        releasing[key] = nil
        Log.mixer.notice("\(key.isEmpty ? "master" : key, privacy: .public) tap gap over, recording \(self.recording.sorted(), privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logTaps("a second after the gap") }
        return false
    }

    /// Whether the tap under `key` takes a process whose input runs.
    private func takesRecording(_ key: String) -> Bool {
        guard !recording.isEmpty else { return false }
        let inApp = { [taps, groups] (id: String) -> Set<AudioObjectID> in
            let own = Self.byBundle ? groups.values.filter { $0.app.bundleIdentifier == id }.flatMap(\.own) : []
            return Set(taps[id]?.objects ?? []).union(own)
        }
        if key != Self.masterKey { return !recording.isDisjoint(with: inApp(key)) }
        return !recording.subtracting(taps.keys.flatMap(inApp)).isEmpty
    }

    /// Whether the tap under `key` takes this process's sound.
    private func takes(_ key: String, _ client: AudioClient) -> Bool {
        let inApp: (String) -> Bool = { [taps] id in
            guard let tap = taps[id] else { return false }
            return tap.objects.contains(client.object) || (Self.byBundle && client.bundleID == id)
        }
        if key != Self.masterKey { return inApp(key) }
        let own = Bundle.main.bundleIdentifier
        return client.pid != getpid() && client.bundleID != own && !taps.keys.contains(where: inApp)
    }

    private func updateList() {
        audible = currentlyAudible()
        lastSound = lastSound.filter { key, _ in groups.values.contains { $0.app.bundleIdentifier == key } }
        let now = Date()
        var played = config.played
        var hidden = config.hidden
        for (pid, group) in groups where audible.contains(pid) {
            lastPlayed[pid] = now
            // Only on measured sound: an app that keeps its output running in
            // silence would otherwise count as playing.
            guard measures(group), let bundleID = group.app.bundleIdentifier else { continue }
            if group.app.activationPolicy != .regular { played.insert(bundleID) }
            hidden.remove(bundleID)
        }
        lastPlayed = lastPlayed.filter { groups[$0.key] != nil }
        if played != config.played || hidden != config.hidden {
            // Saves them; the didSet comes back here, which is harmless.
            config.played = played
            config.hidden = hidden
            return
        }

        // Every Dock app with sound open, playing or not. Menu
        // bar apps only once they've played, since many keep audio open and
        // never make a sound. Playing first, then the most recently heard,
        // then the rest by name.
        apps = groups.values.compactMap { group in
            guard let bundleID = group.app.bundleIdentifier, config.ignored[bundleID] == nil else { return nil }
            let listed = audible.contains(group.app.processIdentifier) || config.apps[bundleID] != nil
                || (!config.hidden.contains(bundleID)
                    && (group.app.activationPolicy == .regular || config.played.contains(bundleID)))
            guard listed else { return nil }
            let playing = audible.contains(group.app.processIdentifier)
            return MixerApp(pid: group.app.processIdentifier, bundleID: bundleID,
                            name: group.app.localizedName ?? bundleID, icon: group.app.icon, isPlaying: playing)
        }
        .sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            let (x, y) = (lastPlayed[a.pid] ?? .distantPast, lastPlayed[b.pid] ?? .distantPast)
            if x != y { return x > y }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func scheduleRetry() {
        guard retryAt == nil else { return }
        retryAt = Date().addingTimeInterval(retryDelay)
        retryDelay = min(retryDelay * 2, 300)
    }

    private func retryFailed() {
        guard running, let retryAt, retryAt <= Date() else { return }
        self.retryAt = nil
        failed.removeAll()
        applyTaps()
        // Every tap made this time: the next miss starts the waits over.
        if failed.isEmpty { retryDelay = 2 }
    }

    private func rebuildTaps() {
        // Another output has its own equalizer, and maybe another sample rate.
        pushEqualizer()
        if let driver {
            driver.outputReconfigured()
            applyTaps()
            return
        }
        let pair = output.readArray(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput, as: UInt32.self)
        stereo = pair.count == 2 && pair.allSatisfy({ $0 >= 1 }) && pair[0] != pair[1] ? (Int(pair[0]) - 1, Int(pair[1]) - 1) : (0, 1)
        settling = true
        taps.removeAll()
        masterTap = nil
        listeners.removeAll()
        failed.removeAll()
        releasing = [:]
        applyTaps()
    }

    /// The software volume as a gain, 1 when there is none.
    private var masterGain: Float {
        guard softwareActive, currentOutput != nil else { return 1 }
        return softwareVolume.gain
    }

    /// Everything plays through a tap while the mixer is on: each app with
    /// sound open through its own, everything else through the master. The
    /// taps wait idle until something plays to them.
    ///
    /// Sound moved from one tap to another while it plays clicks unless both
    /// are running, and a new tap is never running yet. So an app's process
    /// only moves while it's quiet, unless its sound would be wrong where it
    /// is: an app with a volume of its own moves at once. Until then, both
    /// ways sound the same. Each change is made in place: the tap that takes
    /// a process first, then the one that lets it go.
    private func applyTaps() {
        if driver != nil { return applyToDriver() }
        if driverRetrying { return }
        guard running, permission == .granted, let device = currentOutput else {
            taps.removeAll()
            masterTap = nil
            listeners.removeAll()
            releasing = [:]
            return
        }
        let master = masterGain
        let now = Date()
        var budget = Self.tapsPerPass

        // What each app's tap should take, and its gain.
        var plan: [String: (objects: [AudioObjectID], gain: Float)] = [:]
        var byApp: [String: AudioAppGroup] = [:]
        for group in groups.values {
            guard let bundleID = group.app.bundleIdentifier else { continue }
            if var merged = byApp[bundleID] {
                // Two copies of one app share its tap.
                merged.objects += group.objects
                merged.playing.formUnion(group.playing)
                merged.own.formUnion(group.own)
                byApp[bundleID] = merged
            } else {
                byApp[bundleID] = group
            }
        }
        if Self.byBundle {
            for (bundleID, setting) in config.apps where runningBundles.contains(bundleID) && byApp[bundleID] == nil {
                plan[bundleID] = ([], setting.gain * master)
            }
        }
        for (bundleID, group) in byApp {
            let ignored = config.ignored[bundleID] != nil
            let setting = config.apps[bundleID] ?? AppVolume(name: "")
            let urgent = !ignored && (!setting.isDefault || settling || releasing[bundleID] != nil)
            let tap = taps[bundleID]
            let quiet: (AudioObjectID) -> Bool = { [listeners, heardAt, lastSound] object in
                guard group.playing.contains(object) else { return true }
                if let tap, tap.objects.contains(object) || (Self.byBundle && group.own.contains(object)) {
                    return now.timeIntervalSince(lastSound[bundleID] ?? .distantPast) >= Self.quietFor
                }
                return listeners[object] != nil && now.timeIntervalSince(heardAt[object] ?? now) >= Self.quietFor
            }
            if tap == nil {
                // A tap by bundle ID takes the app's own processes the moment it's made.
                guard !ignored, urgent || !Self.byBundle || group.own.allSatisfy(quiet) else { continue }
                if !urgent {
                    guard budget > 0 else {
                        schedulePass()
                        continue
                    }
                    budget -= 1
                }
            }
            var objects = (tap?.objects ?? []).filter { group.objects.contains($0) }
            if ignored {
                // Excluded apps play through the master, as everything else does; each process moves once quiet.
                objects = objects.filter { !quiet($0) }
                let held = Self.byBundle && !group.own.allSatisfy(quiet)
                if objects.isEmpty, !held { continue }
            } else {
                for object in group.objects where !objects.contains(object) && (urgent || quiet(object)) { objects.append(object) }
            }
            plan[bundleID] = (objects.sorted(), (ignored ? 1 : setting.gain) * master)
        }
        for bundleID in plan.keys where failed.contains("\(device.uid) \(bundleID)") { plan[bundleID] = nil }
        releasing = releasing.filter { $0.key == Self.masterKey || plan[$0.key] != nil }

        // First the taps that take something on, keeping what they have.
        // One taking a process whose output runs (in silence) starts running
        // itself; it's waited for, so the master lets go of the process
        // between two running taps, which is what doesn't click.
        var starting: [(AppTap, UInt32)] = []
        for (bundleID, want) in plan {
            let group = byApp[bundleID]
            // Whether the app's tap, taking these and its own processes, takes one that records.
            let records = { [recording] (objects: [AudioObjectID]) in
                !recording.isDisjoint(with: Set(objects).union(Self.byBundle ? group?.own ?? [] : []))
            }
            let running = { (tap: AppTap?) in
                want.objects.contains { object in
                    group?.playing.contains(object) == true && tap?.objects.contains(object) != true
                        && !(Self.byBundle && tap != nil && group?.own.contains(object) == true)
                }
            }
            if stillReleasing(bundleID, now) { continue }
            if let tap = taps[bundleID], tap.deviceUID == device.uid {
                tap.gain = want.gain
                let taking = Array(Set(tap.objects).union(want.objects).filter { group?.objects.contains($0) ?? false }).sorted()
                let wakes = running(tap)
                let before = tap.callbacks
                if tap.update(objects: taking, bundleIDs: tap.bundleIDs) {
                    // Swapped for one that runs, or waits, only while nothing of the app plays: then it can't click.
                    let swap = "swap \(device.uid) \(bundleID)"
                    let run = records(taking)
                    if tap.autoStart == run, group?.playing.isEmpty == false {
                        logHold(bundleID, "should \(run ? "run" : "wait"), but its app plays \(group?.playing.sorted() ?? [])")
                    }
                    if tap.autoStart == run, group?.playing.isEmpty != false, !failed.contains(swap) {
                        loggedHolds = loggedHolds.filter { !$0.hasPrefix(bundleID) }
                        if run {
                            release(bundleID) { taps[bundleID] = nil }
                            continue
                        }
                        Log.mixer.notice("\(bundleID, privacy: .public) tap waits for sound again: its input has stopped")
                        if let fresh = AppTap(objects: taking, deviceUID: device.uid, gain: want.gain, autoStart: !run,
                                              bundleIDs: tap.bundleIDs, stereo: stereo, equalizer: equalizerState) {
                            taps[bundleID] = fresh
                        } else {
                            Log.mixer.error("\(bundleID, privacy: .public) tap could not be swapped; the old one stays")
                            failed.insert(swap)
                            scheduleRetry()
                        }
                    } else if wakes {
                        starting.append((tap, before))
                    }
                    continue
                }
            }
            // Made before any old one is let go, so the app is never left unmuted.
            if let tap = AppTap(objects: want.objects, deviceUID: device.uid, gain: want.gain, autoStart: !records(want.objects),
                                bundleIDs: Self.byBundle ? [bundleID] : [], stereo: stereo, equalizer: equalizerState) {
                taps[bundleID] = tap
                if running(nil) || (Self.byBundle && group?.own.contains { group?.playing.contains($0) == true } == true) {
                    starting.append((tap, 0))
                }
            } else {
                taps[bundleID] = nil
                plan[bundleID] = nil
                failed.insert("\(device.uid) \(bundleID)")
                scheduleRetry()
            }
        }

        // At the start the output is read before the apps are.
        if appsRead { settling = false }

        // A tap's device takes a few buffers to start.
        let deadline = Date().addingTimeInterval(0.15)
        while starting.contains(where: { $0.0.callbacks < $0.1 &+ 2 }), Date() < deadline { usleep(2000) }

        // Then the master, which leaves out what the app taps have.
        // The master takes the recording processes no app's tap has.
        var inApps = Set(plan.values.flatMap(\.objects))
        if Self.byBundle { for bundleID in plan.keys { inApps.formUnion(byApp[bundleID]?.own ?? []) } }
        applyMasterTap(device: device, plan: plan, gain: master, run: !recording.subtracting(inApps).isEmpty, now: now)

        // Then the taps that let something go, or are no longer wanted.
        for (bundleID, tap) in taps {
            guard let want = plan[bundleID] else {
                taps[bundleID] = nil
                continue
            }
            if !tap.update(objects: want.objects, bundleIDs: tap.bundleIDs) {
                taps[bundleID] = AppTap(objects: want.objects, deviceUID: device.uid, gain: want.gain, autoStart: tap.autoStart,
                                        bundleIDs: tap.bundleIDs, stereo: stereo, equalizer: equalizerState)
            }
        }

        // Listeners for what's playing through the master and waiting to move.
        var waiting: Set<AudioObjectID> = []
        for (bundleID, group) in byApp where config.ignored[bundleID] == nil {
            var held = Set(plan[bundleID]?.objects ?? [])
            if Self.byBundle, taps[bundleID] != nil { held.formUnion(group.own) }
            waiting.formUnion(group.playing.subtracting(held))
        }
        for object in waiting where listeners[object] == nil && !failed.contains("listen \(object)") {
            if let listener = AppTap(objects: [object], deviceUID: device.uid, gain: 1, controlsVolume: false) {
                listeners[object] = listener
                heardAt[object] = now
            } else {
                failed.insert("listen \(object)")
            }
        }
        listeners = listeners.filter { waiting.contains($0.key) }
        heardAt = heardAt.filter { listeners[$0.key] != nil }
        stranded = Set(byApp.filter { plan[$0.key] == nil && failed.contains("\(device.uid) \($0.key)") }.values.flatMap(\.objects))
    }

    // MARK: - The driver

    private func startDriver() {
        driverInstall = DriverInstall.status
        guard ownsSystem, config.usesDriver else {
            driverProblem = nil
            return
        }
        switch driverInstall {
        case .current: break
        case .missing:
            driverProblem = .notInstalled
            Log.mixer.notice("driver: asked for, but it isn't installed: on taps")
            return
        case .unavailable:
            driverProblem = .notInstalled
            Log.mixer.error("driver: asked for, but this build of the app has none: on taps")
            return
        case .outdated:
            driverProblem = .outdated
            Log.mixer.notice("driver: asked for, but the installed one is another version: on taps")
            return
        }
        do {
            driver = try MixerDriver(equalizer: equalizerState)
            driverStarting = true
            // Its device shows in a moment, which the device list's listener hears.
            let deadline = DispatchWorkItem { [weak self] in self?.driverNeverShowed() }
            driverDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deadline)
        } catch {
            Log.mixer.error("driver: no link: \(String(describing: error), privacy: .public): on taps")
            // It reads the app from disk, which it can't anywhere under a home folder.
            driverProblem = Bundle.main.bundlePath.hasPrefix("/Applications/") ? .refused : .notInApplications
        }
    }

    /// Its device went while the toolkit is here: coreaudiod restarted, or the
    /// heartbeat came too late. macOS has moved sound to a real output, so
    /// nothing is silent: back on the driver if it's there again in a moment,
    /// and otherwise on taps.
    private func driverLost() {
        Log.mixer.error("driver: its device went: try \(self.driverRetries + 1, privacy: .public) of 3 to get it back")
        stopDriver()
        driverRetrying = true
        driverRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, running, driverRetrying else { return }
            driverRetrying = false
            if driverRetries <= 3 { startDriver() }
            if driver == nil {
                if driverRetries <= 3 { driverProblem = .noDevice }
                rebuildTaps()
            }
            refreshDevices()
        }
    }

    private func driverNeverShowed() {
        Log.mixer.error("driver: its device never showed: on taps")
        driverProblem = .noDevice
        stopDriver()
        rebuildTaps()
    }

    private func stopDriver() {
        driverDeadline?.cancel()
        driverDeadline = nil
        driver?.close()
        driver = nil
        driverActive = false
        driverStarting = false
        driverBundles = [:]
    }

    /// Each process at its app's volume, and the main volume where the output
    /// has none of its own. The driver glides to them, so nothing here has to
    /// wait for a quiet moment as taps do.
    private func applyToDriver() {
        guard running, let driver else { return }
        driver.link.gain = masterGain
        var gains: [pid_t: Float] = [:]
        var bundles: [pid_t: String] = [:]
        for group in groups.values {
            guard let bundleID = group.app.bundleIdentifier else { continue }
            let setting = config.ignored[bundleID] == nil ? config.apps[bundleID] : nil
            for object in group.objects {
                guard let pid = object.read(kAudioProcessPropertyPID, as: pid_t.self) else { continue }
                bundles[pid] = bundleID
                if let setting, !setting.isDefault { gains[pid] = setting.gain }
            }
        }
        driverBundles = bundles
        driver.link.setGains(gains)
    }

    /// The preview's switch. Turning it on installs the driver first if it has
    /// to, which asks for a password. Off a moment for a coreaudiod restart.
    func setUsesDriver(_ on: Bool) {
        guard !driverBusy else { return }
        driverInstall = DriverInstall.status
        driverProblem = nil
        guard on, driverInstall != .current else {
            config.usesDriver = on
            return
        }
        driverWork = .installing
        let wasRunning = running
        stop()
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = DriverInstall.run(install: true)
            DispatchQueue.main.async { [self] in
                driverInstall = DriverInstall.status
                guard installed else {
                    driverWork = nil
                    driverProblem = .installFailed
                    if wasRunning { start() }
                    return
                }
                whenDriverLoaded { [self] in
                    driverWork = nil
                    config.usesDriver = true
                    // No change of setting if it was already set, for an update.
                    if wasRunning, !running { start() }
                }
            }
        }
    }

    /// Takes the driver off this Mac.
    func removeDriver() {
        guard !driverBusy else { return }
        driverWork = .removing
        let wasRunning = running
        stop()
        DispatchQueue.global(qos: .userInitiated).async {
            let removed = DriverInstall.run(install: false)
            DispatchQueue.main.async { [self] in
                driverWork = nil
                driverInstall = DriverInstall.status
                if !removed { Log.mixer.error("driver: not removed") }
                if wasRunning { start() }
            }
        }
    }

    /// coreaudiod has restarted, and takes a moment to load its drivers.
    private func whenDriverLoaded(tries: Int = 40, _ then: @escaping () -> Void) {
        if DriverLink.plugIn != nil || tries <= 0 { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.whenDriverLoaded(tries: tries - 1, then)
        }
    }

    /// Another pass soon, for the taps this one left for later.
    private func schedulePass() {
        guard !passPending else { return }
        passPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.passPending = false
            self?.applyTaps()
        }
    }

    /// Everything without a tap of its own goes through one tap that applies
    /// the software volume and the equalizer. It's always up while the mixer
    /// is, passing the sound through untouched when there's nothing to do:
    /// putting it up or taking it down while something plays clicks.
    private func applyMasterTap(device: OutputDevice, plan: [String: (objects: [AudioObjectID], gain: Float)], gain: Float, run: Bool, now: Date) {
        if stillReleasing(Self.masterKey, now) { return }
        // Ours too, or the tap would hear its own output. Our process only has
        // a Core Audio object once it has used audio, so on macOS 26 and later
        // it is also left out by bundle ID, which needs no such object.
        let own = AudioProcesses.processObject(of: ProcessInfo.processInfo.processIdentifier)
        var bundleIDs: [String] = []
        if Self.byBundle, let id = Bundle.main.bundleIdentifier { bundleIDs = [id] + plan.keys.sorted() }
        guard own != nil || !bundleIDs.isEmpty else {
            if !loggedMasterSkip { Log.mixer.notice("software volume needs macOS 26 or later to leave its own audio out of the tap") }
            loggedMasterSkip = true
            masterTap = nil
            return
        }
        let excluded = Array(Set((own.map { [$0] } ?? []) + plan.values.flatMap(\.objects))).sorted()
        let signature = "master \(device.uid)"
        if let tap = masterTap, tap.deviceUID == device.uid {
            tap.gain = gain
            if tap.update(objects: excluded, bundleIDs: bundleIDs) {
                // As an app's tap: another mode only while nothing it takes plays.
                let swap = "swap \(signature)"
                guard tap.autoStart == run, !failed.contains(swap) else { return }
                let playing = AudioProcesses.clients().filter { $0.isPlaying && takes(Self.masterKey, $0) }
                guard playing.isEmpty else {
                    logHold(Self.masterKey, "should \(run ? "run" : "wait"), but it takes \(playing.map(\.object).sorted()), playing")
                    return
                }
                loggedHolds = loggedHolds.filter { !$0.hasPrefix("should") }
                if run {
                    release(Self.masterKey) { masterTap = nil }
                    return
                }
                Log.mixer.notice("master tap waits for sound again: its input has stopped")
                if let fresh = AppTap(objects: excluded, deviceUID: device.uid, gain: gain, isGlobal: true, autoStart: !run,
                                      bundleIDs: bundleIDs, stereo: stereo, equalizer: equalizerState) {
                    masterTap = fresh
                } else {
                    Log.mixer.error("master tap could not be swapped; the old one stays")
                    failed.insert(swap)
                    scheduleRetry()
                }
                return
            }
        }
        guard !failed.contains(signature) else { return }
        // The new tap is up before the old one goes, so nothing plays unmuted in between.
        if let tap = AppTap(objects: excluded, deviceUID: device.uid, gain: gain, isGlobal: true, autoStart: !run,
                            bundleIDs: bundleIDs, stereo: stereo, equalizer: equalizerState) {
            masterTap = tap
        } else {
            masterTap = nil
            failed.insert(signature)
            scheduleRetry()
        }
    }

    private func scheduleSave() {
        guard persists else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.config.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

extension MixerController {
    /// Prints the apps the mixer would list, for `--list-audio`.
    static func dumpApps() {
        for group in AudioProcesses.groups().values.sorted(by: { $0.app.processIdentifier < $1.app.processIdentifier }) {
            let pids = group.objects.compactMap { $0.read(kAudioProcessPropertyPID, as: pid_t.self) }
            let kind = group.app.activationPolicy == .regular ? "" : " [menu bar: listed once it plays]"
            print("\(group.isPlaying ? "▶" : " ") \(group.app.localizedName ?? "?") (\(group.app.bundleIdentifier ?? "?")) processes \(pids)\(kind)")
        }
        print("permission: \(AudioPermission.status)")
    }

    /// Made-up rows for `--snapshot`, without touching Core Audio or the saved settings.
    /// For `--snapshot mixer driver=<state>`: the driver's line in that state.
    static var previewDriver: String?

    static func preview(software: Bool = false, equalizer: Bool = false, perOutput: Bool = false, simple: Bool = false,
                        menuBarIcon: MixerMenuBarIcon? = nil) -> MixerController {
        let mixer = MixerController()
        mixer.persists = false
        // Defaults, not this Mac's settings: its excluded apps and volumes
        // aren't for a picture.
        mixer.config = MixerConfig()
        if let state = previewDriver {
            mixer.config.usesDriver = state != "failed-install"
            switch state {
            case "installing": mixer.driverWork = .installing
            case "removing": mixer.driverWork = .removing
            case "starting": mixer.driverStarting = true
            case "on": mixer.driverActive = true
            case "outdated":
                mixer.driverInstall = .outdated
                mixer.driverProblem = .outdated
            case "failed-install": mixer.driverProblem = .installFailed
            default: mixer.driverProblem = .noDevice
            }
        }
        func icon(_ bundleID: String) -> NSImage? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        mixer.apps = [
            MixerApp(pid: 1, bundleID: "com.apple.Music", name: "Music", icon: icon("com.apple.Music"), isPlaying: true),
            MixerApp(pid: 2, bundleID: "com.apple.Safari", name: "Safari", icon: icon("com.apple.Safari"), isPlaying: true),
            MixerApp(pid: 3, bundleID: "com.apple.FaceTime", name: "FaceTime", icon: icon("com.apple.FaceTime"), isPlaying: false),
            MixerApp(pid: 4, bundleID: "com.apple.podcasts", name: "Podcasts", icon: icon("com.apple.podcasts"), isPlaying: false),
            MixerApp(pid: 5, bundleID: "com.apple.QuickTimePlayerX", name: "QuickTime Player", icon: icon("com.apple.QuickTimePlayerX"), isPlaying: false),
        ]
        mixer.config.apps = [
            "com.apple.Safari": AppVolume(name: "Safari", volume: 0.45),
            "com.apple.podcasts": AppVolume(name: "Podcasts", volume: 0.8, muted: true),
        ]
        if equalizer {
            mixer.config.equalizer.enabled = true
            mixer.config.equalizer.gains = EqualizerPreset.loudness.gains
        }
        mixer.config.equalizerPerOutput = perOutput
        if simple { mixer.config.equalizerMode = .simple }
        mixer.outputs = [
            OutputDevice(id: 1, uid: "a", name: "MacBook Pro Speakers"),
            OutputDevice(id: 2, uid: "b", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
            OutputDevice(id: 3, uid: "c", name: "LG UltraFine", transport: kAudioDeviceTransportTypeDisplayPort),
        ]
        mixer.output = 1
        // Before the volume, which a change to the settings reads again.
        if let menuBarIcon { mixer.config.menuBarIcon = menuBarIcon }
        mixer.mainVolume = 0.62
        mixer.hasMainVolume = true
        mixer.softwareActive = software
        mixer.permission = .granted
        return mixer
    }
}

#if TOOLKIT_DEV
extension MixerController {
    /// For `--test-mixer-engine`: a mixer that runs for real, beside the
    /// installed app, with made-up settings and taps for these apps only.
    static func testInstance(apps: Set<String>) -> MixerController {
        let mixer = MixerController()
        mixer.persists = false
        mixer.ownsSystem = false
        mixer.onlyApps = apps
        mixer.config = MixerConfig()
        return mixer
    }

    /// Treats this Mac as one whose inputs waiting taps hold up, to run that path where they don't.
    static var forceInputsHeldUp = false

    /// What goes through which tap, for the test's report.
    var engineState: String {
        let mode = { (tap: AppTap?) in tap?.autoStart == false ? " (running)" : "" }
        let apps = taps.keys.sorted().map { "\($0) \(taps[$0]?.objects ?? [])\(mode(taps[$0]))" }.joined(separator: ", ")
        let master = masterTap.map { "master leaves out \($0.objects) \($0.bundleIDs)\(mode($0))" } ?? "no master"
        return "taps: [\(apps)]; listening to \(listeners.keys.sorted()); \(master)\(recording.isEmpty ? "" : "; recording \(recording.sorted())")\(releasing.isEmpty ? "" : "; released \(releasing.keys.sorted())")"
    }
}
#endif

