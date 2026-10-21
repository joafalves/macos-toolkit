import AppKit
import IOKit.pwr_mgt

extension AwakeController {
    /// `--test-awake <report>`: a session holds the right power assertion and
    /// lets go of it, the time left reads right, the battery can be read, the
    /// lid rule passes visudo, and one mouse drift lands where it should. Run
    /// the app bundle with `open -n`, so Accessibility is the app's own;
    /// sessions here aren't saved, so the app's own is left alone.
    static func selfTest(into path: String) {
        freopen(path, "w", stdout)
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }

        // Ours, by type, from macOS's own list for this process.
        func assertions() -> [String] {
            var list: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&list) == kIOReturnSuccess,
                  let all = list?.takeRetainedValue() as? [Int: [[String: Any]]] else { return [] }
            return (all[Int(getpid())] ?? []).filter { $0[kIOPMAssertionNameKey] as? String == "Keep Awake in MacOS Toolkit" }
                .compactMap { $0[kIOPMAssertionTypeKey] as? String }
        }

        let awake = AwakeController()
        awake.persists = false
        awake.config = AwakeConfig()
        check(assertions().isEmpty, "off: no assertion")
        awake.turnOn(for: 90 * 60)
        check(assertions() == [kIOPMAssertionTypePreventUserIdleDisplaySleep], "on: keeps the display awake (\(assertions()))")
        awake.config.keepDisplayOn = false
        check(assertions() == [kIOPMAssertionTypePreventUserIdleSystemSleep], "display may sleep: only the system (\(assertions()))")
        awake.config.stayAvailable = true
        check(assertions() == [kIOPMAssertionTypePreventUserIdleDisplaySleep], "stay available holds the display on (\(assertions()))")
        awake.config.stayAvailable = false
        check(assertions() == [kIOPMAssertionTypePreventUserIdleSystemSleep], "and gives it back after (\(assertions()))")
        check(awake.status.hasPrefix("On until") && awake.status.hasSuffix("1:30 left"), "status: \(awake.status)")
        awake.turnOff()
        check(assertions().isEmpty, "turned off: no assertion")
        awake.turnOn(for: nil)
        awake.config.enabled = false
        check(assertions().isEmpty && awake.session == nil, "tool off: the session ends")
        awake.stop()

        check(left(84 * 60) == "1:24" && left(5 * 60 - 10) == "0:05" && left(1) == "0:01" && left(0) == "0:00", "time left: \(left(84 * 60)), \(left(5 * 60 - 10)), \(left(1))")
        let now = Date()
        let half = AwakeSession(started: now.addingTimeInterval(-600), until: now.addingTimeInterval(600))
        check(abs(half.fractionLeft(at: now) - 0.5) < 0.001 && AwakeSession(started: now, until: nil).fractionLeft() == 1, "fill: half way is half")

        if let battery = battery() {
            print("      battery: \(battery.percent)%, \(battery.charging ? "on power" : "on battery")")
            if !battery.charging, battery.percent < 95 {
                // A stop level above the charge: nothing starts, and the menu says why.
                let low = AwakeController()
                low.persists = false
                var config = AwakeConfig()
                config.batteryFloor = ((battery.percent / 10) + 1) * 10
                config.soundAtEnd = false
                low.config = config
                low.turnOn(for: 600)
                let titles = low.menuItems(openSettings: {}).map(\.title)
                check(low.batteryLow && low.session == nil && assertions().isEmpty, "below the stop level (\(config.batteryFloor)%): it won't start")
                check(titles.contains { $0.hasPrefix("The battery is below") }, "and its menu says why")
                low.config.batteryFloor = 0
                check(!low.batteryLow, "with Never, it can start again")
                low.stop()
            }
        } else {
            print("      no battery")
        }

        // visudo runs as anyone for a syntax check.
        if let rule = LidSleep.rule(for: NSUserName()) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-rule-\(getpid())")
            try? (rule + "\n").write(to: file, atomically: true, encoding: .utf8)
            let visudo = Process()
            visudo.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
            visudo.arguments = ["-cf", file.path]
            visudo.standardOutput = FileHandle.nullDevice
            visudo.standardError = FileHandle.nullDevice
            try? visudo.run()
            visudo.waitUntilExit()
            try? FileManager.default.removeItem(at: file)
            check(visudo.terminationStatus == 0, "lid rule passes visudo: \(rule)")
        }
        check(LidSleep.rule(for: "a b") == nil && LidSleep.rule(for: "x;rm") == nil, "lid rule refuses odd user names")

        // One drift, when the mouse is left alone for a moment.
        if AXIsProcessTrusted() {
            let quiet = Date().addingTimeInterval(30)
            while CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 2, Date() < quiet {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            let start = StayAvailable.pointer()
            let stay = StayAvailable()
            stay.startDrift()
            RunLoop.main.run(until: Date().addingTimeInterval(1.1))
            let end = StayAvailable.pointer()
            let distance = hypot(end.x - start.x, end.y - start.y)
            check(distance >= 70 && distance <= 320, String(format: "drift: %.0f pt, from (%.0f, %.0f) to (%.0f, %.0f)", distance, start.x, start.y, end.x, end.y))
        } else {
            print("      no Accessibility: drift not tried")
        }
        print(failures == 0 ? "all ok" : "\(failures) failed")
        fflush(stdout)
    }
}
