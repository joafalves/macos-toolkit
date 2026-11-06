import CoreGraphics
import Foundation

/// A setting that either defers to macOS or uses our own value.
enum ValueMode: String, Codable, CaseIterable {
    case macOS, custom
}

/// The key that, held while pressing the wheel button, gives the app its own
/// wheel button instead of autoscroll.
enum ModifierKey: String, Codable, CaseIterable {
    case option, control, shift, command

    var flag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .shift: return .maskShift
        case .command: return .maskCommand
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }
}

/// Like `ValueMode`, for settings that can also be switched off entirely.
enum AccelMode: String, Codable, CaseIterable {
    case macOS, off, custom
}

/// How far a notch of the wheel scrolls.
enum ScrollMode: String, Codable, CaseIterable {
    /// macOS's own: a slow notch barely moves, fast spins go further.
    case macOS
    /// Every notch the same distance.
    case fixed
    /// A single notch one distance, fast spins further, along a graph.
    case curve
}

/// The graph's shape, for `ScrollMode.curve`.
enum ScrollCurve: String, Codable, CaseIterable {
    /// Evenly, from the first quick notches.
    case linear
    /// Little for a gentle pace, then more and more, as macOS's does.
    case curve
}

/// Per-mouse settings. Every field defaults to "macOS", meaning the toolkit leaves
/// that behaviour to System Settings.
/// One of a mouse's buttons: one macOS numbers from 0 (the left button), or
/// one the mouse keeps to itself (a DPI switch) and reports only through its
/// HID++ channel, by control ID, once it's told to.
enum MouseButtonID: Hashable, Codable {
    case number(Int)
    case control(UInt16)

    /// As a single string in the file, `button:4` or `control:00FD`.
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text.hasPrefix("button:"), let n = Int(text.dropFirst(7)), (2...31).contains(n) {
            self = .number(n)
        } else if text.hasPrefix("control:"), let cid = UInt16(text.dropFirst(8), radix: 16) {
            self = .control(cid)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown button \(text)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode("button:\(n)")
        case .control(let cid): try c.encode(String(format: "control:%04X", cid))
        }
    }
}

/// What a button does instead of what macOS makes of it.
enum ButtonAction: String, Codable, CaseIterable {
    case nothing, floatingDock, back, forward, missionControl, showDesktop, shortcut, openApp
}

struct ButtonAssignment: Codable, Equatable, Identifiable {
    var button: MouseButtonID
    var action: ButtonAction
    /// For `.shortcut`: the keys it presses.
    var shortcut: Shortcut = .none
    /// For `.openApp`: the app, and its name to show while it's not there.
    var appPath: String?
    var appName: String?
    var id: MouseButtonID { button }

    init(button: MouseButtonID, action: ButtonAction) {
        self.button = button
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = try c.decode(MouseButtonID.self, forKey: .button)
        // An action from a later version does nothing here rather than lose the row.
        action = (try? c.decodeIfPresent(ButtonAction.self, forKey: .action)) ?? .nothing
        shortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .shortcut)) ?? .none
        appPath = try? c.decodeIfPresent(String.self, forKey: .appPath)
        appName = try? c.decodeIfPresent(String.self, forKey: .appName)
    }
}

struct Profile: Codable, Equatable {
    /// What macOS calls the mouse.
    var name: String
    /// A name given to it in the toolkit, over `name`.
    var label: String?
    /// How it was connected, and the end of its address, to show while it's away.
    var transport: String?
    var shortUnit: String?

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
    /// How far a notch scrolls, and the one setting for it each way.
    var scrollMode: ScrollMode = .macOS
    /// For macOS: a multiplier on what macOS gives (1 is macOS's own).
    var scrollSpeed: Double = 1.0
    /// For Fixed: lines a notch, whole.
    var scrollLines: Double = 3
    static let scrollLinesRange: ClosedRange<Double> = 1...15
    /// For Curve: lines a single notch scrolls, and a fast spin
    /// (`WheelEngine.further`), each within `scrollCurveRange`.
    var scrollCurveStart: Double = 3
    var scrollCurveEnd: Double = 6
    static let scrollCurveRange: ClosedRange<Double> = 0.5...12
    var scrollCurve: ScrollCurve = .linear
    /// For a curve, how late it rises: the power of the pace (1 is a line).
    var scrollCurveBend: Double = 2
    var smoothScrolling = false

    // Buttons
    /// Turns the side buttons into back/forward navigation in Apple's apps.
    var navigationButtons = false
    /// Which buttons those are, as macOS numbers them from 0 (the left
    /// button): 3 and 4 on most mice, the fourth and fifth buttons.
    var backButton = 3
    var forwardButton = 4
    static let sideButtons: ClosedRange<Int> = 3...31
    /// Holding the wheel button and moving the mouse scrolls, faster the
    /// farther it moves.
    var autoscroll = false
    /// Multiplier on the autoscroll speed, 1 for a pace that can be read
    /// as it goes (`Autoscroller.pace`).
    var autoscrollPace = 1.0
    static let autoscrollPaceRange: ClosedRange<Double> = 0.25...4
    /// Buttons given an action of their own, which wins over Navigate and
    /// Autoscroll for that button.
    var buttonActions: [ButtonAssignment] = []

