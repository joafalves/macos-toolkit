import AppKit
import Darwin

/// An app and what it uses, its helpers counted in.
struct AppUsage: Identifiable, Equatable {
    var id: pid_t
    var name: String
    var icon: NSImage?
    /// Of one core, as Activity Monitor counts it: 2 is two cores' worth.
    var cpu: Double
    var memory: UInt64

    static func == (a: AppUsage, b: AppUsage) -> Bool {
        a.id == b.id && a.name == b.name && a.cpu == b.cpu && a.memory == b.memory
    }
}

/// The apps using the most, read only while a panel that lists them is open.
/// Processes are filed under the app that started them, as Activity Monitor
/// does, so a browser's helpers add up to the browser. Other users' processes
/// (macOS's own daemons) can't be read without root and aren't listed.
final class TopApps {
    private var lastTimes: [pid_t: UInt64] = [:]
    /// Names and icons by process, looked up once: that lookup was most of a read.
    private var described: [pid_t: AppUsage] = [:]
    private var lastRead: TimeInterval?
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Whether the last read had an earlier one to tell CPU time from.
    private(set) var cpuKnown = false

    func read() -> [AppUsage] {
        let now = ProcessInfo.processInfo.systemUptime
        let seconds = lastRead.map { now - $0 } ?? 0
        lastRead = now
        cpuKnown = seconds > 0
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var times: [pid_t: UInt64] = [:]
        var byOwner: [pid_t: AppUsage] = [:]
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard status == 0 else { continue }
            let time = usage.ri_user_time + usage.ri_system_time
            times[pid] = time
            let cpu = seconds > 0 ? lastTimes[pid].map { Double(time &- $0) * Self.timebase / 1e9 / seconds } ?? 0 : 0
            let owner = AudioProcesses.responsiblePID(of: pid) ?? pid
            var entry = byOwner[owner] ?? described[owner] ?? {
                let entry = Self.describe(owner)
                described[owner] = entry
                return entry
            }()
            entry.cpu += max(0, cpu)
            entry.memory += usage.ri_phys_footprint
            byOwner[owner] = entry
        }
        lastTimes = times
        // Gone processes don't keep their names; a reused number gets a new one.
        described = described.filter { byOwner[$0.key] != nil }
        return Array(byOwner.values)
    }

    private static func describe(_ pid: pid_t) -> AppUsage {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return AppUsage(id: pid, name: name, icon: app.icon, cpu: 0, memory: 0)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return AppUsage(id: pid, name: name.isEmpty ? "Process \(pid)" : name, icon: nil, cpu: 0, memory: 0)
    }
}
