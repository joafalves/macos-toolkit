import Foundation
import IOKit.hid

/// A mouse's vendor channel for HID++ 2.0, the protocol some makers use for
/// what the mouse does by itself: buttons macOS never sees (a DPI switch), and
/// the reprogrammable controls that can be told to report to us instead.
/// Over Bluetooth LE the channel is a collection of its own on the mouse (vendor
/// page 0xFF43); through a receiver it is page 0xFF00, and the mouse is one of
/// the receiver's numbered devices.
final class HIDPPChannel {
    let device: IOHIDDevice
    /// 0xFF for a mouse connected directly; 1...6 for one behind a receiver.
    private(set) var index: UInt8 = 0xFF
    private var replies: [[UInt8]] = []
    /// What the mouse sends of its own accord (software ID 0): a diverted
    /// control pressed or let go, on the channel's run loop.
    var onNotification: (([UInt8]) -> Void)?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let runLoop: CFRunLoop = CFRunLoopGetCurrent()!
    /// A request is waiting for its reply on this thread, running the loop:
    /// what else the loop runs meanwhile must not start another (`HIDPPButtons.later`).
    static var waiting = 0
    private static let software: UInt8 = 0x0A
    private static let longReport: UInt8 = 0x11

    static let matching: [[String: Any]] = [
        [kIOHIDDeviceUsagePageKey: 0xFF43, kIOHIDDeviceUsageKey: 0x0202],
        [kIOHIDDeviceUsagePageKey: 0xFF00, kIOHIDDeviceUsageKey: 0x0002],
    ]

    init?(_ device: IOHIDDevice) {
        self.device = device
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            buffer.deallocate()
            return nil
        }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // Some transports hand the report without its ID, some with it.
            if bytes.first != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
            let channel = Unmanaged<HIDPPChannel>.fromOpaque(context).takeUnretainedValue()
            if bytes.count >= 4, bytes[2] != 0xFF, bytes[3] & 0x0F == 0 { channel.onNotification?(bytes) } else { channel.replies.append(bytes) }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    enum Failure: Error { case send(IOReturn), refused(UInt8), timeout }

    /// One request and its reply's parameters, waiting on this run loop.
    func request(feature: UInt8, function: UInt8, _ params: [UInt8] = [], timeout: TimeInterval = 1) -> Result<[UInt8], Failure> {
        var message = [UInt8](repeating: 0, count: 20)
        message[0] = Self.longReport; message[1] = index; message[2] = feature; message[3] = (function << 4) | Self.software
        for (i, p) in params.prefix(16).enumerated() { message[4 + i] = p }
        replies.removeAll()
        let sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.longReport), message, message.count)
        guard sent == kIOReturnSuccess else { return .failure(.send(sent)) }
        let end = Date().addingTimeInterval(timeout)
        Self.waiting += 1
        defer { Self.waiting -= 1 }
        while Date() < end {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
            for r in replies where r.count >= 6 && r[1] == index {
                if r[2] == feature && r[3] == message[3] { return .success(Array(r[4...])) }
                if r[2] == 0xFF && r[3] == feature && r[4] == message[3] { return .failure(.refused(r[5])) }
            }
        }
        return .failure(.timeout)
    }

    /// Finds which device index answers: the mouse itself, or its slot on a receiver.
    func findIndex() -> Bool {
        for i: UInt8 in [0xFF, 1, 2, 3, 4, 5, 6] {
            index = i
            if case .success = request(feature: 0, function: 1, timeout: 0.4) { return true }
        }
        return false
    }

    /// Where a feature sits on this mouse, from the root feature; nil if it has none.
    func featureIndex(_ id: UInt16) -> UInt8? {
        guard case .success(let p) = request(feature: 0, function: 0, [UInt8(id >> 8), UInt8(id & 0xFF)]), p[0] != 0 else { return nil }
        return p[0]
    }

    /// A reprogrammable control (REPROG_CONTROLS_V4, 0x1B04).
    struct Control: Equatable {
        let cid: UInt16
        let task: UInt16
        let flags: UInt8
        let position: UInt8
        let group: UInt8
        /// How it reports now: bit 0 diverted, bit 2 diverted persistently.
        var reporting: UInt8?
        var divertable: Bool { flags & 0x20 != 0 }
        var mouseButton: Bool { flags & 0x01 != 0 }
        /// No button of its own: one the mouse makes up, for gestures.
        var virtual: Bool { flags & 0x80 != 0 }
        /// The buttons macOS sees anyway, by number: taken there, not here.
        var seenByMacOS: Bool { [0x0050, 0x0051, 0x0052, 0x0053, 0x0056].contains(cid) }
        /// A real button the mouse keeps to itself and lets us have.
        var offered: Bool { divertable && !virtual && !seenByMacOS }
        var diverted: Bool { (reporting ?? 0) & 0x01 != 0 }
    }

    static let reprogControls: UInt16 = 0x1B04

    func controls() -> [Control]? {
        guard let feature = featureIndex(Self.reprogControls),
              case .success(let count) = request(feature: feature, function: 0) else { return nil }
        return (0..<count[0]).compactMap { i in
            guard case .success(let p) = request(feature: feature, function: 1, [i]) else { return nil }
            var c = Control(cid: UInt16(p[0]) << 8 | UInt16(p[1]), task: UInt16(p[2]) << 8 | UInt16(p[3]), flags: p[4], position: p[5], group: p[6])
            if case .success(let r) = request(feature: feature, function: 2, [p[0], p[1]]) { c.reporting = r[2] }
            return c
        }
    }

    /// Reports the control to us (`divert`) or lets the mouse do its own thing
    /// with it again. Not persistent: the mouse forgets it when it disconnects.
    @discardableResult
    func setDiverted(_ cid: UInt16, _ divert: Bool, feature: UInt8) -> Bool {
        // Bit 0 divert, bit 1 "divert is valid": the other settings stay as they are.
        if case .success = request(feature: feature, function: 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), divert ? 0x03 : 0x02]) { return true }
        return false
    }

    /// Names for the control IDs this protocol has made common, for a readable list.
    static let controlNames: [UInt16: String] = [
        0x0050: "left button", 0x0051: "right button", 0x0052: "middle button", 0x0053: "back", 0x0056: "forward",
        0x00C3: "gesture button", 0x00C4: "smart shift", 0x00D7: "virtual gesture", 0x00FD: "DPI switch",
    ]
}

