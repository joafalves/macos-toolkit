#if TOOLKIT_DEV
import Foundation

extension TweaksModel {
    /// `--test-tweaks`: every tweak read from this Mac, which changes nothing
    /// of macOS's, and the preference round trip on a scratch domain of our own.
    static func selfTest() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print((ok ? "ok    " : "FAIL  ") + what)
        }

        // The page reads as it's made, so it has to be quick.
        _ = read()
        let start = Date()
        let states = read()
        let took = Date().timeIntervalSince(start) * 1000
        check(took < 30, String(format: "a read of every tweak takes %.1f ms", took))
        check(states.count == Tweak.allCases.count, "every tweak read (\(states.count) of \(Tweak.allCases.count))")
        for tweak in Tweak.allCases {
            let on = states[tweak] ?? tweak.macOSDefault
            print("      \(tweak.rawValue): \(on ? "on" : "off")\(on != tweak.macOSDefault ? ", changed from macOS's default" : "")")
        }
        print("      disabled in this session: \(disabledServices().sorted().joined(separator: ", "))")
        for tweak in Tweak.allCases {
            guard case .service(let label) = tweak.kind else { continue }
            check(!run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).isEmpty, "\(label) is a service in this session")
        }

        let domain = "dev.jalves.macos-toolkit.tweaks-test"
        let pair = Tweak.Preference(domain: domain, keys: ["first", "second"], on: 0.0)
        check(!pair.read(), "a preference whose on value is set reads off while the key isn't there")
        pair.write(true)
        check(pair.read() && run("/usr/bin/defaults", ["read", domain, "second"]).hasPrefix("0"), "on writes every key")
        pair.write(false)
        check(!pair.read() && run("/usr/bin/defaults", ["read", domain, "second"]).isEmpty, "off deletes every key")
        // `defaults write -int 0` as someone may have set it by hand.
        _ = run("/usr/bin/defaults", ["write", domain, "first", "-int", "0"])
        check(pair.read(), "0 written as an integer reads as on for 0.0")
        let inverse = Tweak.Preference(domain: domain, keys: ["third"], off: "none")
        check(inverse.read(), "a preference whose off value is set reads on while the key isn't there")
        inverse.write(false)
        check(!inverse.read() && run("/usr/bin/defaults", ["read", domain, "third"]).hasPrefix("none"), "off writes its value")
        inverse.write(true)
        check(inverse.read() && run("/usr/bin/defaults", ["read", domain, "third"]).isEmpty, "on deletes the key, macOS's default")
        _ = run("/usr/bin/defaults", ["delete", domain])

        print(failures == 0 ? "all ok" : "\(failures) failed")
    }
}
#endif
