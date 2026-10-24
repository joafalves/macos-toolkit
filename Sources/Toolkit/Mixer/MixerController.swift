import AppKit
import AudioToolbox
import CoreAudio

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

/// Volume per app, on top of the main volume. Only apps set below 100% or
/// muted are tapped; everything else plays exactly as it would without us.
final class MixerController: ObservableObject {
    @Published var config: MixerConfig {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
            if config.enabled != oldValue.enabled {
                config.enabled ? start() : stop()
            } else {
                equalizerState.set(config.equalizer)
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

    /// While the panel is on screen, apps whose output is running get a tap
    /// that only listens, so the playing bars show real sound. Taps make macOS
    /// show its purple recording indicator, so they don't run otherwise.
    var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            applyTaps()
            updateList()
        }
    }

    private var running = false
    private var persists = true
    private var groups: [pid_t: AudioAppGroup] = [:]
    /// When each app last played, so recently heard apps sort above idle ones.
    private var lastPlayed: [pid_t: Date] = [:]
    /// When each tapped app last made an actual sound.
    private var lastSound: [pid_t: Date] = [:]
    /// Apps making sound right now, as last shown.
    private var audible: Set<pid_t> = []
    private var levelTimer: Timer?
    private var taps: [pid_t: AppTap] = [:]
    /// Plays everything else at the software volume, on outputs without a volume of their own.
    private var masterTap: AppTap?
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

    init() {
        config = MixerConfig.load()
        equalizerState.set(config.equalizer)
    }

    // MARK: - Lifecycle

