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

        if AXIsProcessTrusted(), let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            check(AppNavigation.backAndForward(in: finder.processIdentifier) != nil, "Finder's Back and Forward menu items are found by title")
        } else {
            print("      menu items: not checked (needs Accessibility: run the dev bundle with open -n)")
        }
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }
}
#endif
