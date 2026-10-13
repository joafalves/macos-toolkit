import Foundation

/// A setting that either defers to macOS or uses Tiller's own value.
enum ValueMode: String, Codable, CaseIterable {
    case macOS, custom
}

/// Like `ValueMode`, for settings that can also be switched off entirely.
enum AccelMode: String, Codable, CaseIterable {
    case macOS, off, custom
}

/// Per-mouse settings. Every field defaults to "macOS", meaning Tiller leaves
/// that behaviour to System Settings.
struct Profile: Codable, Equatable {
    var name: String

    // Cursor
    var cursorSpeedMode: ValueMode = .macOS
    /// Multiplier over the mouse's native resolution (1.0 = unchanged).
    var cursorSpeed: Double = 1.0
    var accelMode: AccelMode = .macOS
    /// Same scale as the macOS "Tracking speed" slider (0...3).
    var accel: Double = 0.6875

    // Wheel
    var verticalInverted = false
    var horizontalInverted = false
    var scrollSpeedMode: ValueMode = .macOS
    /// Multiplier applied to each wheel event's distance.
    var scrollSpeed: Double = 1.0
    var scrollAccelMode: AccelMode = .macOS
    /// Same scale as the macOS "Scrolling speed" slider.
    var scrollAccel: Double = 0.3125
    var smoothScrolling = false

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mouse"
        cursorSpeedMode = try c.decodeIfPresent(ValueMode.self, forKey: .cursorSpeedMode) ?? .macOS
        cursorSpeed = try c.decodeIfPresent(Double.self, forKey: .cursorSpeed) ?? 1.0
        accelMode = try c.decodeIfPresent(AccelMode.self, forKey: .accelMode) ?? .macOS
        accel = try c.decodeIfPresent(Double.self, forKey: .accel) ?? 0.6875
        verticalInverted = try c.decodeIfPresent(Bool.self, forKey: .verticalInverted) ?? false
        horizontalInverted = try c.decodeIfPresent(Bool.self, forKey: .horizontalInverted) ?? false
        scrollSpeedMode = try c.decodeIfPresent(ValueMode.self, forKey: .scrollSpeedMode) ?? .macOS
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1.0
        scrollAccelMode = try c.decodeIfPresent(AccelMode.self, forKey: .scrollAccelMode) ?? .macOS
        scrollAccel = try c.decodeIfPresent(Double.self, forKey: .scrollAccel) ?? 0.3125
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? false
    }

    /// True when any setting needs the scroll event tap (and so Accessibility).
    var rewritesWheelEvents: Bool {
        verticalInverted || horizontalInverted || smoothScrolling
            || (scrollSpeedMode == .custom && scrollSpeed != 1.0)
    }

    var isAllMacOS: Bool {
        cursorSpeedMode == .macOS && accelMode == .macOS && scrollSpeedMode == .macOS
            && scrollAccelMode == .macOS && !verticalInverted && !horizontalInverted && !smoothScrolling
    }

    mutating func resetToMacOS() {
        self = Profile(name: name)
    }
}

struct Config: Codable, Equatable {
    /// Keyed by `MouseIdentity.key` (vendor:product:transport).
    var profiles: [String: Profile] = [:]
    var restoreOnQuit = true
    var showAllPointingDevices = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
        restoreOnQuit = try c.decodeIfPresent(Bool.self, forKey: .restoreOnQuit) ?? true
        showAllPointingDevices = try c.decodeIfPresent(Bool.self, forKey: .showAllPointingDevices) ?? false
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tiller", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else {
            let config = Config.firstRun
            config.save()
            return config
        }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    func save() {
        let url = Config.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Seeds the MX Anywhere 2S (Bluetooth) with the cursor values carried over
    /// from the previous SteerMouse setup: tracking speed 0.685 at native CPI.
    private static var firstRun: Config {
        var config = Config()
        var profile = Profile(name: "MX Anywhere 2S")
        profile.accelMode = .custom
        profile.accel = 0.685
        profile.cursorSpeedMode = .custom
        profile.cursorSpeed = 1.0
        config.profiles["1133:45082:Bluetooth Low Energy"] = profile
        return config
    }
}