    func start() {
        guard config.enabled, !running else { return }
        running = true
        AppTap.removeLeftovers()

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
        taps.removeAll()
        masterTap = nil
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
        if !setting.isDefault, permission == .unknown { requestPermission() }
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
        output.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, Float32(volume))
        // Like the volume keys: changing the volume unmutes.
        if mainMuted { output.write(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, UInt32(0)) }
        refreshMainVolume()
    }

    func toggleMainMute() {
        if softwareActive { return updateSoftware { $0.muted.toggle() } }
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
        var setting = config.software[uid] ?? SoftwareVolume()
        change(&setting)
        config.software[uid] = setting.isDefault ? nil : setting
        if !setting.isDefault, permission == .unknown { requestPermission() }
    }

    /// Whether anything is waiting on the audio permission.
    var needsAudioPermission: Bool {
        hasCustomVolumes || config.equalizer.isActive || (softwareActive && !(config.software[currentOutput?.uid ?? ""]?.isDefault ?? true))
    }

    // MARK: - Equalizer

    func setEqualizerEnabled(_ enabled: Bool) {
        config.equalizer.enabled = enabled
        if config.equalizer.isActive, permission == .unknown { requestPermission() }
    }

    func setBand(_ band: Int, gain: Double) {
        let range = EqualizerConfig.range
        config.equalizer.gains[band] = min(range, max(-range, (gain * 2).rounded() / 2))
        config.equalizer.enabled = true
        if config.equalizer.isActive, permission == .unknown { requestPermission() }
    }

    func applyPreset(_ preset: EqualizerPreset) {
        config.equalizer.gains = preset.gains
        config.equalizer.enabled = true
        if config.equalizer.isActive, permission == .unknown { requestPermission() }
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
                  let uid = id.readString(kAudioDevicePropertyDeviceUID), !uid.hasPrefix(AppTap.uidPrefix),
                  (id.read(kAudioDevicePropertyIsHidden, as: UInt32.self) ?? 0) == 0,
                  let name = id.readString(kAudioObjectPropertyName)
            else { return nil }
            return OutputDevice(id: id, uid: uid, name: name,
                                transport: id.read(kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let current = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        if current != output {
            output = current
            let scope = kAudioObjectPropertyScopeOutput
            deviceListeners = [
                AudioListener(current, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) { [weak self] in self?.refreshMainVolume() },
                AudioListener(current, kAudioDevicePropertyMute, scope: scope) { [weak self] in self?.refreshMainVolume() },
                // Taps are built for one sample rate.
                AudioListener(current, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.rebuildTaps() },
            ]
            // The taps depend on whether the new output needs a software volume.
            refreshMainVolume()
            rebuildTaps()
        }
        refreshMainVolume()
    }

    private func refreshMainVolume() {
        let scope = kAudioObjectPropertyScopeOutput
        hardwareVolume = output.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        let software = running && config.softwareVolume && !hardwareVolume && currentOutput != nil
        if software != softwareActive {
            softwareActive = software
            NSLog("Toolkit: mixer software volume \(software ? "on" : "off") for \(currentOutput?.name ?? "no output") (permission \(permission))")
        }
        hasMainVolume = hardwareVolume || software
        if software {
            let setting = config.software[currentOutput?.uid ?? ""] ?? SoftwareVolume()
            mainVolume = Float(setting.volume)
            mainMuted = setting.muted
        } else {
            mainVolume = output.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, as: Float32.self) ?? 0
            mainMuted = (output.read(kAudioDevicePropertyMute, scope: scope, as: UInt32.self) ?? 0) != 0
        }
        // Every output, so the keys always show the same bar while the mixer is on.
        volumeKeys.setWanted(running)
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

        // Starting and stopping playback doesn't change the process list, so
        // each process is watched too. macOS 27 never announces a change of
        // running output, only of running at all, so both: a playing app went
        // unnoticed until some other change came along, often for many seconds.
        let objects = Set(groups.values.flatMap(\.objects))
        processListeners = processListeners.filter { objects.contains($0.key) }
        for object in objects where processListeners[object] == nil {
            processListeners[object] = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunning].map {
                AudioListener(object, $0) { [weak self] in self?.scheduleRefresh() }
            }
        }
        applyTaps()
        updateList()
    }

    /// An app counts as playing while its output runs and, when it's tapped,
    /// the tap heard something in the last moment. Many apps keep their output
    /// running in silence, so the running flag alone isn't enough.
    private func currentlyAudible() -> Set<pid_t> {
        let now = Date()
        return Set(groups.compactMap { pid, group in
            guard group.isPlaying else { return nil }
            guard taps[pid] != nil else { return pid }
            return now.timeIntervalSince(lastSound[pid] ?? .distantPast) < 1.5 ? pid : nil
        })
    }

    private func updateLevels() {
        guard running, !taps.isEmpty else { return }
        let now = Date()
        for (pid, tap) in taps where tap.takePeak() > 0.001 { lastSound[pid] = now }
        if currentlyAudible() != audible { updateList() }
        // A tap kept on only to avoid a click can go once its sound has stopped.
        if lingering(now) { applyTaps() }
    }

    /// How long a tap that is no longer needed stays up after its last sound.
    /// Taking it down mid-playback reroutes the audio and clicks; in silence
    /// nobody hears it.
    private static let quietBeforeRelease: TimeInterval = 3

    private func isQuiet(since last: Date?, _ now: Date = Date()) -> Bool {
        now.timeIntervalSince(last ?? .distantPast) >= Self.quietBeforeRelease
    }

    /// Whether a tap kept on only to avoid a click has gone quiet, so it can go.
    private func lingering(_ now: Date) -> Bool {
        for (pid, tap) in taps where tap.controlsVolume {
            let bundleID = groups[pid]?.app.bundleIdentifier ?? ""
            if (config.apps[bundleID]?.isDefault ?? true), isQuiet(since: lastSound[pid], now) { return true }
        }
        return false
    }

    private func updateList() {
        audible = currentlyAudible()
        lastSound = lastSound.filter { groups[$0.key] != nil }
        let now = Date()
        var played = config.played
        var hidden = config.hidden
        for (pid, group) in groups where audible.contains(pid) {
            lastPlayed[pid] = now
            // Only on measured sound: with the panel closed, an app that keeps
            // its output running in silence would otherwise count as playing.
            guard taps[pid] != nil, let bundleID = group.app.bundleIdentifier else { continue }
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
        taps.removeAll()
        masterTap = nil
        failed.removeAll()
        applyTaps()
    }

    /// The software volume as a gain, 1 when there is none.
    private var masterGain: Float {
        guard softwareActive, let uid = currentOutput?.uid else { return 1 }
        return (config.software[uid] ?? SoftwareVolume()).gain
    }

    private func applyTaps() {
        guard running, permission == .granted, let device = currentOutput else {
            taps.removeAll()
            masterTap = nil
            return
        }
        let master = masterGain
        var wanted: Set<pid_t> = []
        /// What the app taps play themselves, so the master tap has to leave it alone.
        var controlled: [AudioObjectID] = []
        for (pid, group) in groups {
            guard let bundleID = group.app.bundleIdentifier, config.ignored[bundleID] == nil else { continue }
            // Apps with their own volume get a tap that plays them; apps whose
            // output is running get one that only listens, to see if they're
            // really making sound.
            let setting = config.apps[bundleID] ?? AppVolume(name: "")
            // An app put back to 100% keeps its tap, passing the sound through,
            // until it goes quiet: removing it mid-playback would click.
            let lingers = setting.isDefault && taps[pid]?.controlsVolume == true && !isQuiet(since: lastSound[pid])
            let controlsVolume = !setting.isDefault || lingers
            guard controlsVolume || (panelOpen && group.isPlaying) else { continue }
            wanted.insert(pid)
            let objects = group.objects.sorted()
            // These bypass the master tap, so the software volume is applied here.
            let gain = setting.gain * master
            if let tap = taps[pid], tap.deviceUID == device.uid, tap.objects == objects, tap.controlsVolume == controlsVolume {
                tap.gain = gain
                if controlsVolume { controlled += objects }
                continue
            }
            let signature = "\(device.uid) \(objects) \(controlsVolume)"
            guard !failed.contains(signature) else {
                taps[pid] = nil
                continue
            }
            // Made before the old one is let go, so the app is never left unmuted.
            if let tap = AppTap(objects: objects, deviceUID: device.uid, gain: gain, controlsVolume: controlsVolume,
                                equalizer: controlsVolume ? equalizerState : nil) {
                taps[pid] = tap
                if controlsVolume { controlled += objects }
            } else {
                taps[pid] = nil
                failed.insert(signature)
                scheduleRetry()
            }
        }
        // Before the taps that are no longer wanted go: an app they hand back
        // would otherwise play at full volume until the master tap picks it up.
        applyMasterTap(device: device, controlled: controlled, gain: master)
        for pid in taps.keys where !wanted.contains(pid) { taps[pid] = nil }
    }

    /// Everything not played by an app tap goes through one tap that applies
    /// the software volume. It stays up at 100% too, where it passes the sound
    /// through untouched: taking it down there would reroute the audio in the
    /// middle of playback, which clicks every time the volume crosses 100%.
    /// The equalizer needs it too, on any output: everything has to pass
    /// through the toolkit to be equalized.
    private func applyMasterTap(device: OutputDevice, controlled: [AudioObjectID], gain: Float) {
        // Unlike an app's, it goes as soon as the equalizer does, with a small
        // pop like the one when it starts: waiting for a silence kept it, and
        // macOS's recording dot, up for as long as music played.
        guard softwareActive || config.equalizer.isActive else {
            masterTap = nil
            return
        }
        // Ours too, or the tap would hear its own output. Our process only has
        // a Core Audio object once it has used audio, so on macOS 26 and later
        // it is also left out by bundle ID, which needs no such object.
        let own = AudioProcesses.processObject(of: ProcessInfo.processInfo.processIdentifier)
        var bundleIDs: [String] = []
        if #available(macOS 26.0, *), let id = Bundle.main.bundleIdentifier { bundleIDs = [id] }
        guard own != nil || !bundleIDs.isEmpty else {
            if !loggedMasterSkip { NSLog("Toolkit: mixer software volume needs macOS 26 or later to leave its own audio out of the tap") }
            loggedMasterSkip = true
            masterTap = nil
            return
        }
        let excluded = (Array(own.map { [$0] } ?? []) + controlled).sorted()
        if let tap = masterTap, tap.isGlobal, tap.deviceUID == device.uid, tap.objects == excluded {
            tap.gain = gain
            return
        }
        let signature = "master \(device.uid) \(excluded)"
        guard !failed.contains(signature) else { return }
        // The new tap is up before the old one goes, so nothing plays unmuted in between.
        if let tap = AppTap(objects: excluded, deviceUID: device.uid, gain: gain, isGlobal: true,
                            excludedBundleIDs: bundleIDs, equalizer: equalizerState) {
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
    static func preview(software: Bool = false, equalizer: Bool = false, menuBarIcon: MixerMenuBarIcon? = nil) -> MixerController {
        let mixer = MixerController()
        mixer.persists = false
        // Defaults, not this Mac's settings: its excluded apps and volumes
        // aren't for a picture.
        mixer.config = MixerConfig()
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
