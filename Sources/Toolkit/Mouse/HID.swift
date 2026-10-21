import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// What a saved profile is keyed by: the mouse model plus how it is connected.
struct MouseIdentity: Hashable {
    let vendorID: Int
    let productID: Int
    let transport: String

    var key: String { "\(vendorID):\(productID):\(transport)" }
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

    static func toFixed(_ value: Double) -> Int32 {
        Int32((value * 65536).rounded())
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
            guard let vendor = (prop(kIOHIDVendorIDKey) as? NSNumber)?.intValue,
                  let product = (prop(kIOHIDProductIDKey) as? NSNumber)?.intValue
            else { return nil }
            let transport = prop(kIOHIDTransportKey) as? String ?? "Unknown"
            let name = prop(kIOHIDProductKey) as? String ?? "Mouse"
            let builtIn = (prop(kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false
            let isTrackpad = (prop("HIDPointerAccelerationType") as? String) == "HIDTrackpadAcceleration"
            let registryID = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0

            return PointerService(
                client: service,
                registryID: registryID,
                identity: MouseIdentity(vendorID: vendor, productID: product, transport: transport),
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
    /// True when macOS refused to let us listen to at least one mouse
    /// (it requires Input Monitoring for devices that also report keys).
    private(set) var listeningDenied = false
    var onDevicesChanged: (() -> Void)?

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
        guard let vendor = (prop(kIOHIDVendorIDKey) as? NSNumber)?.intValue,
              let product = (prop(kIOHIDProductIDKey) as? NSNumber)?.intValue
        else { return }
        let builtIn = (prop(kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false
        let name = prop(kIOHIDProductKey) as? String ?? ""
        guard !builtIn, !HID.nameLooksLikeKeyboard(name) else { return }

        let identity = MouseIdentity(vendorID: vendor, productID: product, transport: prop(kIOHIDTransportKey) as? String ?? "Unknown")
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            listeningDenied = true
            return
        }
        keys[Unmanaged.passUnretained(device).toOpaque()] = identity.key
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, sender, _ in
            guard let context, let sender else { return }
            let monitor = Unmanaged<ActivityMonitor>.fromOpaque(context).takeUnretainedValue()
            if let key = monitor.keys[sender] { monitor.active.value = key }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func removed(_ device: IOHIDDevice) {
        keys[Unmanaged.passUnretained(device).toOpaque()] = nil
        onDevicesChanged?()
    }
}
