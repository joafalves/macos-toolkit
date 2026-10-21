import Foundation

/// macOS's own tiling settings that Window Layout steps on. Its tiling by
/// dragging (to an edge, to the top, or with ⌥ held) would snap the same
/// windows as ours, so it's off while ours watches drags. Its margins put a
/// fixed gap around windows it fills (double-clicking a title bar, ⌃🌐
/// arrows), so they follow our gap. Each key's value from before is kept in
/// a file, so a crash can't lose it: the next launch puts it back.
enum SystemTiling {
    static let dragKeys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"]
    static let marginsKey = "EnableTiledWindowMargins"

    /// Both can be pointed elsewhere by the self-test, so it never touches
    /// macOS's real settings.
    static var domain = "com.apple.WindowManager" as CFString
    static var savedURL = MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("layout-system-tiling.json")

    /// A key that's missing has never been changed, which is on.
    static func value(_ key: String) -> Bool? {
        (CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.boolValue
    }

    private static func write(_ key: String, _ value: Bool?) {
        let stored: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(key as CFString, stored, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// macOS's window manager reads these at its start only: a change since
    /// needs a restart of it, which macOS does by itself once it has quit.
    private static var unread = false

    private static func sync() {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        unread = true
    }

    /// Restarts macOS's window manager if anything changed since the last
    /// time, so the changes take effect. Desktop widgets and Stage Manager
    /// redraw for a moment.
    static func commit() {
        guard unread else { return }
        unread = false
        guard domain == "com.apple.WindowManager" as CFString else { return }
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["WindowManager"]
        try? killall.run()
        killall.waitUntilExit()
    }

    /// Sets the keys that aren't already so, remembering what each was the
    /// first time it's changed. Keys already right are left alone and not
    /// remembered, so they stay that way afterwards.
    static func change(_ values: [String: Bool]) {
        let changes = values.filter { (value($0.key) ?? true) != $0.value }
        guard !changes.isEmpty else { return }
        var saved = load() ?? [:]
        for key in changes.keys where saved[key] == nil { saved[key] = value(key).map { $0 ? "on" : "off" } ?? "missing" }
        // Written down before anything changes, so a crash halfway still knows.
        store(saved)
        for (key, value) in changes { write(key, value) }
        sync()
    }

    /// Puts back what `change` changed, for these keys or all of them. Also
    /// run at launch, in case a crash left something changed.
    static func restore(_ keys: [String]? = nil) {
        guard var saved = load() else { return }
        let back = saved.filter { keys?.contains($0.key) ?? true }
        guard !back.isEmpty else { return }
        for (key, value) in back {
            write(key, value == "missing" ? nil : value == "on")
            saved[key] = nil
        }
        sync()
        store(saved)
    }

    /// Sets keys for good: nothing is put back afterwards. For handing
    /// windows back to macOS when snapping is turned off in the toolkit.
    static func hand(_ values: [String: Bool]) {
        for (key, value) in values { write(key, value) }
        sync()
        if var saved = load() {
            for key in values.keys { saved[key] = nil }
            store(saved)
        }
    }

    /// By key: "on", "off", or "missing" for a key that wasn't there.
    private static func load() -> [String: String]? {
        guard let data = try? Data(contentsOf: savedURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// An empty record is no record.
    private static func store(_ saved: [String: String]) {
        guard !saved.isEmpty else {
            try? FileManager.default.removeItem(at: savedURL)
            return
        }
        try? FileManager.default.createDirectory(at: savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: savedURL, options: .atomic) }
    }
}
