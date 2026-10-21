import ApplicationServices
import CoreGraphics
import Foundation

/// `--test-nudge <report>`: which input, posted by the app, resets the idle
/// time chat apps read. Chromium (Slack, Teams) reads the combined session
/// state's time since any input. Waits for quiet moments, so leave the
/// mouse and keyboard alone while it runs. Run the app bundle with `open -n`.
enum AwakeProbe {
    static func run(into path: String) {
        freopen(path, "w", stdout)
        setvbuf(stdout, nil, _IOLBF, 0)
        print("accessibility: \(AXIsProcessTrusted()), may post events: \(CGPreflightPostEventAccess())")
        func idle() -> Double {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }
        func here() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
        func move(to point: CGPoint, tap: CGEventTapLocation, source: CGEventSource?) {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: tap)
        }
        let hid = CGEventSource(stateID: .hidSystemState)
        let variants: [(String, () -> Void)] = [
            ("move in place, hid tap", { move(to: here(), tap: .cghidEventTap, source: nil) }),
            ("move in place, hid tap, hid source", { move(to: here(), tap: .cghidEventTap, source: hid) }),
            ("move in place, session tap", { move(to: here(), tap: .cgSessionEventTap, source: nil) }),
            ("flags changed with no flags", {
                guard let key = CGEvent(keyboardEventSource: hid, virtualKey: 0x3F, keyDown: true) else { return }
                key.type = .flagsChanged
                key.flags = []
                key.post(tap: .cghidEventTap)
            }),
            ("1 pt and back", {
                let start = here()
                move(to: CGPoint(x: start.x + 1, y: start.y), tap: .cghidEventTap, source: hid)
                usleep(16_000)
                move(to: start, tap: .cghidEventTap, source: hid)
            }),
        ]
        for (name, post) in variants {
            while idle() < 4 { Thread.sleep(forTimeInterval: 0.5) }
            let before = idle(), start = here()
            post()
            Thread.sleep(forTimeInterval: 0.3)
            let after = idle()
            let moved = here() != start
            print(String(format: "%@: idle %.1f s -> %.1f s, %@%@", name, before, after,
                         after < 1 ? "RESET" : "no change", moved ? ", pointer moved" : ""))
        }
        fflush(stdout)
    }
}