#if TOOLKIT_DEV
extension HIDPPChannel {
    /// `--list-mouse-controls [file]`: every mouse's HID++ features and controls,
    /// asked without changing anything. Run the app bundle with `open -n`, so
    /// macOS lets it open the mouse.
    static func dumpControls(to path: String?) {
        var out = ""
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        if devices.isEmpty { out += "no HID++ channel on any connected device\n" }
        for device in devices {
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
            out += "\(name) [\(transport)]\n"
            guard let channel = HIDPPChannel(device) else { out += "  could not open it (Input Monitoring, which comes with Accessibility?)\n"; continue }
            guard channel.findIndex() else { out += "  no HID++ 2.0 reply\n"; continue }
            out += String(format: "  device index 0x%02X\n", channel.index)
            if let fs = channel.featureIndex(0x0001), case .success(let n) = channel.request(feature: fs, function: 0) {
                let ids = (1...max(1, Int(n[0]))).compactMap { i -> String? in
                    guard case .success(let p) = channel.request(feature: fs, function: 1, [UInt8(i)]) else { return nil }
                    return String(format: "%02X%02X", p[0], p[1])
                }
                out += "  features: \(ids.joined(separator: " "))\n"
            }
            if let dpi = channel.featureIndex(0x2201), case .success(let p) = channel.request(feature: dpi, function: 2, [0]) {
                out += "  DPI now \(Int(p[1]) << 8 | Int(p[2])), default \(Int(p[3]) << 8 | Int(p[4]))\n"
            }
            guard let controls = channel.controls() else { out += "  no reprogrammable controls (0x1B04)\n"; continue }
            for c in controls {
                var flags: [String] = []
                for (bit, label) in [(0x01, "mouse"), (0x02, "fkey"), (0x04, "hotkey"), (0x08, "fntoggle"), (0x10, "reprogrammable"), (0x20, "divertable"), (0x40, "persistently-divertable"), (0x80, "virtual")] where Int(c.flags) & bit != 0 { flags.append(label) }
                let reporting = c.reporting.map { String(format: "reporting 0x%02X", $0) } ?? "reporting ?"
                out += String(format: "  cid 0x%04X task 0x%04X pos %d group %d  %@ [%@] %@\n", c.cid, c.task, c.position, c.group, controlNames[c.cid] ?? "", flags.joined(separator: " "), reporting)
            }
        }
        if let path { try? out.write(toFile: path, atomically: true, encoding: .utf8) }
        print(out, terminator: "")
    }
}
#endif
