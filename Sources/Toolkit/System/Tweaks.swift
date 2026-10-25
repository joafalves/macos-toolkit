import AppKit

/// One of macOS's own settings that System Settings doesn't show. The Mac is
/// its only record: the page reads it each time it shows, and a switch writes
/// it straight to macOS, so nothing here is saved, exported or put back on
/// quit, and a change made elsewhere shows as it is.
enum Tweak: String, CaseIterable {
    case photosAnalysis, peopleAndMemories, gameCenter, tips
    case dockWithoutDelay, quickMissionControl, dimHiddenApps, onlyOpenApps, scrollForWindows
    case pathInTitle, hiddenFiles, extensionWarning, quitFinder, networkStores, usbStores
    case pressAndHold
    case expandedDialogs, saveToCloud, windowAnimations, crashDialog
    case photosOnConnect, offerTimeMachine

    /// How macOS keeps it.
    enum Kind {
        /// A launchd agent in the user's session, turned off for this user
        /// with `launchctl disable`: launchd keeps that across restarts.
        case service(String)
        case preference(Preference)
    }

    /// A preference with one value for on and one for off. One of the two is
    /// nil, the key deleted: that's macOS's default, and what a reset writes.
    struct Preference {
        /// Nil for the global domain.
        var domain: String?
        /// Written together; the first is the one read.
        var keys: [String]
        var on: Any?
        var off: Any?
        /// In the per-Mac preferences (`defaults -currentHost`).
        var currentHost = false
    }

    /// What has to start again for a change to show. macOS starts both again
    /// by itself, and Finder reopens its windows.
    enum Restart {
        case dock, finder
    }

    var kind: Kind {
        switch self {
        case .photosAnalysis: return .service("com.apple.mediaanalysisd")
        case .peopleAndMemories: return .service("com.apple.photoanalysisd")
        case .gameCenter: return .service("com.apple.gamed")
        case .tips: return .service("com.apple.tipsd")
        case .dockWithoutDelay: return .preference(.init(domain: "com.apple.dock", keys: ["autohide-delay"], on: 0.0))
        case .quickMissionControl: return .preference(.init(domain: "com.apple.dock", keys: ["expose-animation-duration"], on: 0.1))
        case .dimHiddenApps: return .preference(.init(domain: "com.apple.dock", keys: ["showhidden"], on: true))
        case .onlyOpenApps: return .preference(.init(domain: "com.apple.dock", keys: ["static-only"], on: true))
        case .scrollForWindows: return .preference(.init(domain: "com.apple.dock", keys: ["scroll-to-open"], on: true))
        case .pathInTitle: return .preference(.init(domain: "com.apple.finder", keys: ["_FXShowPosixPathInTitle"], on: true))
        case .hiddenFiles: return .preference(.init(domain: "com.apple.finder", keys: ["AppleShowAllFiles"], on: true))
        case .extensionWarning: return .preference(.init(domain: "com.apple.finder", keys: ["FXEnableExtensionChangeWarning"], off: false))
        case .quitFinder: return .preference(.init(domain: "com.apple.finder", keys: ["QuitMenuItem"], on: true))
        case .networkStores: return .preference(.init(domain: "com.apple.desktopservices", keys: ["DSDontWriteNetworkStores"], on: true))
        case .usbStores: return .preference(.init(domain: "com.apple.desktopservices", keys: ["DSDontWriteUSBStores"], on: true))
        case .pressAndHold: return .preference(.init(keys: ["ApplePressAndHoldEnabled"], off: false))
        case .expandedDialogs:
            return .preference(.init(keys: ["NSNavPanelExpandedStateForSaveMode", "NSNavPanelExpandedStateForSaveMode2",
                                            "PMPrintingExpandedStateForPrint", "PMPrintingExpandedStateForPrint2"], on: true))
        case .saveToCloud: return .preference(.init(keys: ["NSDocumentSaveNewDocumentsToCloud"], off: false))
        case .windowAnimations: return .preference(.init(keys: ["NSAutomaticWindowAnimationsEnabled"], off: false))
        case .crashDialog: return .preference(.init(domain: "com.apple.CrashReporter", keys: ["DialogType"], off: "none"))
        case .photosOnConnect: return .preference(.init(domain: "com.apple.ImageCapture", keys: ["disableHotPlug"], off: true, currentHost: true))
        case .offerTimeMachine: return .preference(.init(domain: "com.apple.TimeMachine", keys: ["DoNotOfferNewDisksForBackup"], off: true))
        }
    }

    var restart: Restart? {
        switch self {
        case .dockWithoutDelay, .quickMissionControl, .dimHiddenApps, .onlyOpenApps, .scrollForWindows: return .dock
        case .pathInTitle, .hiddenFiles, .extensionWarning, .quitFinder, .networkStores, .usbStores: return .finder
        default: return nil
        }
    }

    /// As macOS comes: every service runs, and a preference is at the value
    /// its key stands for when it isn't there.
    var macOSDefault: Bool {
        switch kind {
        case .service: return true
        case .preference(let preference): return preference.on == nil
        }
    }
}

extension Tweak.Preference {
    private var application: CFString { (domain ?? kCFPreferencesAnyApplication as String) as CFString }
    private var host: CFString { currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost }

