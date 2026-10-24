import AppKit
import ApplicationServices
import IOKit.ps

/// A row in the device list: a connected mouse, or a saved profile whose
/// mouse is currently away.
struct MouseDevice: Identifiable, Equatable {
    let id: String
    /// What macOS calls it, or the name given in the toolkit.
    var name: String
    var transport: String
    var connected: Bool
    /// The end of its address or serial number, for telling apart mice with
    /// the same name.
    var shortUnit: String?
    /// What its charge is listed under (`MouseIdentity.batteryIDs`).
    var batteryIDs: Set<String> = []
}

final class MouseController: ObservableObject {
    @Published var config: MouseConfig {
        didSet {
            guard config != oldValue, !isPreview else { return }
            config.save()
            if oldValue.enabled, !config.enabled { restoreAll() }
            refresh(force: true)
        }
    }

    @Published private(set) var devices: [MouseDevice] = []
    /// The mouse whose page is open in the settings window; nil for the list.
    @Published var openID: String?
    /// Battery charge (0...100), for mice that report one: by the identifier
    /// the power-source registry gives (`MouseIdentity.batteryIDs`), and by
    /// "vendor:product" for mice that have none.
    @Published private(set) var batteries: [String: Int] = [:]
    @Published private(set) var accessibilityGranted = false
    /// Accessibility is granted but macOS still refused the event tap; this
    /// happens when the grant predates the running process.
    @Published private(set) var wheelTapFailed = false

    private let monitor = ActivityMonitor()
    private let wheel = WheelEngine()
    private var services: [PointerService] = []
    /// Values we have written this session, by "registryID/key".
    private var written: [String: Int32] = [:]
    private var timer: Timer?

    /// For `--snapshot`: a made-up mouse, with nothing read from or written
    /// to the real ones.
    private(set) var isPreview = false
    /// For `--snapshot mouse device`: the made-up mouse's own page.
    static var previewOpen = false

    static func preview() -> MouseController {
        let mouse = MouseController(preview: true)
        let id = "unit:00:00:00:00:00:01"
        var profile = Profile(name: "Wireless Mouse")
        profile.cursorSpeedMode = .custom
        profile.cursorSpeed = 1.2
        profile.accelMode = .custom
        profile.accel = 0.5
        profile.smoothScrolling = true
        mouse.config = MouseConfig()
        mouse.config.profiles[id] = profile
        mouse.config.profiles["unit:00:00:00:00:00:03"] = Profile(name: "Travel Mouse")
        mouse.devices = [
            MouseDevice(id: id, name: "Wireless Mouse", transport: "Bluetooth Low Energy", connected: true,
                        shortUnit: "00:01", batteryIDs: ["00:00:00:00:00:01"]),
            MouseDevice(id: "unit:00:00:00:00:00:02", name: "Wireless Mouse", transport: "USB", connected: true, shortUnit: "00:02"),
            MouseDevice(id: "unit:00:00:00:00:00:03", name: "Travel Mouse", transport: "Bluetooth", connected: false, shortUnit: "00:03"),
        ]
        if previewOpen { mouse.openID = id }
        mouse.batteries = ["00:00:00:00:00:01": 80]
        mouse.accessibilityGranted = true
        return mouse
    }

    private init(preview: Bool) {
        isPreview = true
        config = MouseConfig()
    }

