import AppKit
import UserNotifications

/// Keep my choices, the one thing Tweaks remembers, and only when asked to: a
/// macOS update can turn a setting back to its default, and with this on, what
/// was changed here is put back when the app starts and when the Mac wakes. An
/// update means a restart, so nothing has to watch in between. What it remembers
/// is on this Mac only: not in the settings export, and gone when it's turned off.
final class TweaksKeeper {
    static let shared = TweaksKeeper()
    /// Something was put back, for a page that's open.
    static let putBack = Notification.Name("dev.jalves.macos-toolkit.tweaks-put-back")

    private static let key = "tweaksKept"
    private let queue = DispatchQueue(label: "dev.jalves.macos-toolkit.tweaks-keeper")
    private var observers: [NSObjectProtocol] = []

    var isOn: Bool { UserDefaults.standard.dictionary(forKey: Self.key) != nil }

    private var kept: [Tweak: Bool] {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: saved.compactMap { name, value in Tweak(rawValue: name).map { ($0, value) } })
    }

    private func save(_ kept: [Tweak: Bool]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: kept.map { ($0.rawValue, $1) }), forKey: Self.key)
    }

    /// At launch. Costs a look at a default when it's off.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.apply() })
        }
        apply()
    }

    /// From the page, with the tweaks as they are now.
    func turnOn(states: [Tweak: Bool]) {
        save(states.filter { $0.value != $0.key.macOSDefault })
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func turnOff() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// A switch moved on the page: that's the choice now. Back at macOS's default,
    /// there's nothing to keep.
    func chose(_ tweak: Tweak, _ value: Bool) {
        guard isOn else { return }
        var kept = kept
        kept[tweak] = value == tweak.macOSDefault ? nil : value
        save(kept)
    }

    /// What's kept that isn't what's set now.
    static func differences(kept: [Tweak: Bool], states: [Tweak: Bool]) -> [Tweak: Bool] {
        kept.filter { states[$0.key] != $0.value }
    }

    private func apply() {
        guard isOn else { return }
        let kept = kept
        queue.async {
            let different = Self.differences(kept: kept, states: TweaksModel.read())
            guard !different.isEmpty else { return }
            for (tweak, value) in different { TweaksModel.write(tweak, value) }
            // Only what took: one macOS refuses isn't news at every launch.
            let states = TweaksModel.read()
            let back = different.keys.filter { states[$0] == different[$0] }
            let refused = different.keys.filter { states[$0] != different[$0] }
            Log.app.notice("tweaks: put back \(back.map(\.rawValue).sorted(), privacy: .public), refused \(refused.map(\.rawValue).sorted(), privacy: .public)")
            guard !back.isEmpty else { return }
            if back.contains(where: { $0.restart == .dock }) { TweaksModel.run("/usr/bin/killall", ["Dock"]) }
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.putBack, object: nil) }
            guard Bundle.main.bundleIdentifier != nil else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Your Tweaks are back as you set them")
            content.body = String(localized: "macOS had changed some of them. A background task that's running stops at the next restart.")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "tweaks-put-back", content: content, trigger: nil))
        }
    }
}
