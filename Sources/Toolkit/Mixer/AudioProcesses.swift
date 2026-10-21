import AppKit
import CoreAudio

/// One process that is connected to the audio system, as Core Audio lists it.
struct AudioClient {
    let object: AudioObjectID
    let pid: pid_t
    /// Playing sound right now, as opposed to only having audio open.
    let isPlaying: Bool
}

/// An app and every process that plays sound on its behalf. Browsers and
/// Electron apps play from helper processes, Safari from a WebKit service.
struct AudioAppGroup {
    let app: NSRunningApplication
    var objects: [AudioObjectID]
    var isPlaying: Bool
}

enum AudioProcesses {
    static func clients() -> [AudioClient] {
        AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self).compactMap { object in
            guard let pid = object.read(kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
            let playing = (object.read(kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0
            return AudioClient(object: object, pid: pid, isPlaying: playing)
        }
    }

    /// The audio clients grouped by the app they belong to. Processes that
    /// belong to no app, such as system services, are left out.
    static func groups() -> [pid_t: AudioAppGroup] {
        let own = ProcessInfo.processInfo.processIdentifier
        // Looked up by PID rather than taken from `runningApplications`, which
        // lists Steam with a PID of -1.
        var cache: [pid_t: NSRunningApplication?] = [:]
        func lookup(_ pid: pid_t) -> NSRunningApplication? {
            if let app = cache[pid] { return app }
            let app = NSRunningApplication(processIdentifier: pid).flatMap { isUserApp($0) ? $0 : nil }
            cache[pid] = app
            return app
        }
        func topApp(_ pid: pid_t) -> NSRunningApplication? {
            lookup(pid).flatMap { isNested($0) ? nil : $0 }
        }

        var groups: [pid_t: AudioAppGroup] = [:]
        for client in clients() {
            // A helper with no app above it still gets a row of its own.
            guard let app = owner(of: client.pid, topApp: topApp) ?? lookup(client.pid), app.processIdentifier != own else { continue }
            groups[app.processIdentifier, default: AudioAppGroup(app: app, objects: [], isPlaying: false)].objects.append(client.object)
            if client.isPlaying { groups[app.processIdentifier]?.isPlaying = true }
        }
        return groups
    }

    /// An app that shows up in the Dock or the menu bar, as opposed to a
    /// background service. Not only `.app` bundles: Steam runs from a folder
    /// called `Steam.AppBundle`. Apps in /System/Library, such as Finder,
    /// Control Center and the charging chime, only make system sounds.
    private static func isUserApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy != .prohibited, app.bundleIdentifier != nil, let url = app.bundleURL,
              !["xpc", "appex"].contains(url.pathExtension)
        else { return false }
        // Also catches the copies of system frameworks under /System/Volumes/Preboot.
        return !url.path.contains("/System/Library/")
    }

    /// A helper inside another app's bundle, like Claude Helper inside Claude
    /// or Steam Helper inside Steam.
    private static func isNested(_ app: NSRunningApplication) -> Bool {
        app.bundleURL?.deletingLastPathComponent().pathComponents.contains("Contents") ?? false
    }

    private static func owner(of pid: pid_t, topApp: (pid_t) -> NSRunningApplication?) -> NSRunningApplication? {
        if let app = topApp(pid) { return app }
        // What Activity Monitor uses to file XPC services under their app.
        if let responsible = responsiblePID(of: pid), let app = topApp(responsible) { return app }
        // Helpers that the app started itself, like Chrome's.
        var current = pid
        for _ in 0..<16 {
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            if let app = topApp(parent) { return app }
            current = parent
        }
        return nil
    }

    /// The Core Audio object of a process, which exists once it has used audio.
    static func processObject(of pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != .unknown ? object : nil
    }

    private typealias ResponsibleFunc = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunc: ResponsibleFunc? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunc.self)
    }()

    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let pid = responsibleFunc?(pid), pid > 0 else { return nil }
        return pid
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
