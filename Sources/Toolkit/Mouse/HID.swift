import ApplicationServices
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// What a saved profile is keyed by: the mouse itself, so two of the same
/// model each have their own, and one keeps its own on the cable too.
struct MouseIdentity: Hashable {
    let vendorID: Int
    let productID: Int
    let transport: String
    /// The mouse's Bluetooth address, which it also reports over USB, or else
    /// its serial number. Nil for a mouse with neither.
    let unit: String?
    /// What the charge in the power-source registry is listed under: the
    /// address over Bluetooth, the serial number over USB.
    let batteryIDs: Set<String>

    var key: String { unit.map { "unit:\($0)" } ?? modelKey }
    /// The model plus how it is connected: the key before 0.20.0, and still
    /// the one for a mouse that has no address or serial number.
    var modelKey: String { "\(vendorID):\(productID):\(transport)" }

    /// From a device's or a service's properties, which hold the same keys,
    /// and its place in the I/O Registry, where the rest is.
    init?(_ prop: (String) -> Any?, entry: io_registry_entry_t) {
        guard let vendor = (prop(kIOHIDVendorIDKey) as? NSNumber)?.intValue,
              let product = (prop(kIOHIDProductIDKey) as? NSNumber)?.intValue
        else { return nil }
        vendorID = vendor
        productID = product
        transport = prop(kIOHIDTransportKey) as? String ?? "Unknown"
        // Over Bluetooth the serial number is the address.
        let ids = HID.ids(of: entry)
        let serial = ids.serial.flatMap(Self.normalized)
        let address = ids.address.flatMap(Self.normalized)
        unit = address ?? serial
        batteryIDs = Set([address, serial].compactMap { $0 })
    }

    /// One spelling for an address however it's written ("7c-f3-…" over USB,
    /// "7C:F3:…" over Bluetooth and in the power-source registry).
    static func normalized(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    /// The end of the address or serial number, to tell apart two mice
    /// with the same name.
    var shortUnit: String? {
        guard let unit else { return nil }
        return unit.contains(":") ? unit.split(separator: ":").suffix(2).joined(separator: ":") : String(unit.suffix(4))
    }
}

/// One HID event service belonging to a pointing device. Pointer speed and
/// acceleration live on these as per-service properties.
struct PointerService {
    let client: IOHIDServiceClient
    let registryID: UInt64
    let identity: MouseIdentity
    let name: String
    let looksLikeMouse: Bool

    private func number(_ key: String) -> NSNumber? {
        IOHIDServiceClientCopyProperty(client, key as CFString) as? NSNumber
    }

    func string(_ key: String) -> String? {
        IOHIDServiceClientCopyProperty(client, key as CFString) as? String
    }

    /// Reads a 16.16 fixed-point property.
    func fixed(_ key: String) -> Int32? {
        number(key)?.int32Value
    }

    @discardableResult
    func setFixed(_ key: String, _ value: Int32) -> Bool {
        IOHIDServiceClientSetProperty(client, key as CFString, NSNumber(value: value))
    }

    /// The property macOS actually reads for this device class
    /// (mouse vs. trackpad), falling back to the mouse one.
    var pointerAccelKey: String { string("HIDPointerAccelerationType") ?? "HIDMouseAcceleration" }
    var scrollAccelKey: String { string("HIDScrollAccelerationType") ?? "HIDMouseScrollAcceleration" }
}

enum HID {
    static let pointerAcceleration = "HIDPointerAcceleration"
    static let scrollAcceleration = "HIDScrollAcceleration"
    static let pointerResolution = "HIDPointerResolution"
    /// macOS assumes 400 CPI when a mouse does not report a resolution.
    static let defaultResolution: Int32 = 400 << 16
    /// A negative acceleration tells macOS to skip the curve (1:1 movement).
    static let accelerationOff: Int32 = -1 << 16

    /// Clamped: `Int32(_:)` traps on a value too big for it, or on NaN.
    static func toFixed(_ value: Double) -> Int32 {
        let fixed = (value * 65536).rounded()
        return fixed.isFinite ? Int32(clamping: Int64(max(-1e15, min(1e15, fixed)))) : 0
    }

    // The client must outlive the services copied from it.
    private static var client: IOHIDEventSystemClient?

    /// Lists every service that reports itself as a mouse or pointer.
    static func pointerServices() -> [PointerService] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        self.client = client
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return all.compactMap { service in
            let isMouse = IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
            let isPointer = IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) != 0
            guard isMouse || isPointer else { return nil }