    func assignment(for button: MouseButtonID) -> ButtonAssignment? {
        buttonActions.first { $0.button == button }
    }

    /// The control IDs to take from the mouse through its HID++ channel.
    var divertedControls: Set<UInt16> {
        Set(buttonActions.compactMap { if case .control(let cid) = $0.button { return cid } else { return nil } })
    }

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mouse"
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        transport = try? c.decodeIfPresent(String.self, forKey: .transport)
        shortUnit = try? c.decodeIfPresent(String.self, forKey: .shortUnit)
        cursorSpeedMode = try c.decodeIfPresent(ValueMode.self, forKey: .cursorSpeedMode) ?? .macOS
        // Kept to what the sliders offer: a value from a file edited by hand
        // or another version reaches the mouse's own settings.
        func within(_ value: Double?, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard let value, value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        cursorSpeed = within(try c.decodeIfPresent(Double.self, forKey: .cursorSpeed), 0.2...3, 1.0)
        accelMode = try c.decodeIfPresent(AccelMode.self, forKey: .accelMode) ?? .macOS
        accel = within(try c.decodeIfPresent(Double.self, forKey: .accel), 0...3, 0.6875)
        verticalInverted = try c.decodeIfPresent(Bool.self, forKey: .verticalInverted) ?? false
        horizontalInverted = try c.decodeIfPresent(Bool.self, forKey: .horizontalInverted) ?? false
        scrollSpeed = within(try c.decodeIfPresent(Double.self, forKey: .scrollSpeed), 0.25...5, 1.0)
        if let mode = try? c.decodeIfPresent(ScrollMode.self, forKey: .scrollMode) {
            scrollMode = mode
            scrollLines = within(try c.decodeIfPresent(Double.self, forKey: .scrollLines), Self.scrollLinesRange, 3).rounded()
            scrollCurveStart = within(try c.decodeIfPresent(Double.self, forKey: .scrollCurveStart), Self.scrollCurveRange, 3)
            scrollCurveEnd = within(try c.decodeIfPresent(Double.self, forKey: .scrollCurveEnd), Self.scrollCurveRange, 6)
        } else {
            try migrate(from: decoder.container(keyedBy: LegacyKeys.self), within: within)
        }
        scrollCurveEnd = max(scrollCurveEnd, scrollCurveStart)
        scrollCurve = (try? c.decodeIfPresent(ScrollCurve.self, forKey: .scrollCurve)) ?? .linear
        scrollCurveBend = within(try c.decodeIfPresent(Double.self, forKey: .scrollCurveBend), 1...4, 2)
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? false
        navigationButtons = try c.decodeIfPresent(Bool.self, forKey: .navigationButtons) ?? false
        let back = try c.decodeIfPresent(Int.self, forKey: .backButton) ?? 3
        let forward = try c.decodeIfPresent(Int.self, forKey: .forwardButton) ?? 4
        // Two different buttons past the wheel button (2); else the defaults.
        if Self.sideButtons.contains(back), Self.sideButtons.contains(forward), back != forward {
            (backButton, forwardButton) = (back, forward)
        }
        autoscroll = try c.decodeIfPresent(Bool.self, forKey: .autoscroll) ?? false
        if let pace = try c.decodeIfPresent(Double.self, forKey: .autoscrollPace) {
            autoscrollPace = within(pace, Self.autoscrollPaceRange, 1.0)
        } else if let speed = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Double.self, forKey: .autoscrollSpeed),
                  speed.isFinite, speed != 1 {
            // Before 0.18.3, 1 was four times as fast, too fast to read by: one
            // picked by hand stays as fast; the 1 nobody changed is the new 1.
            autoscrollPace = within(speed * 4, Self.autoscrollPaceRange, 1.0)
        }
        // One row a button, the first kept; a row whose button can't be read is left out.
        var seen = Set<MouseButtonID>()
        buttonActions = ((try? c.decodeIfPresent([LossyAssignment].self, forKey: .buttonActions)) ?? [])
            .compactMap(\.value).filter { seen.insert($0.button).inserted }
    }

    private struct LossyAssignment: Decodable {
        let value: ButtonAssignment?
        init(from decoder: Decoder) throws { value = try? ButtonAssignment(from: decoder) }
    }

    /// Before one setting for the distance, a speed and an acceleration, each
    /// macOS's or the toolkit's: the same distances, in the new setting.
    private mutating func migrate(from c: KeyedDecodingContainer<LegacyKeys>,
                                  within: (Double?, ClosedRange<Double>, Double) -> Double) throws {
        let speed = (try? c.decodeIfPresent(ValueMode.self, forKey: .scrollSpeedMode)) == .custom ? scrollSpeed : 1
        switch (try? c.decodeIfPresent(AccelMode.self, forKey: .scrollAccelMode)) ?? .macOS {
        case .macOS:
            scrollMode = .macOS
            scrollSpeed = speed
        case .off:
            // Three lines a notch, times the speed.
            scrollMode = .fixed
            scrollLines = within((3 * speed).rounded(), Self.scrollLinesRange, 3)
        case .custom:
            // Times three lines and the speed, from the notch to a fast spin;
            // before that, a strength on macOS's own slider's scale (0 to 1.7).
            scrollMode = .curve
            let start = try c.decodeIfPresent(Double.self, forKey: .scrollAccelStart) ?? 1
            let strength = try c.decodeIfPresent(Double.self, forKey: .scrollAccel) ?? 0.3125
            let end = try c.decodeIfPresent(Double.self, forKey: .scrollAccelEnd) ?? 1 + strength / 1.7 * 3
            scrollCurveStart = within(3 * speed * start, Self.scrollCurveRange, 3)
            scrollCurveEnd = within(3 * speed * end, Self.scrollCurveRange, 6)
        }
    }

    private enum LegacyKeys: String, CodingKey {
        case scrollSpeedMode, scrollAccelMode, scrollAccel, scrollAccelStart, scrollAccelEnd, autoscrollSpeed
    }

    /// True when any setting needs the event tap (and so Accessibility).
    var needsEventTap: Bool {
        rewritesWheelEvents || navigationButtons || autoscroll
            || buttonActions.contains { if case .number = $0.button { return true } else { return false } }
    }

    var rewritesWheelEvents: Bool {
        verticalInverted || horizontalInverted || smoothScrolling
            || (scrollMode == .macOS && scrollSpeed != 1.0)
            // A notch made a set distance, or one along the graph.
            || scrollMode != .macOS
    }

    var isAllMacOS: Bool {
        cursorSpeedMode == .macOS && accelMode == .macOS && scrollMode == .macOS && scrollSpeed == 1
            && !verticalInverted && !horizontalInverted && !smoothScrolling && !navigationButtons
            && !autoscroll && buttonActions.isEmpty
    }

    /// Every setting back to macOS; which mouse it is, and its name, stay.
    mutating func resetToMacOS() {
        var reset = Profile(name: name)
        reset.label = label
        reset.transport = transport
        reset.shortUnit = shortUnit
        self = reset
    }

    /// Every setting from `other`; which mouse this is, and its name, stay.
    mutating func takeSettings(of other: Profile) {
        var copy = other
        copy.name = name
        copy.label = label
        copy.transport = transport
        copy.shortUnit = shortUnit
        self = copy
    }
}

