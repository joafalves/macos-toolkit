import Darwin
import Foundation
import IOKit
import SystemConfiguration

/// What each stat reads, with the counters it needs between reads. Each one
/// is only read while it's shown or its panel is open; a reading that needs a
/// previous one (a speed, a share of time) is nil the first time.

struct CPUReading: Equatable {
    /// 0 to 1 of all cores.
    var total: Double
    var user: Double
    var system: Double
    /// 0 to 1 each, in macOS's order.
    var cores: [Double]
    /// Core groups, as macOS names them ("Super", "Performance", "Efficiency").
    var groups: [CoreGroup]
}

struct CoreGroup: Equatable {
    var name: String
    var cores: Range<Int>
}

struct MemoryReading: Equatable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    /// Files macOS keeps in memory and drops as soon as apps need room.
    var cached: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var pressure: MemoryPressure

    /// What can't be dropped without swapping, of all there is.
    var needed: UInt64 { app + wired + compressed }
    var neededShare: Double { total > 0 ? min(1, Double(needed) / Double(total)) : 0 }
}

enum MemoryPressure: Int, Equatable {
    case normal = 1, warning = 2, critical = 4
}

struct NetworkReading: Equatable {
    /// Bytes a second.
    var up: Double
    var down: Double
    var interface: String?
    var address: String?
}

struct DiskReading: Equatable {
    var total: Int64
    var free: Int64
    /// Bytes a second, across disks; nil until there's a previous read.
    var read: Double?
    var write: Double?

    var usedShare: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

struct PowerReading: Equatable {
    /// What the whole Mac draws, in watts.
    var system: Double?
    var cpu: Double?
    var gpu: Double?
    /// What the charger can give, in watts, while one is connected.
    var charger: Int?
    var charging: Bool
    var battery: Int?
    /// Of the battery's design capacity, in percent.
    var health: Int?
    var cycles: Int?

    /// The whole Mac's draw where the battery reports it; on a desktop, which
    /// has none, what the CPU and GPU draw.
    var drawn: Double? {
        if let system { return system }
        guard cpu != nil || gpu != nil else { return nil }
        return (cpu ?? 0) + (gpu ?? 0)
    }
}

enum StatsReadings {
    // MARK: - CPU

    final class CPU {
        private var last: [[UInt32]]?
        private let groups = CPU.coreGroups()

        func read() -> CPUReading? {
            guard let ticks = Self.ticks() else { return nil }
            defer { last = ticks }
            guard let last, last.count == ticks.count else { return nil }
            var user = 0.0, system = 0.0, all = 0.0
            var cores: [Double] = []
            for (now, before) in zip(ticks, last) {
                // Counters wrap; the difference of the unsigned values doesn't care.
                let u = Double(now[Int(CPU_STATE_USER)] &- before[Int(CPU_STATE_USER)])
                    + Double(now[Int(CPU_STATE_NICE)] &- before[Int(CPU_STATE_NICE)])
                let s = Double(now[Int(CPU_STATE_SYSTEM)] &- before[Int(CPU_STATE_SYSTEM)])
                let idle = Double(now[Int(CPU_STATE_IDLE)] &- before[Int(CPU_STATE_IDLE)])
                let total = u + s + idle
                cores.append(total > 0 ? (u + s) / total : 0)
                user += u
                system += s
                all += total
            }
            guard all > 0 else { return nil }
            return CPUReading(total: (user + system) / all, user: user / all, system: system / all, cores: cores, groups: groups)
        }