    init() {
        config = MouseConfig.load()
        wheel.profileProvider = { [weak self] in self?.wheelProfile() }
        let choice = wheelChoice
        wheel.autoscroller.excludedApps = { choice.value.autoscrollExcluded }
        wheel.autoscroller.bypassKey = { choice.value.autoscrollBypass }
        monitor.onDevicesChanged = { [weak self] in
            // The event service appears slightly after the device itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh(force: false) }
        }
        refresh(force: false)

        // macOS re-pushes its global values now and then (wake, reconnect,
        // System Settings changes), so keep re-asserting ours. Only on the
        // mice already found: listing them again is what costs, and a mouse
        // coming or going is announced anyway.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Devices

    /// Battery levels change slowly; every so many ticks is plenty.
    private var ticks = 0

    private func tick() {
        ticks += 1
        // Now and then a full rescan anyway, in case a change went unannounced
        // (some mice come back as new services after sleep).
        if ticks % 30 == 0 { return refresh(force: false) }
        if ticks % 15 == 0 {
            let levels = Self.batteryLevels()
            if levels != batteries { batteries = levels }
        }
        reapply(force: false)
    }

    /// Rescans connected mice and applies their profiles. With `force`,
    /// settings left on "macOS" are actively put back to the system value.
    func refresh(force: Bool) {
        services = HID.pointerServices().filter { $0.looksLikeMouse || config.showAllPointingDevices }
        if adoptModelProfiles() { return }

        var list: [MouseDevice] = []
        for service in services where !list.contains(where: { $0.id == service.identity.key }) {
            let identity = service.identity
            list.append(MouseDevice(id: identity.key, name: config.profiles[identity.key]?.label ?? service.name,
                                    transport: identity.transport, connected: true,
                                    shortUnit: identity.shortUnit, batteryIDs: identity.batteryIDs))
        }
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let away = config.profiles
            .filter { key, _ in !list.contains { $0.id == key } }
            .map { key, profile in
                MouseDevice(id: key, name: profile.label ?? profile.name, transport: profile.transport ?? Self.transport(inModelKey: key),
                            connected: false, shortUnit: profile.shortUnit)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        list += away
        if list != devices { devices = list }
        if let openID, !list.contains(where: { $0.id == openID }) { self.openID = nil }
        let levels = Self.batteryLevels()
        if levels != batteries { batteries = levels }
        updateWheelChoice()
        reapply(force: force)
    }

    /// The profiles onto the mice already found, and the checks that can
    /// change without a mouse coming or going.
    private func reapply(force: Bool) {
        for service in services where config.enabled {
            if let profile = config.profiles[service.identity.key] {
                apply(profile, to: service, force: force)
            }
        }

        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityGranted {
            accessibilityGranted = trusted
            NSLog("Toolkit: accessibility granted = \(trusted)")
        }
        if config.enabled, trusted, !wheel.isRunning {
            let started = wheel.start()
            NSLog("Toolkit: scroll event tap started = \(started)")
            if wheelTapFailed == started { wheelTapFailed = !started }
        } else if !config.enabled, wheel.isRunning {
            wheel.stop()
        }
    }

    func profile(for device: MouseDevice) -> Profile {
        config.profiles[device.id] ?? newProfile(for: device)
    }

    func setProfile(_ profile: Profile, for device: MouseDevice) {
        config.profiles[device.id] = profile
    }

    /// A profile that leaves everything to macOS, with what's needed to list
    /// the mouse while it's away.
    private func newProfile(for device: MouseDevice) -> Profile {
        var profile = Profile(name: services.first { $0.identity.key == device.id }?.name ?? device.name)
        profile.transport = device.transport
        profile.shortUnit = device.shortUnit
        return profile
    }

    /// Every setting of the mouse back to macOS's; its name stays.
    func reset(_ device: MouseDevice) {
        config.profiles[device.id]?.resetToMacOS()
    }

    /// Puts the mouse back to macOS and drops what's saved for it. A connected
    /// one stays in the list, with nothing changed.
    func forget(_ device: MouseDevice) {
        guard config.profiles[device.id] != nil else { return }
        // Two steps: the reset is applied while the profile is still there.
        config.profiles[device.id]?.resetToMacOS()
        config.profiles[device.id] = nil
    }

    /// A name of its own for the mouse, or back to what macOS calls it when empty.
    func rename(_ device: MouseDevice, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = profile(for: device)
        profile.label = trimmed.isEmpty || trimmed == profile.name ? nil : trimmed
        config.profiles[device.id] = profile
    }

    /// The name macOS gives the mouse, under any the toolkit gave it.
    func systemName(of device: MouseDevice) -> String {
        config.profiles[device.id]?.name ?? device.name
    }

    /// Name for a list; the connection, and then the end of its address, are
    /// only spelled out when two entries would otherwise read the same.
    func label(for device: MouseDevice) -> String {
        var label = device.name
        let same = devices.filter { $0.name == device.name && $0.id != device.id }
        if !same.isEmpty {
            if same.allSatisfy({ Self.shortTransport($0.transport) != Self.shortTransport(device.transport) }) {
                label += " (\(Self.shortTransport(device.transport)))"
            } else if let unit = device.shortUnit {
                label += " (\(unit))"
            }
        }
        return label
    }

    static func shortTransport(_ transport: String) -> String {
        transport.hasPrefix("Bluetooth") ? "Bluetooth" : transport
    }

    func battery(for device: MouseDevice) -> Int? {
        guard device.connected else { return nil }
        if let level = device.batteryIDs.lazy.compactMap({ self.batteries[$0] }).first { return level }
        // Not listed under its own address or serial number: by its model,
        // as long as it's the only one of it connected, so the charge is its own.
        guard let model = services.first(where: { $0.identity.key == device.id })?.identity else { return nil }
        let same = Set(services.filter { $0.identity.vendorID == model.vendorID && $0.identity.productID == model.productID }.map(\.identity.key))
        guard same.count == 1 else { return nil }
        return batteries["\(model.vendorID):\(model.productID)"]
    }

    /// Reads the charge of wireless accessories from the power-source registry,
    /// the same place the Bluetooth menu gets it from.
    private static func batteryLevels() -> [String: Int] {
        // 4 is kIOPSSourceForAccessories.
        guard let blob = IOPSCopyPowerSourcesByType(4)?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [:] }
        var levels: [String: Int] = [:]
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            let max = info[kIOPSMaxCapacityKey] as? Int ?? 100
            let level = max > 0 ? current * 100 / max : current
            // Over Bluetooth its address, over USB its serial number.
            if let id = (info["Accessory Identifier"] as? String).flatMap(MouseIdentity.normalized) { levels[id] = level }
            if let vendor = info["Vendor ID"] as? Int, let product = info["Product ID"] as? Int {
                levels["\(vendor):\(product)"] = level
            }
        }
        return levels
    }

