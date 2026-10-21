import Foundation

/// macOS's own tiling by dragging (to an edge, to the top, or with ⌥ held),
/// which would snap the same windows as ours. It's switched off while ours
/// watches drags, and put back as it was afterwards. What it was is kept in a
/// file, so a crash can't lose it: the next launch puts it back.
enum SystemTiling {
    private static let domain = "com.apple.WindowManager" as CFString
    private static let keys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"]

    private static var savedURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("layout-system-tiling.json")
    }

    /// A key that's missing has never been changed, which is on.
    private static func value(_ key: String) -> Bool? {
        (CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.boolValue
    }

    private static func set(_ key: String, _ value: Bool?) {
        let stored: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(key as CFString, stored, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Whether any of it is on now.
    static var isOn: Bool { keys.contains { value($0) ?? true } }

    /// Switches off what is on, remembering it. Keys that were already off
    /// are left alone and not remembered, so they stay off afterwards.
    static func disable() {
        let on = keys.filter { value($0) ?? true }
        guard !on.isEmpty else { return }
        var saved = load() ?? [:]
        for key in on where saved[key] == nil { saved[key] = value(key).map { $0 ? "on" : "off" } ?? "missing" }
        // Written down before anything changes, so a crash halfway still knows.
        store(saved)
        for key in on { set(key, false) }
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Puts back what `disable` changed. Also run at launch, in case a crash
    /// left it off.
    static func restore() {
        guard let saved = load() else { return }
        for (key, value) in saved { set(key, value == "missing" ? nil : value == "on") }
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try? FileManager.default.removeItem(at: savedURL)
    }

    /// Turning snapping off in the toolkit hands windows back to macOS, so its
    /// tiling comes on, even if it was off before: off it would leave no
    /// snapping at all. Nothing is left to put back afterwards.
    static func enable() {
        for key in keys { set(key, true) }
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try? FileManager.default.removeItem(at: savedURL)
    }

    /// By key: "on", "off", or "missing" for a key that wasn't there.
    private static func load() -> [String: String]? {
        guard let data = try? Data(contentsOf: savedURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func store(_ saved: [String: String]) {
        try? FileManager.default.createDirectory(at: savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: savedURL, options: .atomic) }
    }
}
