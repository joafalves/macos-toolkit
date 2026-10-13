import AppKit
import ApplicationServices
import ServiceManagement

/// A row in the device list: a connected mouse, or a saved profile whose
/// mouse is currently away.
struct MouseDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var transport: String
    var connected: Bool
}

final class AppState: ObservableObject {
    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            config.save()
            refresh(force: true)
        }
    }

    @Published private(set) var devices: [MouseDevice] = []
    /// Sidebar selection of the settings window: a device id, or "general".
    @Published var selection: String?
    @Published private(set) var accessibilityGranted = false
    /// Accessibility is granted but macOS still refused the event tap; this
    /// happens when the grant predates the running process.
    @Published private(set) var wheelTapFailed = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let monitor = ActivityMonitor()
    private let wheel = WheelEngine()
    private var services: [PointerService] = []
    /// Values Tiller has written this session, by "registryID/key".
    private var written: [String: Int32] = [:]
    private var timer: Timer?

    init() {
        config = Config.load()
        wheel.profileProvider = { [weak self] in self?.wheelProfile() }
        monitor.onDevicesChanged = { [weak self] in
            // The event service appears slightly after the device itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh(force: false) }
        }
        refresh(force: false)

        // macOS re-pushes its global values now and then (wake, reconnect,
        // System Settings changes), so keep re-asserting ours.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh(force: false) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Devices

    /// Rescans connected mice and applies their profiles. With `force`,
    /// settings left on "macOS" are actively put back to the system value.
    func refresh(force: Bool) {
        services = HID.pointerServices().filter { $0.looksLikeMouse || config.showAllPointingDevices }

        var list: [MouseDevice] = []
        for service in services where !list.contains(where: { $0.id == service.identity.key }) {
            list.append(MouseDevice(id: service.identity.key, name: service.name, transport: service.identity.transport, connected: true))
        }
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let away = config.profiles
            .filter { key, _ in !list.contains { $0.id == key } }
            .map { key, profile in
                MouseDevice(id: key, name: profile.name, transport: key.split(separator: ":").dropFirst(2).joined(separator: ":"), connected: false)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        list += away
        if list != devices { devices = list }

        for service in services {
            if let profile = config.profiles[service.identity.key] {
                apply(profile, to: service, force: force)
            }
        }

        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityGranted {
            accessibilityGranted = trusted
            NSLog("Tiller: accessibility granted = \(trusted)")
        }
        if trusted, !wheel.isRunning {
            let started = wheel.start()
            NSLog("Tiller: scroll event tap started = \(started)")
            if wheelTapFailed == started { wheelTapFailed = !started }
        }
    }

    func profile(for device: MouseDevice) -> Profile {
        config.profiles[device.id] ?? Profile(name: device.name)
    }

    func setProfile(_ profile: Profile, for device: MouseDevice) {
        config.profiles[device.id] = profile
    }

    func forget(_ device: MouseDevice) {
        if config.profiles[device.id] != nil {
            config.profiles[device.id]?.resetToMacOS()
            config.profiles[device.id] = nil
        }
    }

    var connectedCount: Int { devices.filter(\.connected).count }

    /// With several mice attached we need to know which one is scrolling.
    var needsInputMonitoring: Bool { connectedCount > 1 && monitor.listeningDenied }

    // MARK: - Applying settings

    private func apply(_ profile: Profile, to service: PointerService, force: Bool) {
        let accel: Int32?
        switch profile.accelMode {
        case .macOS: accel = nil
        case .off: accel = HID.accelerationOff
        case .custom: accel = HID.toFixed(profile.accel)
        }
        set(service, keys: [service.pointerAccelKey, HID.pointerAcceleration], to: accel,
            system: HID.toFixed(HID.globalDefault("com.apple.mouse.scaling") ?? 0.6875), force: force)

        // Sensitivity works through the resolution macOS assumes for the mouse:
        // claiming fewer counts per inch makes every count move the cursor further.
        // 1.0x is the macOS default of 400 CPI.
        let resolution: Int32? = profile.cursorSpeedMode == .custom
            ? HID.toFixed(400 / max(profile.cursorSpeed, 0.05))
            : nil
        set(service, keys: [HID.pointerResolution], to: resolution, system: HID.defaultResolution, force: force)

        let scrollAccel: Int32?
        switch profile.scrollAccelMode {
        case .macOS: scrollAccel = nil
        case .off: scrollAccel = HID.accelerationOff
        case .custom: scrollAccel = HID.toFixed(profile.scrollAccel)
        }
        set(service, keys: [service.scrollAccelKey, HID.scrollAcceleration], to: scrollAccel,
            system: HID.toFixed(HID.globalDefault("com.apple.scrollwheel.scaling") ?? 0.3125), force: force)
    }

    /// Writes `target` to the service, or hands the property back to macOS
    /// (`system`) when `target` is nil and we had overridden it.
    private func set(_ service: PointerService, keys: [String], to target: Int32?, system: Int32, force: Bool) {
        for key in Set(keys) {
            let id = "\(service.registryID)/\(key)"
            // Some properties (the resolution) are write-only from here, so fall
            // back to what we last wrote instead of rewriting them on every pass.
            let current = service.fixed(key) ?? written[id]
            if let target {
                if current != target { service.setFixed(key, target) }
                written[id] = target
            } else if force || written[id] != nil {
                if current != system, current != nil { service.setFixed(key, system) }
                written[id] = nil
            }
        }
    }

    /// Puts every mouse back to what macOS would do on its own.
    func restoreAll() {
        for service in services where config.profiles[service.identity.key] != nil {
            apply(Profile(name: service.name), to: service, force: true)
        }
    }

    // MARK: - Wheel

    private func wheelProfile() -> Profile? {
        let connected = devices.filter(\.connected)
        if connected.count == 1 { return config.profiles[connected[0].id] }
        if let key = monitor.lastActiveKey, connected.contains(where: { $0.id == key }) {
            return config.profiles[key]
        }
        // Can't tell the mice apart: only act when just one of them wants changes.
        let candidates = connected.compactMap { config.profiles[$0.id] }.filter(\.rewritesWheelEvents)
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: - Permissions and login item

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Tiller: launch at login failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
