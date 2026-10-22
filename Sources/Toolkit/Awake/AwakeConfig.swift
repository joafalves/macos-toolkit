import Foundation

/// How Keep Awake shows in the menu bar.
enum AwakeMenuBarIcon: String, Codable, CaseIterable {
    /// No part of its own: a submenu in the toolkit menu.
    case none
    /// A pill filled with the time left, like the battery's charge.
    case pill
    /// The cup, with the time left beside it.
    case cupAndTime
    /// Only the cup, filled while it's on: no time.
    case cup
}

/// How Stay available keeps chat apps from marking you away.
enum StayAvailableMethod: String, Codable, CaseIterable {
    /// A mouse move to where the pointer already is: nothing on screen changes.
    case signal
    /// The pointer drifts to a spot nearby.
    case mouseMove
}

struct AwakeConfig: Codable, Equatable {
    var enabled = true
    var menuBarIcon = AwakeMenuBarIcon.pill {
        didSet { if menuBarIcon != .none { shownIcon = menuBarIcon } }
    }
    /// The look it had when last in the menu bar, for when it's put back.
    var shownIcon = AwakeMenuBarIcon.pill
    /// With no end, the menu bar counts up how long it's been on.
    var showElapsed = false
    /// Turns it on or off, with no end. None until one is set.
    var shortcut = Shortcut.none
    /// Off keeps only the system awake: the display may sleep while
    /// downloads and jobs go on.
    var keepDisplayOn = true
    /// Awake with the lid closed, on battery too. Needs the admin rule.
    var lidClosed = false
    /// On battery, a session ends below this charge, and none starts. 0 is never.
    var batteryFloor = 0
    var notifyAtEnd = false
    var soundAtEnd = true
    var stayAvailable = false
    var stayAvailableMethod = StayAvailableMethod.signal
    /// Seconds without input before Stay available acts.
    var stayAvailableEvery: TimeInterval = 120

    init() {}

    /// Stay available holds the display on: a chat app can't see you're there
    /// through a dark screen, and waking it every few minutes would undo the
    /// choice to let it sleep. Your own choice is kept for when it's off.
    var displayStaysOn: Bool { keepDisplayOn || stayAvailable }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        menuBarIcon = (try? c.decodeIfPresent(AwakeMenuBarIcon.self, forKey: .menuBarIcon)) ?? .pill
        // A file from before this was kept has the look in use, if any.
        let shown = (try? c.decodeIfPresent(AwakeMenuBarIcon.self, forKey: .shownIcon)) ?? nil
        shownIcon = menuBarIcon != .none ? menuBarIcon : shown.flatMap { $0 == .none ? nil : $0 } ?? .pill
        showElapsed = try c.decodeIfPresent(Bool.self, forKey: .showElapsed) ?? false
        shortcut = try c.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? .none
        keepDisplayOn = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayOn) ?? true
        lidClosed = try c.decodeIfPresent(Bool.self, forKey: .lidClosed) ?? false
        batteryFloor = try c.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? 0
        notifyAtEnd = try c.decodeIfPresent(Bool.self, forKey: .notifyAtEnd) ?? false
        soundAtEnd = try c.decodeIfPresent(Bool.self, forKey: .soundAtEnd) ?? true
        stayAvailable = try c.decodeIfPresent(Bool.self, forKey: .stayAvailable) ?? false
        stayAvailableMethod = (try? c.decodeIfPresent(StayAvailableMethod.self, forKey: .stayAvailableMethod)) ?? .signal
        stayAvailableEvery = try c.decodeIfPresent(TimeInterval.self, forKey: .stayAvailableEvery) ?? 120
    }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("awake.json")
    }

    static func load() -> AwakeConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AwakeConfig() }
        return (try? JSONDecoder().decode(AwakeConfig.self, from: data)) ?? AwakeConfig()
    }

    func save() {
        let url = AwakeConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// A session in progress. Kept in a file of its own, apart from the settings,
/// so it carries on after a relaunch or a restart, and an export of the
/// settings doesn't take it along.
struct AwakeSession: Codable, Equatable {
    var started: Date
    /// Nil for no end.
    var until: Date?

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("awake-session.json")
    }

    /// The session left from before, if it hasn't run out.
    static func load() -> AwakeSession? {
        guard let data = try? Data(contentsOf: fileURL),
              let session = try? JSONDecoder().decode(AwakeSession.self, from: data) else { return nil }
        if let until = session.until, until <= Date() { return nil }
        return session
    }

    static func store(_ session: AwakeSession?) {
        guard let session else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(session) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// How much of a timed session is left, 0 to 1; 1 for no end.
    func fractionLeft(at now: Date = Date()) -> Double {
        guard let until else { return 1 }
        let total = until.timeIntervalSince(started)
        guard total > 0 else { return 0 }
        return min(1, max(0, until.timeIntervalSince(now) / total))
    }
}
