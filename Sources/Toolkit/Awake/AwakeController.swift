import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

/// Keeps the Mac awake for a while or until it's turned off: a power
/// assertion while a session is on, nothing at all while it's off. A timed
/// session wakes only when the minutes left change, and the battery is
/// watched through macOS's own power notifications, not a poll.
final class AwakeController: ObservableObject {
    @Published var config: AwakeConfig {
        didSet {
            guard config != oldValue else { return }
            if persists { config.save() }
            apply()
        }
    }

    @Published private(set) var session: AwakeSession?
    /// Goes up as the minutes left (or, with no end, on) change, for what the menu bar shows.
    @Published private(set) var minute = 0
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var shortcutFailed = false
    /// On battery below the stop level: a session can't start.
    @Published private(set) var batteryLow = false

    /// The lengths offered, grouped into minutes and hours.
    static let minutes = [5, 10, 15, 20, 30, 45, 50, 55]
    static let hours = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 24]

    static func title(minutes: Int) -> String { String(localized: "\(minutes) Minutes") }
    static func title(hours: Int) -> String { hours == 1 ? String(localized: "1 Hour") : String(localized: "\(hours) Hours") }

    enum Ending {
        case byHand, ranOut, battery(Int)
    }

    var persists = true
    private var isPreview = false
    private var assertion: IOPMAssertionID?
    private var assertionKeepsDisplay = false
    private var tick: Timer?
    private var power: CFRunLoopSource?
    private var stayParameters: (StayAvailableMethod, TimeInterval)?
    private let stay = StayAvailable()
    private let key = AwakeKey()
    private var observers: [NSObjectProtocol] = []

    init() {
        config = AwakeConfig.load()
    }

    static func preview() -> AwakeController {
        let awake = AwakeController()
        awake.persists = false
        awake.isPreview = true
        awake.config = AwakeConfig()
        awake.accessibility = true
        // A timed session part way through, for the page and the menu bar.
        let now = Date()
        awake.session = AwakeSession(started: now.addingTimeInterval(-36 * 60), until: now.addingTimeInterval(84 * 60))
        return awake
    }

    func start() {
        LidSleep.removeLeftovers()
        key.onPress = { [weak self] in self?.toggle() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ShortcutRecording.changed, object: nil, queue: .main) { [weak self] _ in
            self?.key.suspend(ShortcutRecording.active)
        })
        // A timer doesn't run while the Mac sleeps: the time may be up on waking.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        })
        // Coming back from System Settings, perhaps with Accessibility granted.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.accessibility = AXIsProcessTrusted()
        })
        session = AwakeSession.load()
        apply()
    }

    /// On quit: everything put back. The session itself is kept, to carry on
    /// at the next launch.
    func stop() {
        releaseAssertion()
        stay.stop()
        tick?.invalidate()
        tick = nil
        stopPowerWatch()
        key.set(nil)
    }

    var isOn: Bool { config.enabled && session != nil }

    // MARK: - Sessions

    func turnOn(for duration: TimeInterval?) {
        let now = Date()
        begin(AwakeSession(started: now, until: duration.map { now.addingTimeInterval($0) }))
    }

    func turnOn(until date: Date) {
        begin(AwakeSession(started: Date(), until: date))
    }

    func turnOff() {
        end(.byHand)
    }

    /// The shortcut: on with no end, or off.
    func toggle() {
        isOn ? turnOff() : turnOn(for: nil)
    }

    /// Why a session can't start now, if it can't.
    var cantStart: String? {
        batteryLow ? String(localized: "The battery is below \(config.batteryFloor)%. Charge it, or lower the stop level.") : nil
    }

    private func begin(_ session: AwakeSession) {
        checkBattery()
        // Only reachable by the shortcut: the menus don't offer it.
        guard !batteryLow else { return NSSound.beep() }
        if !config.enabled { config.enabled = true }
        self.session = session
        if persists { AwakeSession.store(session) }
        askToNotify()
        apply()
    }

    private func end(_ ending: Ending) {
        guard session != nil else { return }
        session = nil
        if persists { AwakeSession.store(nil) }
        apply()
        switch ending {
        case .byHand: break
        case .ranOut: notify("Its time is up.")
        case .battery(let percent): notify("The battery is at \(percent)%.")
        }
    }

    /// Puts everything in line with the settings and the session: the one
    /// place that turns things on and off.
    private func apply() {
        if config.enabled, let until = session?.until, until <= Date() { return end(.ranOut) }
        // Turning the tool off ends the session rather than holding it for later.
        if !config.enabled, session != nil {
            session = nil
            if persists { AwakeSession.store(nil) }
        }
        let on = isOn
        guard !isPreview else { return }

        if on { holdAssertion(keepingDisplay: config.displayStaysOn) } else { releaseAssertion() }

        // Off too, so the menus know whether a session can start.
        if config.enabled, config.batteryFloor > 0 { startPowerWatch() } else { stopPowerWatch() }

        let parameters = on && config.stayAvailable ? (config.stayAvailableMethod, config.stayAvailableEvery) : nil
        if parameters?.0 != stayParameters?.0 || parameters?.1 != stayParameters?.1 {
            stay.stop()
            if let parameters { stay.start(method: parameters.0, every: parameters.1) }
            stayParameters = parameters
        }

        key.set(config.enabled ? config.shortcut.active : nil)
        shortcutFailed = key.failed
        scheduleTick()
        checkBattery()
    }

    // MARK: - The assertion

    private func holdAssertion(keepingDisplay: Bool) {
        if assertion != nil, assertionKeepsDisplay == keepingDisplay { return }
        releaseAssertion()
        let type = keepingDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Keep Awake in MacOS Toolkit" as CFString, &id)
        guard status == kIOReturnSuccess else { return NSLog("Toolkit: Keep Awake assertion failed (\(status))") }
        assertion = id
        assertionKeepsDisplay = keepingDisplay
    }

    private func releaseAssertion() {
        guard let assertion else { return }
        IOPMAssertionRelease(assertion)
        self.assertion = nil
    }

    // MARK: - Time left

    /// At the next change of the minutes left, or the end. With no end, at
    /// the next minute it's been on, if that's shown.
    private func scheduleTick() {
        tick?.invalidate()
        tick = nil
        guard isOn, let session else { return }
        let step: TimeInterval
        if let until = session.until {
            step = until.timeIntervalSinceNow.truncatingRemainder(dividingBy: 60)
        } else if config.showElapsed {
            step = 60 - Date().timeIntervalSince(session.started).truncatingRemainder(dividingBy: 60)
        } else {
            return
        }
        let timer = Timer(timeInterval: max(0.5, step), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.minute += 1
            self.apply()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// Minutes left, rounded up: 1:24, or 0:05 under the hour.
    static func left(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// Minutes it's been on, whole ones: 0:00 for the first.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// What the menu bar shows beside the cup: the time left, or with no end
    /// and that turned on, how long it's been on. Nil for nothing.
    var menuBarTime: (text: String, widest: String)? {
        guard isOn, let session else { return nil }
        if let until = session.until {
            // As wide as the session's longest time, so it doesn't shift as it counts down.
            return (Self.left(until.timeIntervalSinceNow), Self.left(until.timeIntervalSince(session.started)))
        }
        guard config.showElapsed else { return nil }
        // Up to 99 hours without shifting as it counts up.
        return (Self.elapsed(Date().timeIntervalSince(session.started)), "88:88")
    }

    /// For the menu and the settings page.
    var status: String {
        guard isOn, let session else { return String(localized: "Off") }
        guard let until = session.until else {
            return config.showElapsed ? String(localized: "On until you turn it off, on for \(Self.elapsed(Date().timeIntervalSince(session.started)))")
                                      : String(localized: "On until you turn it off")
        }
        return String(localized: "On until \(until.formatted(date: Calendar.current.isDateInToday(until) ? .omitted : .abbreviated, time: .shortened)), \(Self.left(until.timeIntervalSinceNow)) left")
    }

    // MARK: - Battery

    private func startPowerWatch() {
        guard power == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let awake = Unmanaged<AwakeController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { awake.checkBattery() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        power = source
    }

    private func stopPowerWatch() {
        guard let power else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), power, .defaultMode)
        self.power = nil
    }

    /// On battery below the stop level, a session ends and none can start;
    /// charging never ends one.
    private func checkBattery() {
        var low = false
        var percent = 0
        if config.enabled, config.batteryFloor > 0, let battery = Self.battery(), !battery.charging {
            low = battery.percent < config.batteryFloor
            percent = battery.percent
        }
        if low != batteryLow { batteryLow = low }
        if low, isOn { end(.battery(percent)) }
    }

    static func battery() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (current * 100 / max, source != kIOPMBatteryPowerKey)
        }
        return nil
    }

    // MARK: - Notices

    /// Asked when a session starts, not when one ends unseen.
    private func askToNotify() {
        guard config.notifyAtEnd, persists, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ why: String.LocalizationValue) {
        if config.soundAtEnd { NSSound(named: "Glass")?.play() }
        guard config.notifyAtEnd, persists, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Keep Awake is off")
        content.body = String(localized: why)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "keep-awake-ended", content: content, trigger: nil))
    }

    /// A time today, or tomorrow if it has passed: from the settings page,
    /// whose window takes the keyboard.
    func askUntil() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Keep awake until")
        alert.informativeText = String(localized: "Today, or tomorrow if the time has passed.")
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        let soon = Date().addingTimeInterval(3600)
        let quarter = Calendar.current.dateInterval(of: .hour, for: soon)?.start ?? soon
        picker.dateValue = quarter.addingTimeInterval((soon.timeIntervalSince(quarter) / 900).rounded(.up) * 900)
        picker.sizeToFit()
        alert.accessoryView = picker
        alert.addButton(withTitle: String(localized: "Start"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        guard let next = Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime) else { return }
        turnOn(until: next)
    }
}
