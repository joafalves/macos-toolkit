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
            } else if config.ignored != oldValue.ignored || config.played != oldValue.played || config.hidden != oldValue.hidden {
                refreshApps()
            } else {
                applyTaps()
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
    @Published private(set) var permission = AudioPermission.status

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
    /// Taps macOS refused, so they're not retried on every slider move.
    private var failed: Set<String> = []

    private var systemListeners: [AudioListener] = []
    private var deviceListeners: [AudioListener] = []
    private var processListeners: [AudioObjectID: AudioListener] = [:]
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var pendingRefresh = false
    private var saveWork: DispatchWorkItem?

    init() {
        config = MixerConfig.load()
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
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refreshPermission() }
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

    func setVolume(_ volume: Double, of app: MixerApp) {
        update(app) { $0.volume = volume >= 0.995 ? 1 : max(0, volume) }
    }

    func toggleMute(_ app: MixerApp) {
        update(app) { $0.muted.toggle() }
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
        if permission == .denied { return AudioPermission.openSettings() }
        AudioPermission.request { [weak self] _ in self?.refreshPermission() }
    }

    func refreshPermission() {
        let status = AudioPermission.status
        guard status != permission else { return }
        permission = status
        failed.removeAll()
        applyTaps()
    }

    // MARK: - Main volume and output

    func setMainVolume(_ volume: Float) {
        output.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, Float32(volume))
        // Like the volume keys: changing the volume unmutes.
        if mainMuted { output.write(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, UInt32(0)) }
        refreshMainVolume()
    }

    func toggleMainMute() {
        output.write(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, UInt32(mainMuted ? 0 : 1))
        refreshMainVolume()
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
            rebuildTaps()
        }
        refreshMainVolume()
    }

    private func refreshMainVolume() {
        let scope = kAudioObjectPropertyScopeOutput
        hasMainVolume = output.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        mainVolume = output.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, as: Float32.self) ?? 0
        mainMuted = (output.read(kAudioDevicePropertyMute, scope: scope, as: UInt32.self) ?? 0) != 0
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
        // each process is watched too.
        let objects = Set(groups.values.flatMap(\.objects))
        processListeners = processListeners.filter { objects.contains($0.key) }
        for object in objects where processListeners[object] == nil {
            processListeners[object] = AudioListener(object, kAudioProcessPropertyIsRunningOutput) { [weak self] in self?.scheduleRefresh() }
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
    }

    private func updateList() {
        audible = currentlyAudible()
        lastSound = lastSound.filter { groups[$0.key] != nil }
        let now = Date()
        var played = config.played
        var hidden = config.hidden
        for (pid, group) in groups where audible.contains(pid) {
            lastPlayed[pid] = now
            guard let bundleID = group.app.bundleIdentifier else { continue }
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

        // Like Windows: every Dock app with sound open, playing or not. Menu
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

    private func rebuildTaps() {
        taps.removeAll()
        failed.removeAll()
        applyTaps()
    }

    private func applyTaps() {
        guard running, permission == .granted, let device = outputs.first(where: { $0.id == output }) else {
            taps.removeAll()
            return
        }
        var wanted: Set<pid_t> = []
        for (pid, group) in groups {
            guard let bundleID = group.app.bundleIdentifier, config.ignored[bundleID] == nil else { continue }
            // Apps with their own volume get a tap that plays them; apps whose
            // output is running get one that only listens, to see if they're
            // really making sound.
            let setting = config.apps[bundleID] ?? AppVolume(name: "")
            let controlsVolume = !setting.isDefault
            guard controlsVolume || group.isPlaying else { continue }
            wanted.insert(pid)
            let objects = group.objects.sorted()
            if let tap = taps[pid], tap.deviceUID == device.uid, tap.objects == objects, tap.controlsVolume == controlsVolume {
                tap.gain = setting.gain
                continue
            }
            let signature = "\(device.uid) \(objects) \(controlsVolume)"
            taps[pid] = nil
            guard !failed.contains(signature) else { continue }
            if let tap = AppTap(objects: objects, deviceUID: device.uid, gain: setting.gain, controlsVolume: controlsVolume) {
                taps[pid] = tap
            } else {
                failed.insert(signature)
            }
        }
        for pid in taps.keys where !wanted.contains(pid) { taps[pid] = nil }
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
    static func preview() -> MixerController {
        let mixer = MixerController()
        mixer.persists = false
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
        mixer.outputs = [
            OutputDevice(id: 1, uid: "a", name: "MacBook Pro Speakers"),
            OutputDevice(id: 2, uid: "b", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
            OutputDevice(id: 3, uid: "c", name: "LG UltraFine", transport: kAudioDeviceTransportTypeDisplayPort),
        ]
        mixer.output = 1
        mixer.mainVolume = 0.62
        mixer.hasMainVolume = true
        mixer.permission = .granted
        return mixer
    }
}