struct MouseConfig: Codable, Equatable {
    /// When off, every mouse is left to macOS, whatever its profile says.
    var enabled = true
    /// A part in the menu bar, whose panel lists the mice and their charge.
    var menuBarIcon = false
    /// Keyed by `MouseIdentity.key`: "unit:" and the mouse's address or serial
    /// number, or vendor:product:transport for a mouse with neither.
    var profiles: [String: Profile] = [:]
    var restoreOnQuit = true
    var showAllPointingDevices = false
    /// Apps that get the wheel button unchanged, for every mouse, by bundle ID
    /// with their names.
    var autoscrollExcluded: [String: String] = [:]
    /// Held while pressing the wheel button, the app gets the button itself.
    var autoscrollBypass = ModifierKey.option

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        menuBarIcon = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarIcon)) ?? false
        profiles = try c.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
        restoreOnQuit = try c.decodeIfPresent(Bool.self, forKey: .restoreOnQuit) ?? true
        showAllPointingDevices = try c.decodeIfPresent(Bool.self, forKey: .showAllPointingDevices) ?? false
        autoscrollExcluded = (try? c.decodeIfPresent([String: String].self, forKey: .autoscrollExcluded)) ?? [:]
        autoscrollBypass = (try? c.decodeIfPresent(ModifierKey.self, forKey: .autoscrollBypass)) ?? .option
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOS Toolkit", isDirectory: true)
        return dir.appendingPathComponent("mouse.json")
    }

    static func load() -> MouseConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            let config = MouseConfig.firstRun
            config.save()
            return config
        }
        return (try? JSONDecoder().decode(MouseConfig.self, from: data)) ?? MouseConfig()
    }

    func save() {
        let url = MouseConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Seeds the MX Anywhere 2S (Bluetooth) with the cursor values carried over
    /// from the previous setup: tracking speed 0.685 at native CPI.
    private static var firstRun: MouseConfig {
        var config = MouseConfig()
        var profile = Profile(name: "MX Anywhere 2S")
        profile.accelMode = .custom
        profile.accel = 0.685
        profile.cursorSpeedMode = .custom
        profile.cursorSpeed = 1.0
        config.profiles["1133:45082:Bluetooth Low Energy"] = profile
        return config
    }
}
