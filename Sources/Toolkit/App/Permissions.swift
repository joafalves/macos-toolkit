import AppKit
import AVFoundation

/// A permission macOS keeps for the app, which some tools need.
enum Permission: String, CaseIterable, Identifiable {
    // Not Input Monitoring: macOS gives it with Accessibility and lets no app
    // ask for it without, and telling mice apart is only for the wheel and
    // buttons, which need Accessibility anyway.
    case accessibility, screenRecording, systemAudio, microphone

    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility: return String(localized: "Accessibility")
        case .screenRecording: return String(localized: "Screen Recording")
        case .systemAudio: return String(localized: "System Audio Recording")
        case .microphone: return String(localized: "Microphone")
        }
    }

    /// Its name for `tccutil`.
    fileprivate var service: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "ScreenCapture"
        case .systemAudio: return "AudioCapture"
        case .microphone: return "Microphone"
        }
    }

    /// Its list in System Settings, under Privacy & Security.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .systemAudio: pane = "Privacy_AudioCapture"
        case .microphone: pane = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// A permission a tool needs, and what for, in a few words. A `required`
/// one is what the tool is for: its settings stay locked until it's
/// granted. Any other is for one feature, which says so on its own.
struct PermissionNeed: Identifiable {
    let permission: Permission
    let reason: String
    let required: Bool
    var id: Permission { permission }

    static func required(_ permission: Permission, _ reason: String) -> PermissionNeed {
        PermissionNeed(permission: permission, reason: reason, required: true)
    }

    static func optional(_ permission: Permission, _ reason: String) -> PermissionNeed {
        PermissionNeed(permission: permission, reason: reason, required: false)
    }
}

/// Each permission as macOS has it now. macOS sends no notice when one
/// changes, so they're read again when the app comes to the front, and every
/// second while a permissions sheet is open (`watch`).
final class Permissions: ObservableObject {
    /// A tool that isn't working for another reason than a permission, with why:
    /// the sidebar gives it the same warning.
    @Published var toolWarnings: [AppSection: String] = [:]

    /// `needsRestart`: turned on in System Settings, but macOS only lets
    /// this process use it once it starts again (Screen Recording).
    enum State: Equatable { case granted, denied, notAsked, needsRestart }

    static let shared = Permissions()

    @Published private(set) var states: [Permission: State] = [:]
    /// For `--snapshot`: states made up, nothing read from this Mac.
    private var fixed = false
    private var timer: Timer?
    private var watchers = 0
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func state(_ permission: Permission) -> State { states[permission] ?? .notAsked }
    func isGranted(_ permission: Permission) -> Bool { state(permission) == .granted }

    /// Whether a tool has every permission it can't work without.
    func ready(_ needs: [PermissionNeed]) -> Bool {
        needs.allSatisfy { !$0.required || isGranted($0.permission) }
    }

    func refresh() {
        guard !fixed else { return }
        var now: [Permission: State] = [:]
        for permission in Permission.allCases { now[permission] = Self.read(permission) }
        if now != states {
            states = now
        } else if watchers > 0 {
            // The tools' own restart checks aren't published here.
            objectWillChange.send()
        }
    }

