import AppKit

/// `--test-wheel <report>`: one notch of scroll in, as a mouse sends it, and
/// what comes out after the installed toolkit's wheel tap. With a profile
/// that changes the wheel, the notch itself must not come out, only what the
/// toolkit makes of it. It scrolls whatever is under the pointer by a line.
enum WheelProbe {
    static func run(into path: String) {
        let seen = Locked<[(user: Int64, points: Int64)]>([])
        let tap = EventTap(name: "test-wheel", events: [.scrollWheel], place: .tailAppendEventTap, listenOnly: true) { _, event in
            seen.update { $0.append((event.getIntegerValueField(.eventSourceUserData), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))) }
            return Unmanaged.passUnretained(event)
        }
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0) {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            event.post(tap: .cgSessionEventTap)
        }
        Thread.sleep(forTimeInterval: 1.5)
        tap?.stop()
        let events = seen.value
        let original = events.filter { $0.user == 0 }
        let made = events.filter { $0.user != 0 }
        let report = """
        the notch itself came out: \(original.count) time(s)
        made by the toolkit: \(made.count) event(s), \(made.reduce(0) { $0 + $1.points }) points
        (a notch is about 10 points; with smoothing on, only the toolkit's events should come out)

        """
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `--log-wheel <file> [seconds]`: every scroll event for a while, as
    /// macOS hands it to the taps (its acceleration already in) and as apps
    /// get it after the toolkit's: what a real notch of a real mouse becomes,
    /// which a posted one can't show. Run the app bundle with `open -n`.
    static func log(into path: String, seconds: Double) {
        let start = ProcessInfo.processInfo.systemUptime
        let lines = Locked<[String]>([])
        func describe(_ where: String, _ event: CGEvent) -> String {
            let ours = event.getIntegerValueField(.eventSourceUserData) == WheelEngine.marker
            return String(format: "%7.3f %@ %@ continuous=%lld lines=%lld fixed=%.3f points=%lld phase=%lld momentum=%lld",
                          ProcessInfo.processInfo.systemUptime - start, `where`, ours ? "toolkit" : "mouse  ",
                          event.getIntegerValueField(.scrollWheelEventIsContinuous),
                          event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                          event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                          event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                          event.getIntegerValueField(.scrollWheelEventScrollPhase),
                          event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        }
        // Made after the toolkit's own tap, so first in line at the head.
        let before = EventTap(name: "log-wheel-in", events: [.scrollWheel], listenOnly: true) { _, event in
            lines.update { $0.append(describe("in ", event)) }
            return Unmanaged.passUnretained(event)
        }
        let after = EventTap(name: "log-wheel-out", events: [.scrollWheel], place: .tailAppendEventTap, listenOnly: true) { _, event in
            lines.update { $0.append(describe("out", event)) }
            return Unmanaged.passUnretained(event)
        }
        Thread.sleep(forTimeInterval: seconds)
        before?.stop()
        after?.stop()
        let report = (before == nil || after == nil ? "a tap couldn't start: Accessibility?\n" : "") + lines.value.joined(separator: "\n") + "\n"
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
