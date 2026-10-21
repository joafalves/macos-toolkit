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
}