            func prop(_ key: String) -> Any? { IOHIDServiceClientCopyProperty(service, key as CFString) }
            let registryID = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
            let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
            defer { IOObjectRelease(entry) }
            guard let identity = MouseIdentity(prop, entry: entry) else { return nil }
            let name = prop(kIOHIDProductKey) as? String ?? String(localized: "Mouse")
            let builtIn = (prop(kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false
            let isTrackpad = (prop("HIDPointerAccelerationType") as? String) == "HIDTrackpadAcceleration"

            return PointerService(
                client: service,
                registryID: registryID,
                identity: identity,
                name: name,
                looksLikeMouse: !builtIn && !isTrackpad && !nameLooksLikeKeyboard(name)
            )
        }
    }

    /// Many keyboards (e.g. MX Keys) expose a pointer collection and so show up
    /// as mice; their HID descriptors alone don't tell the two apart.
    static func nameLooksLikeKeyboard(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["keyboard", "keys", "keypad", "numpad"].contains { lower.contains($0) }
    }

    /// Walks up from a HID service (or device) to the serial number of its
    /// HID device and, for a mouse on its cable, on to its USB device, under
    /// which Apple's mice also report their Bluetooth address. No further:
    /// above are hubs, or over Bluetooth a node every device shares, whose
    /// numbers aren't the mouse's.
    static func ids(of entry: io_registry_entry_t) -> (serial: String?, address: String?) {
        guard entry != 0 else { return (nil, nil) }
        var serial: String?
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<8 {
            if serial == nil, IOObjectConformsTo(current, kIOHIDDeviceKey) != 0 {
                serial = IORegistryEntryCreateCFProperty(current, kIOHIDSerialNumberKey as CFString, nil, 0)?.takeRetainedValue() as? String
            }
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                let address = IORegistryEntrySearchCFProperty(current, kIOServicePlane, "DeviceAddress" as CFString, nil,
                                                              IOOptionBits(kIORegistryIterateRecursively)) as? String
                return (serial, address)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }
        return (serial, nil)
    }

    static func globalDefault(_ key: String) -> Double? {
        (CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.doubleValue
    }
}

/// Tracks which mouse produced input most recently, so wheel events (which
/// carry no device information) can be attributed to a profile.
final class ActivityMonitor {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var keys: [UnsafeMutableRawPointer: String] = [:]

    /// Read by the wheel tap on its own thread.
    private let active = Locked<String?>(nil)
    var lastActiveKey: String? { active.value }
    /// The mice macOS refused to let us listen to (it requires Input
    /// Monitoring for devices that also report keys), tried again once
    /// that's granted (`retryRefused`).
    private var refused: [UnsafeMutableRawPointer: (IOHIDDevice, String)] = [:]
    var onDevicesChanged: (() -> Void)?
    /// Every mouse macOS has announced, listened to or not.
    var presentKeys: Set<String> { Set(keys.values).union(refused.values.map(\.1)) }

    init() {
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<ActivityMonitor>.fromOpaque(context!).takeUnretainedValue().added(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<ActivityMonitor>.fromOpaque(context!).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    private func added(_ device: IOHIDDevice) {
        defer { onDevicesChanged?() }
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        guard let identity = MouseIdentity(prop, entry: IOHIDDeviceGetService(device)) else { return }
        let builtIn = (prop(kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false
        let name = prop(kIOHIDProductKey) as? String ?? ""
        guard !builtIn, !HID.nameLooksLikeKeyboard(name) else { return }

        listen(device, key: identity.key)
    }

    /// Input Monitoring, which macOS gives with Accessibility, granted while
    /// the app runs: the mice refused at connection would otherwise wait for
    /// a reconnect.
    func retryRefused() {
        // Accessibility brings it with it, as macOS has it.
        guard !refused.isEmpty,
              IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted || AXIsProcessTrusted() else { return }
        for (device, key) in refused.values { listen(device, key: key) }
        onDevicesChanged?()
    }

    private func listen(_ device: IOHIDDevice, key: String) {
        let id = Unmanaged.passUnretained(device).toOpaque()
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            refused[id] = (device, key)
            return
        }
        refused[id] = nil
        keys[id] = key
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, sender, _ in
            guard let context, let sender else { return }
            let monitor = Unmanaged<ActivityMonitor>.fromOpaque(context).takeUnretainedValue()
            if let key = monitor.keys[sender] { monitor.active.value = key }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func removed(_ device: IOHIDDevice) {
        keys[Unmanaged.passUnretained(device).toOpaque()] = nil
        refused[Unmanaged.passUnretained(device).toOpaque()] = nil
        onDevicesChanged?()
    }
}