    /// Before 0.20.0, mice were saved by model and connection, so two of the
    /// same shared one profile. A mouse now saved by its own address that has
    /// none yet takes its model's, and once one has, the model's goes. One
    /// that has its own already supersedes its model's, as when settings
    /// exported before then are imported.
    /// Returns true when it changed the config, which refreshes again.
    private func adoptModelProfiles() -> Bool {
        var profiles = config.profiles
        var adopted: Set<String> = []
        for service in services {
            let identity = service.identity
            guard identity.unit != nil, var profile = profiles[identity.modelKey] else { continue }
            adopted.insert(identity.modelKey)
            guard profiles[identity.key] == nil else { continue }
            profile.transport = identity.transport
            profile.shortUnit = identity.shortUnit
            profiles[identity.key] = profile
        }
        guard !adopted.isEmpty else { return false }
        for key in adopted { profiles[key] = nil }
        config.profiles = profiles
        return true
    }

    /// The connection in a key saved by model ("vendor:product:transport").
    private static func transport(inModelKey key: String) -> String {
        key.split(separator: ":").dropFirst(2).joined(separator: ":")
    }

    #if TOOLKIT_DEV
    /// `--list-mice`: what the Mouse tool sees, and what each is saved under.
    static func dumpMice() {
        let levels = batteryLevels()
        for service in HID.pointerServices() {
            let id = service.identity
            let battery = id.batteryIDs.compactMap { levels[$0] }.first.map { "\($0)%" } ?? "-"
            print("\(service.name) [\(id.transport)] mouse=\(service.looksLikeMouse) key=\(id.key) model=\(id.modelKey) battery=\(battery)")
        }
        print("saved: " + MouseConfig.load().profiles.keys.sorted().joined(separator: ", "))
    }
    #endif

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
        switch profile.scrollMode {
        case .macOS: scrollAccel = nil
        // The wheel tap sets the distance, and macOS's curve on top would
        // shrink a slow notch to a point again.
        case .fixed, .curve: scrollAccel = HID.accelerationOff
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

    /// What the wheel tap needs to pick a profile, kept by the main thread
    /// for the tap's own: the connected mice and their profiles.
    private struct WheelChoice {
        var enabled = false
        var connected: [String] = []
        var profiles: [String: Profile] = [:]
        var autoscrollExcluded: Set<String> = []
        var autoscrollBypass: CGEventFlags = .maskAlternate
    }

    private let wheelChoice = Locked(WheelChoice())

    private func updateWheelChoice() {
        wheelChoice.value = WheelChoice(enabled: config.enabled, connected: devices.filter(\.connected).map(\.id), profiles: config.profiles,
                                        autoscrollExcluded: Set(config.autoscrollExcluded.keys), autoscrollBypass: config.autoscrollBypass.flag)
    }

    /// On the wheel tap's thread.
    private func wheelProfile() -> Profile? {
        let choice = wheelChoice.value
        guard choice.enabled else { return nil }
        let connected = choice.connected
        if connected.count == 1 { return choice.profiles[connected[0]] }
        if let key = monitor.lastActiveKey, connected.contains(key) {
            return choice.profiles[key]
        }
        // Can't tell the mice apart: only act when just one of them wants changes.
        let candidates = connected.compactMap { choice.profiles[$0] }.filter(\.needsEventTap)
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

}

/// Not in the public IOKit headers, but it is what `pmset -g accps` uses.
@_silgen_name("IOPSCopyPowerSourcesByType")
private func IOPSCopyPowerSourcesByType(_ type: Int32) -> Unmanaged<CFTypeRef>?