    /// What's set now, through cfprefsd, as `defaults` reads it.
    func read() -> Bool {
        let value = CFPreferencesCopyValue(keys[0] as CFString, application, kCFPreferencesCurrentUser, host)
        if let on { return Self.same(value, on) }
        return !Self.same(value, off)
    }

    func write(_ isOn: Bool) {
        let value = isOn ? on : off
        for key in keys {
            CFPreferencesSetValue(key as CFString, value.map { $0 as CFPropertyList }, application, kCFPreferencesCurrentUser, host)
        }
        CFPreferencesSynchronize(application, kCFPreferencesCurrentUser, host)
    }

    /// Numbers by value, whichever type wrote them (`defaults` writes 0 as an
    /// integer, we write 0.0); anything else by equality.
    private static func same(_ value: Any?, _ target: Any?) -> Bool {
        guard let value, let target else { return value == nil && target == nil }
        if let a = value as? NSNumber, let b = target as? NSNumber { return a.doubleValue == b.doubleValue }
        if let a = value as? String, let b = target as? String { return a == b }
        return false
    }
}

/// The tweaks as the Mac has them now, for the page.
final class TweaksModel: ObservableObject {
    @Published private(set) var isOn: [Tweak: Bool] = [:]
    /// The last change macOS didn't keep: the switch went back to what's set.
    @Published var refused: Tweak?
    /// For `--snapshot`: macOS's defaults with two changed, nothing read.
    static var previewing = false
    private let isPreview = TweaksModel.previewing
    private let queue = DispatchQueue(label: "dev.jalves.macos-toolkit.tweaks")
    /// Apps waiting to restart, on `queue`: a few switches flipped in a row
    /// restart the Dock or Finder once, after the last.
    private var restarting: Set<Tweak.Restart> = []
    private var activation: NSObjectProtocol?

    init() {
        if isPreview {
            for tweak in Tweak.allCases { isOn[tweak] = tweak.macOSDefault }
            isOn[.dockWithoutDelay] = true
            isOn[.pathInTitle] = true
            return
        }
        // Read here, about 8 ms, so the page's first frame shows the Mac's
        // values rather than macOS's defaults turning into them.
        isOn = Self.read()
        // Back from System Settings or Terminal, it shows what's set now.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    func on(_ tweak: Tweak) -> Bool { isOn[tweak] ?? tweak.macOSDefault }

    func changed(_ tweak: Tweak) -> Bool { on(tweak) != tweak.macOSDefault }

    /// Reads every tweak off the main thread: `launchctl` takes a moment.
    func refresh() {
        guard !isPreview else { return }
        queue.async {
            let states = Self.read()
            DispatchQueue.main.async { self.isOn = states }
        }
    }

    func set(_ tweak: Tweak, _ value: Bool) {
        guard !isPreview else { isOn[tweak] = value; return }
        // At once, so the switch moves under the click; the read after says
        // whether macOS kept it.
        isOn[tweak] = value
        refused = nil
        queue.async {
            Self.write(tweak, value)
            if let app = tweak.restart, self.restarting.insert(app).inserted {
                self.queue.asyncAfter(deadline: .now() + 0.6) {
                    self.restarting.remove(app)
                    Self.run("/usr/bin/killall", [app == .dock ? "Dock" : "Finder"])
                }
            }
            let states = Self.read()
            DispatchQueue.main.async {
                self.isOn = states
                if states[tweak] != value { self.refused = tweak }
            }
        }
    }

    // MARK: - macOS

    static func read() -> [Tweak: Bool] {
        let disabled = disabledServices()
        var states: [Tweak: Bool] = [:]
        for tweak in Tweak.allCases {
            switch tweak.kind {
            case .service(let label): states[tweak] = !disabled.contains(label)
            case .preference(let preference): states[tweak] = preference.read()
            }
        }
        return states
    }

    private static func write(_ tweak: Tweak, _ value: Bool) {
        switch tweak.kind {
        case .service(let label):
            let target = "gui/\(getuid())/\(label)"
            if value {
                launchctl(["enable", target])
                // Started now rather than whenever it's next wanted.
                launchctl(["kickstart", target])
            } else {
                launchctl(["disable", target])
                // Disabled only stops it starting; the one running is stopped too.
                launchctl(["kill", "SIGTERM", target])
            }
        case .preference(let preference):
            preference.write(value)
        }
    }

    /// The labels launchd has disabled in the user's session.
    static func disabledServices() -> Set<String> {
        let output = launchctl(["print-disabled", "gui/\(getuid())"])
        var labels = Set<String>()
        // Lines like `"com.apple.Siri.agent" => disabled` (`=> true` before macOS 26).
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\"")
            guard parts.count >= 3 else { continue }
            let state = parts[2].trimmingCharacters(in: .whitespaces)
            if state.hasSuffix("disabled") || state.hasSuffix("true") { labels.insert(String(parts[1])) }
        }
        return labels
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> String {
        run("/bin/launchctl", arguments)
    }

    /// Its output. Through `posix_spawn`: `Process` took 75 ms to run
    /// `launchctl`, against 4 ms this way, which is the difference between
    /// reading as the page opens and a page that shows defaults first.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> String {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return "" }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, nil, argv, environ)
        close(fds[1])
        let output = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        guard spawned == 0 else { return "" }
        let data = output.readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return String(decoding: data, as: UTF8.self)
    }
}
