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
    /// Each process's CPU time at each read of the last few seconds: CPU is
    /// told from the oldest, an average like Activity Monitor's, so one
    /// spike doesn't put an app on top for a reading.
    private var snapshots: [(at: TimeInterval, times: [pid_t: UInt64])] = []
    private static let window: TimeInterval = 5
    /// Less than this behind it and there's no CPU to tell yet: over a
    /// moment, any spike reads as a lot.
    private static let shortest: TimeInterval = 1
    /// Names and icons by process, looked up once: that lookup was most of a read.
    private var described: [pid_t: AppUsage] = [:]
    /// No CPU before `restart`: until then the panel is still opening.
    private var counting = false
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Whether the last read had an earlier one to tell CPU time from.
    private(set) var cpuKnown = false

    /// Starts counting afresh from now: the panel calls it once it has
    /// drawn, so its own opening isn't counted as the toolkit's use.
    func restart() {
        var times: [pid_t: UInt64] = [:]
        for pid in Self.pids() {
            if let usage = Self.usage(pid) { times[pid] = usage.ri_user_time + usage.ri_system_time }
        }
        snapshots = [(ProcessInfo.processInfo.systemUptime, times)]
        counting = true
        cpuKnown = false
    }

    func read() -> [AppUsage] {
        let now = ProcessInfo.processInfo.systemUptime
        // The reads within the window and the last one before it, so the
        // average reaches back the whole window even at 5 s between reads.
        if let older = snapshots.lastIndex(where: { now - $0.at > Self.window }) { snapshots.removeFirst(older) }
        let anchor = snapshots.first
        let seconds = anchor.map { now - $0.at } ?? 0
        cpuKnown = counting && seconds >= Self.shortest
        var times: [pid_t: UInt64] = [:]
        var byOwner: [pid_t: AppUsage] = [:]
        for pid in Self.pids() {
            guard let usage = Self.usage(pid) else { continue }
            let time = usage.ri_user_time + usage.ri_system_time
            times[pid] = time
            // Less than before: the number went to a new process since.
            let cpu = cpuKnown ? anchor?.times[pid].map { time >= $0 ? Double(time - $0) * Self.timebase / 1e9 / seconds : 0 } ?? 0 : 0
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
        if counting { snapshots.append((now, times)) }
        // Gone processes don't keep their names; a reused number gets a new one.
        described = described.filter { byOwner[$0.key] != nil }
        return Array(byOwner.values)
    }

    private static func pids() -> ArraySlice<pid_t> {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }[...]
    }

    private static func usage(_ pid: pid_t) -> rusage_info_v2? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return status == 0 ? usage : nil
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
