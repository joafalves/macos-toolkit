#if TOOLKIT_DEV
import AppKit

extension WheelEngine {
    /// `--test-navigation`: what Navigate does with each button in each kind
    /// of app, decided without posting anything; the buttons as saved; and,
    /// with Accessibility, Finder's Back and Forward menu items found, not pressed.
    static func navigationSelfTest() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print((ok ? "ok    " : "FAIL  ") + what)
        }
        func decide(_ button: Int64, _ app: String?, _ profile: Profile) -> String {
            guard let decision = navigation(button: button, profile: profile, frontApp: app) else { return "unchanged" }
            return (decision.back ? "back" : "forward") + " by " + (decision.method == .swipe ? "swipe" : "menu")
        }

        var profile = Profile(name: "Test")
        check(profile.backButton == 3 && profile.forwardButton == 4, "buttons 4 and 5 (3 and 4 to macOS) by default")
        check(decide(3, "com.apple.finder", profile) == "back by swipe", "back in Finder by swipe")
        check(decide(4, "com.apple.Safari", profile) == "forward by swipe", "forward in Safari by swipe")
        check(decide(3, "com.apple.systempreferences", profile) == "back by menu", "back in System Settings by its menu")
        check(decide(3, "com.google.Chrome", profile) == "unchanged", "another developer's app gets the button")
        check(decide(3, "dev.jalves.macos-toolkit", profile) == "unchanged", "the toolkit's own window gets the button, and goes back itself")
        check(decide(5, "com.apple.finder", profile) == "unchanged", "another button is left alone")
        check(decide(3, nil, profile) == "unchanged", "no front app: unchanged")
        profile.backButton = 5
        profile.forwardButton = 6
        check(decide(5, "com.apple.finder", profile) == "back by swipe" && decide(6, "com.apple.finder", profile) == "forward by swipe"
              && decide(3, "com.apple.finder", profile) == "unchanged", "buttons chosen as 6 and 7 replace 4 and 5")

        func decoded(_ json: String) -> Profile? { try? JSONDecoder().decode(Profile.self, from: Data(json.utf8)) }
        let kept = decoded(#"{"name":"A","backButton":5,"forwardButton":6}"#)
        check(kept?.backButton == 5 && kept?.forwardButton == 6, "chosen buttons are read back")
        check(decoded(#"{"name":"A"}"#).map { $0.backButton == 3 && $0.forwardButton == 4 } == true, "a profile from before has the defaults")
        for (json, what) in [(#"{"name":"A","backButton":1,"forwardButton":4}"#, "the right button"),
                             (#"{"name":"A","backButton":2,"forwardButton":4}"#, "the wheel button"),
                             (#"{"name":"A","backButton":5,"forwardButton":5}"#, "one button for both")] {
            let profile = decoded(json)
            check(profile?.backButton == 3 && profile?.forwardButton == 4, "\(what) in a file falls back to the defaults")
        }

        // Buttons with an action: read back, a later version's action kept as Nothing, an unreadable button and a second row for one left out.
        let assigned = decoded(#"{"name":"A","buttonActions":[{"button":"control:00FD","action":"floatingDock"},{"button":"button:5","action":"later"},{"button":"left","action":"back"},{"button":"button:5","action":"back"}]}"#)
        check(assigned?.buttonActions.count == 2, "button actions: the unreadable row and the second row for a button left out")
        check(assigned?.assignment(for: .control(0x00FD))?.action == .floatingDock, "button actions: a control the mouse keeps to itself is read back")
        check(assigned?.assignment(for: .number(5))?.action == .nothing, "button actions: an action from a later version does nothing")
        check(assigned?.divertedControls == [0x00FD], "button actions: only the control is diverted")
        check(assigned?.needsEventTap == true, "button actions: a numbered button needs the event tap")
        check(decoded(#"{"name":"A","buttonActions":[{"button":"control:00FD","action":"back"}]}"#)?.needsEventTap == false,
              "button actions: a diverted control alone needs no event tap")
        if let assigned, let data = try? JSONEncoder().encode(assigned), let back = try? JSONDecoder().decode(Profile.self, from: data) {
            check(back.buttonActions == assigned.buttonActions, "button actions: written and read back the same")
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