        private static func ticks() -> [[UInt32]]? {
            var count: natural_t = 0
            var info: processor_info_array_t?
            var size: mach_msg_type_number_t = 0
            guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &size) == KERN_SUCCESS,
                  let info else { return nil }
            defer {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(size) * vm_size_t(MemoryLayout<integer_t>.stride))
            }
            return (0..<Int(count)).map { core in
                (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[Int(CPU_STATE_MAX) * core + $0]) }
            }
        }

        /// macOS lists the slower cores first: perflevel1, then perflevel0.
        private static func coreGroups() -> [CoreGroup] {
            func int(_ name: String) -> Int? {
                var value: Int32 = 0
                var size = MemoryLayout<Int32>.size
                return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
            }
            func string(_ name: String) -> String? {
                var size = 0
                guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
                var buffer = [CChar](repeating: 0, count: size)
                guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
                return String(cString: buffer)
            }
            guard let levels = int("hw.nperflevels"), levels > 1 else { return [] }
            var groups: [CoreGroup] = []
            var start = 0
            for level in (0..<levels).reversed() {
                guard let count = int("hw.perflevel\(level).logicalcpu") else { return [] }
                groups.append(CoreGroup(name: string("hw.perflevel\(level).name") ?? "Level \(level)", cores: start..<(start + count)))
                start += count
            }
            return groups
        }
    }

    // MARK: - Memory

    static func memory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        // As Activity Monitor splits it: purgeable memory counts as cached,
        // since macOS can drop it as readily as a cached file.
        let purgeable = UInt64(stats.purgeable_count)
        let app = (UInt64(stats.internal_page_count) - min(purgeable, UInt64(stats.internal_page_count))) * page
        return MemoryReading(total: total,
                             app: app,
                             wired: UInt64(stats.wire_count) * page,
                             compressed: UInt64(stats.compressor_page_count) * page,
                             cached: (UInt64(stats.external_page_count) + purgeable) * page,
                             free: UInt64(stats.free_count) * page,
                             swapUsed: swap.xsu_used,
                             pressure: MemoryPressure(rawValue: Int(level)) ?? .normal)
    }

    // MARK: - Network

    final class Network {
        private var last: (up: UInt64, down: UInt64, time: TimeInterval, interface: String)?
        /// One session with configd for as long as network is read.
        private let store = SCDynamicStoreCreate(nil, "MacOS Toolkit" as CFString, nil, nil)

        func read() -> NetworkReading? {
            // Offline: nothing moves, rather than the last speeds standing.
            guard let interface = primaryInterface() else {
                last = nil
                return NetworkReading(up: 0, down: 0)
            }
            guard let counters = Self.counters(interface) else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            defer { last = (counters.up, counters.down, now, interface) }
            // Counters that went back (the interface was reset) say nothing.
            guard let last, last.interface == interface, now > last.time,
                  counters.up >= last.up, counters.down >= last.down else { return nil }
            let seconds = now - last.time
            return NetworkReading(up: Double(counters.up &- last.up) / seconds, down: Double(counters.down &- last.down) / seconds,
                                  interface: interface, address: Self.address(interface))
        }

        /// The interface macOS sends traffic through: Wi-Fi, Ethernet, or a VPN's.
        private func primaryInterface() -> String? {
            guard let store, let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
            return global["PrimaryInterface"] as? String
        }

        /// 64-bit counters from the routing table's interface list.
        private static func counters(_ interface: String) -> (up: UInt64, down: UInt64)? {
            var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
            var size = 0
            guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return nil }
            let index = if_nametoindex(interface)
            guard index > 0 else { return nil }
            return buffer.withUnsafeBytes { raw -> (UInt64, UInt64)? in
                var offset = 0
                while offset + MemoryLayout<if_msghdr>.size <= size {
                    let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                    if header.ifm_type == RTM_IFINFO2, header.ifm_index == UInt16(index) {
                        let full = raw.load(fromByteOffset: offset, as: if_msghdr2.self)
                        return (full.ifm_data.ifi_obytes, full.ifm_data.ifi_ibytes)
                    }
                    guard header.ifm_msglen > 0 else { break }
                    offset += Int(header.ifm_msglen)
                }
                return nil
            }
        }

        private static func address(_ interface: String) -> String? {
            var list: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&list) == 0, let first = list else { return nil }
            defer { freeifaddrs(list) }
            var item: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = item {
                defer { item = entry.pointee.ifa_next }
                guard String(cString: entry.pointee.ifa_name) == interface,
                      let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            return nil
        }
    }

    // MARK: - Disk

    final class Disk {
        private var last: (read: UInt64, write: UInt64, disks: Int, time: TimeInterval)?
        private var space: (total: Int64, free: Int64, time: TimeInterval)?

        func read() -> DiskReading? {
            let now = ProcessInfo.processInfo.systemUptime
            // Free space as Finder counts it, with what macOS can purge; costly
            // to work out, and slow to change, so every half minute.
            if space.map({ now - $0.time > 30 }) ?? true {
                let root = URL(fileURLWithPath: "/")
                if let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
                   let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage {
                    space = (Int64(total), free, now)
                }
            }
            guard let space else { return nil }
            var reading = DiskReading(total: space.total, free: space.free)
            if let bytes = Self.transferred() {
                // The same disks, and counters that only went up: a disk that
                // comes or goes changes the sums by all it has ever moved,
                // which read as one absurd speed and flattened the chart.
                if let last, now > last.time, bytes.disks == last.disks, bytes.read >= last.read, bytes.write >= last.write {
                    reading.read = Double(bytes.read - last.read) / (now - last.time)
                    reading.write = Double(bytes.write - last.write) / (now - last.time)
                }
                last = (bytes.read, bytes.write, bytes.disks, now)
            }
            return reading
        }

        /// Bytes read and written since startup, across every disk's driver,
        /// and how many disks that is.
        private static func transferred() -> (read: UInt64, write: UInt64, disks: Int)? {
            var read: UInt64 = 0, write: UInt64 = 0, disks = 0
            let found = registry("IOBlockStorageDriver") { entry in
                guard let statistics = property(entry, "Statistics") as? [String: Any] else { return }
                disks += 1
                read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            return found ? (read, write, disks) : nil
        }
    }

    // MARK: - GPU

    /// The GPU driver's own figure, as Activity Monitor's GPU history shows it.
    static func gpu() -> Double? {
        var usage: Double?
        registry("IOAccelerator") { entry in
            guard let statistics = property(entry, "PerformanceStatistics") as? [String: Any],
                  let percent = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            usage = max(usage ?? 0, percent / 100)
        }
        return usage
    }

    // MARK: - Power

    /// The battery's own readings. `SystemLoad` is what the Mac draws, whether
    /// it comes from the charger or the battery. On Apple silicon the
    /// battery's `MaxCapacity` is its health, as System Settings shows it, and
    /// `CurrentCapacity` its charge, both in percent.
    static func power() -> PowerReading? {
        var reading: PowerReading?
        registry("AppleSmartBattery") { battery in
            func number(_ key: String) -> NSNumber? { property(battery, key) as? NSNumber }
            let telemetry = property(battery, "PowerTelemetryData") as? [String: Any]
            let adapter = property(battery, "AdapterDetails") as? [String: Any]
            let external = number("ExternalConnected")?.boolValue ?? false
            let health = number("MaxCapacity")?.intValue
            reading = PowerReading(
                system: (telemetry?["SystemLoad"] as? NSNumber).map { $0.doubleValue / 1000 },
                charger: external ? (adapter?["Watts"] as? NSNumber)?.intValue : nil,
                charging: number("IsCharging")?.boolValue ?? false,
                battery: number("CurrentCapacity")?.intValue,
                health: health.flatMap { $0 <= 100 ? $0 : nil },
                cycles: number("CycleCount")?.intValue)
        }
        return reading
    }

    // MARK: - The registry

    /// Calls `body` with each service of a class; false if there was none.
    /// Properties are read one by one with `property`: copying them all made a
    /// GPU or battery read cost ten times as much.
    @discardableResult
    static func registry(_ className: String, _ body: (io_registry_entry_t) -> Void) -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            found = true
            body(entry)
        }
        return found
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