    /// Only while something shows the states as they change.
    func watch(_ on: Bool) {
        watchers += on ? 1 : -1
        if watchers > 0, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        } else if watchers <= 0 {
            watchers = 0
            timer?.invalidate()
            timer = nil
        }
    }

    /// Accessibility can't tell refused from never asked, and needs not: its
    /// prompt puts the app in System Settings' list either way, with a button
    /// to it. Screen Recording's comes from TCC's own record.
    private static func read(_ permission: Permission) -> State {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notAsked
        case .screenRecording:
            // macOS answers for this process as it was when it started; TCC's
            // record says when it has been turned on since.
            if CGPreflightScreenCaptureAccess() { return .granted }
            switch tccPreflight("kTCCServiceScreenCapture") {
            case 0: return .needsRestart
            case 1: return .denied
            default: return .notAsked
            }
        case .systemAudio:
            switch AudioPermission.status {
            case .granted: return .granted
            case .denied: return .denied
            case .unknown: return .notAsked
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        }
    }

    /// Always asks macOS first: that's what puts the app (back) in System
    /// Settings' list, after a refusal or a revoke, and shows macOS's prompt
    /// while it has one to show. Once the answer was no, macOS asks nothing,
    /// so the list opens too, with the app in it to turn on.
    func request(_ permission: Permission) {
        let refused = state(permission) == .denied
            // Without TCC's record, an unanswered one can't be told apart.
            || (permission == .screenRecording && Self.tccPreflight("kTCCServiceScreenCapture") == nil)
        let done: (Bool) -> Void = { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        switch permission {
        case .accessibility:
            // macOS's prompt has a button to the list in System Settings.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .systemAudio:
            AudioPermission.request(done)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: done)
        }
        if refused { NSWorkspace.shared.open(permission.settingsURL) }
        refresh()
    }

    /// Takes a permission back with `tccutil`, which leaves it as before macOS
    /// asked, then restarts, so no tap or capture keeps what it had. Where
    /// macOS doesn't let it, says where the switch is.
    func revoke(_ permission: Permission) {
        let ask = NSAlert()
        ask.messageText = String(localized: "Revoke \(permission.title)?")
        ask.informativeText = String(localized: "The tools that use it stop working until it's granted again. MacOS Toolkit restarts to let go of it.")
        ask.addButton(withTitle: String(localized: "Revoke and Restart"))
        ask.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        if Self.reset(permission.service) { return Relaunch.now() }

        let manual = NSAlert()
        manual.messageText = String(localized: "macOS didn't revoke it.")
        manual.informativeText = String(localized: "Turn off MacOS Toolkit in System Settings, under Privacy & Security → \(permission.title).")
        manual.addButton(withTitle: String(localized: "Open System Settings"))
        manual.addButton(withTitle: String(localized: "Cancel"))
        if manual.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(permission.settingsURL) }
    }

    /// Every permission at once, as `revoke` does one.
    func revokeAll() {
        let ask = NSAlert()
        ask.messageText = String(localized: "Revoke every permission?")
        ask.informativeText = String(localized: "Every tool that needs one stops working until it's granted again, and macOS asks for each one again. MacOS Toolkit restarts to let go of them.")
        ask.addButton(withTitle: String(localized: "Revoke All and Restart"))
        ask.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        if Self.reset("All") { return Relaunch.now() }

        let manual = NSAlert()
        manual.messageText = String(localized: "macOS didn't revoke them.")
        manual.informativeText = String(localized: "Turn off MacOS Toolkit in each list in System Settings, under Privacy & Security.")
        manual.addButton(withTitle: String(localized: "Open System Settings"))
        manual.addButton(withTitle: String(localized: "Cancel"))
        if manual.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int

    /// TCC's record for this app: 0 granted, 1 denied, other not asked.
    private static func tccPreflight(_ service: String) -> Int? {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunc.self)(service as CFString, nil)
    }

    /// `tccutil reset` for this app: as if macOS had never asked.
    private static func reset(_ service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "dev.jalves.macos-toolkit"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// For `--snapshot`: every permission granted but these.
    func preview(missing: [Permission: State] = [:]) {
        fixed = true
        var states: [Permission: State] = [:]
        for permission in Permission.allCases { states[permission] = missing[permission] ?? .granted }
        self.states = states
    }
}

// MARK: - What each tool needs

// With the tool's settings as they are, whether it's on or not: the sheet
// asks as it's turned on, and Overview counts the tools that are on. Which
// are required is each tool's call: Mouse's cursor settings, Finder's
// right-click menu and Keep Awake work without any.

extension MouseController {
    var permissionNeeds: [PermissionNeed] {
        [.optional(.accessibility, String(localized: "For the wheel and button settings."))]
    }
}

extension SwitcherController {
    var permissionNeeds: [PermissionNeed] {
        var needs: [PermissionNeed] = [.required(.accessibility, String(localized: "To take its shortcut and see your windows."))]
        if config.style == .previews {
            needs.append(.optional(.screenRecording, String(localized: "For the pictures of windows in the grid.")))
        }
        return needs
    }
}

extension LayoutController {
    var permissionNeeds: [PermissionNeed] {
        var needs: [PermissionNeed] = [.required(.accessibility, String(localized: "To move windows and notice them being dragged."))]
        if config.suggest == .previews {
            needs.append(.optional(.screenRecording, String(localized: "For the pictures of the windows it suggests.")))
        }
        return needs
    }
}

extension MixerController {
    var permissionNeeds: [PermissionNeed] {
        // Through the audio driver nothing records, and waiting for its update nothing plays through us.
        var needs: [PermissionNeed] = driverActive || driverBlocked ? [] : [.required(.systemAudio, String(localized: "To change the volume of each app."))]
        needs.append(.optional(.accessibility, String(localized: "For the volume keys.")))
        return needs
    }
}

extension FinderController {
    var permissionNeeds: [PermissionNeed] {
        guard config.cut || config.swipe else { return [] }
        return [.optional(.accessibility, String(localized: "For Cut and for swiping back and forward."))]
    }
}

extension CaptureController {
    var permissionNeeds: [PermissionNeed] {
        var needs: [PermissionNeed] = [.required(.screenRecording, String(localized: "To take screenshots and recordings."))]
        if config.microphone {
            needs.append(.optional(.microphone, String(localized: "To record your voice.")))
        }
        if config.windowStyle == .content {
            needs.append(.optional(.accessibility, String(localized: "To find where a window's title bar ends, for Content Only.")))
        }
        return needs
    }
}

extension AwakeController {
    var permissionNeeds: [PermissionNeed] {
        config.stayAvailable ? [.optional(.accessibility, String(localized: "For Stay available."))] : []
    }
}
