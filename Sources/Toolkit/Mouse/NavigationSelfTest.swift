#if TOOLKIT_DEV
import AppKit

extension WheelEngine {
    /// `--test-navigation`: what Back and Forward do with each button in each
    /// kind of app, decided without posting anything; settings from before
    /// 0.28.0 read into the new ones; a notch's distance as apps get it; and,
    /// with Accessibility, Finder's Back and Forward menu items found, not pressed.
    static func navigationSelfTest() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print((ok ? "ok    " : "FAIL  ") + what)
        }
        func passes(_ action: ButtonAction, _ button: Int64, _ app: String?) -> Bool {
            ButtonActions.passesThrough(action, button: button, frontApp: app)
        }

        check(!passes(.back, 3, "com.apple.finder") && !passes(.forward, 4, "com.apple.Safari"), "Apple's apps ignore the buttons: Back and Forward are taken")
        check(passes(.back, 3, "com.example.browser") && passes(.forward, 4, "com.example.editor"), "another developer's app gets the button it already knows")
        check(passes(.back, 3, "dev.jalves.macos-toolkit"), "the toolkit's own window gets the button, and goes back itself")
        check(!passes(.back, 5, "com.example.browser") && !passes(.forward, 3, "com.example.browser"), "Back on another button, or Forward on the back button, is taken")
        check(!passes(.missionControl, 3, "com.example.browser"), "another action on the back button is taken")
        check(passes(.back, 3, nil), "no front app: the button goes through")
        check(ButtonAction.offered(for: .number(2)).contains(.autoscroll) && !ButtonAction.offered(for: .number(3)).contains(.autoscroll)
              && !ButtonAction.offered(for: .control(0x00FD)).contains(.autoscroll), "only the wheel button offers Autoscroll")

        func decoded(_ json: String) -> Profile? { try? JSONDecoder().decode(Profile.self, from: Data(json.utf8)) }
        func actions(_ profile: Profile?) -> [String] {
            (profile?.buttonActions ?? []).map { a in
                if case .number(let n) = a.button { return "\(n):\(a.action.rawValue)" }
                return a.action.rawValue
            }
        }
        // Navigate and Autoscroll before 0.28.0, now the buttons' actions.
        check(actions(decoded(#"{"name":"A","navigationButtons":true}"#)) == ["3:back", "4:forward"], "Navigate becomes Back and Forward on buttons 4 and 5")
        check(actions(decoded(#"{"name":"A","navigationButtons":true,"backButton":5,"forwardButton":6}"#)) == ["5:back", "6:forward"], "Navigate on chosen buttons keeps them")
        check(actions(decoded(#"{"name":"A","navigationButtons":true,"backButton":2,"forwardButton":4}"#)) == ["3:back", "4:forward"], "Navigate on the wheel button falls back to 4 and 5")
        check(actions(decoded(#"{"name":"A","navigationButtons":false,"backButton":5}"#)).isEmpty, "Navigate off adds nothing")
        check(actions(decoded(#"{"name":"A","autoscroll":true}"#)) == ["2:autoscroll"], "Autoscroll becomes the wheel button's action")
        check(actions(decoded(#"{"name":"A","navigationButtons":true,"buttonActions":[{"button":"button:3","action":"missionControl"}]}"#)) == ["3:missionControl", "4:forward"],
              "a button's own action still wins over Navigate")
        let migrated = decoded(#"{"name":"A","navigationButtons":true,"autoscroll":true}"#)
        check(migrated?.needsEventTap == true, "migrated buttons need the event tap")
        if let migrated, let data = try? JSONEncoder().encode(migrated) {
            let text = String(decoding: data, as: UTF8.self)
            check(!text.contains("navigationButtons") && !text.contains("\"autoscroll\":"), "the old switches aren't written again")
            check(actions(try? JSONDecoder().decode(Profile.self, from: data)) == actions(migrated), "migrated actions are read back the same")
        }

        // Distances: lines before 0.28.0, now points.
        let fixed = decoded(#"{"name":"A","scrollMode":"fixed","scrollLines":3}"#)
        check(fixed?.scrollDistance == 90, "3 lines, the old default, become 90 points, the new one")
        let curve = decoded(#"{"name":"A","scrollMode":"curve","scrollCurveStart":3.2,"scrollCurveEnd":4.7}"#)
        check(curve?.scrollCurveFrom == 95 && curve?.scrollCurveTo == 140, "a curve in lines becomes points in proportion, in fives")
        check(decoded(#"{"name":"A","scrollMode":"fixed","scrollDistance":80,"scrollLines":3}"#)?.scrollDistance == 80, "points, once saved, win over lines")
        check(decoded(#"{"name":"A","scrollMode":"fixed","scrollDistance":5000}"#)?.scrollDistance == 300, "a distance past the slider is kept to it")
        check(decoded(#"{"name":"A","scrollAccelMode":"off","scrollSpeedMode":"custom","scrollSpeed":2}"#).map { $0.scrollMode == .fixed && $0.scrollDistance == 180 } == true,
              "the oldest settings: macOS's curve off at twice the speed becomes 180 points")
        if let fixed, let data = try? JSONEncoder().encode(fixed) {
            check(!String(decoding: data, as: UTF8.self).contains("scrollLines"), "lines aren't written again")
        }

        // Picking a distance of the toolkit's turns smoothing on; a glide speed is read back.
        var picked = Profile(name: "A")
        picked.setScrollMode(.fixed)
        check(picked.smoothScrolling && picked.scrollDistance == 90, "picking Fixed starts at 90 points, smooth")
        picked.smoothScrolling = false
        picked.setScrollMode(.curve)
        check(!picked.smoothScrolling, "going from Fixed to Curve keeps smoothing as it was")
        check(decoded(#"{"name":"A","glide":"fast"}"#)?.glide == .fast && decoded(#"{"name":"A","glide":"later"}"#)?.glide == .normal,
              "a glide speed is read back, and one from a later version is Normal")

        // A notch as apps get it: a distance in points, the lines only as many as it's gone.
        let engine = WheelEngine()
        var got: [(lines: Int64, fixed: Double, points: Int64)] = []
        for points in [25.0, 25, 2.5, 2.5, 2.5, 2.5, -60] {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 1, wheel2: 0, wheel3: 0) else { continue }
            engine.setDistance(event, x: 0, y: points)
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1
            if !continuous { check(false, "a notch made a distance is continuous") }
            got.append((event.getIntegerValueField(.scrollWheelEventDeltaAxis1), event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                        event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)))
        }
        check(got.map(\.points) == [25, 25, 2, 3, 2, 3, -60], "points are whole, and what's left over goes with the next")
        check(got.map(\.lines) == [2, 3, 0, 0, 0, 1, -6], "lines are counted only as the distance goes, and a turn back starts afresh")
        check(got.first.map { abs($0.fixed - 2.5) < 0.001 } == true, "the share of lines is the points over ten, as macOS writes it")
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0) {
            let made = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            engine.setDistance(event, x: 0, y: 3)
            print("      macOS's own 3 px event says \(made) line; ours says \(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))")
        }

        if AXIsProcessTrusted(), let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            check(AppNavigation.backAndForward(in: finder.processIdentifier) != nil, "Finder's Back and Forward menu items are found by title")
        } else {
            print("      menu items: not checked (needs Accessibility: run the dev bundle with open -n)")
        }
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }
}
#endif
