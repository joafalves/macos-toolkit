import AppKit

/// Awake with the lid closed, on battery too: `pmset disablesleep`, which
/// needs root. Turning the option on installs a rule in `/etc/sudoers.d`
/// that lets this user run exactly that and nothing else, so no password
/// is asked at each session and nothing runs as root in the background.
///
/// `disablesleep` stays set across a restart, so it's never left on: a file
/// says it's on before it's set, and it's put back on quit, on `kill`, and at
/// the next launch if the app crashed.
enum LidSleep {
    private static let rulePath = "/etc/sudoers.d/macos-toolkit"
    private static let pmset = "/usr/bin/pmset"

    private static var markerURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("awake-sleep-disabled")
    }

    /// The rule is there and lets this user set it without a password.
    static var ready: Bool {
        FileManager.default.fileExists(atPath: rulePath) && run("/usr/bin/sudo", ["-n", "-l", pmset, "-a", "disablesleep", "1"])
    }

    /// Asks for an admin password once and installs the rule. False if it was
    /// cancelled or failed.
    static func install() -> Bool {
        guard let rule = rule(for: NSUserName()) else { return false }
        // Checked by visudo before it's put in place: a broken file in
        // sudoers.d would break sudo altogether. The draft is made by root, so
        // nothing else can swap it between the check and the install.
        let script = """
        f=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' '# Keep Awake in MacOS Toolkit: awake with the lid closed. Removed when the option is turned off.' '\(rule)' > "$f" \
        && /usr/sbin/visudo -cf "$f" && /usr/bin/install -m 0440 -o root -g wheel "$f" \(rulePath); r=$?; /bin/rm -f "$f"; exit $r
        """
        let source = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Toolkit: lid rule not installed: \(error)") }
        return error == nil && ready
    }

    /// This user may set `disablesleep` and take the rule out, and nothing else.
    /// Only a plain name goes into it.
    static func rule(for user: String) -> String? {
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1, /bin/rm -f \(rulePath)"
    }

    /// Takes the rule out again; the rule allows exactly this too.
    static func uninstall() {
        restore()
        _ = run("/usr/bin/sudo", ["-n", "/bin/rm", "-f", rulePath])
    }

    /// Lets the Mac stay awake with the lid closed.
    @discardableResult
    static func disableSleep() -> Bool {
        // Written down first, so a crash right after still puts it back.
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
        return run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", "1"])
    }

    /// Sleep as before. Also run at launch, in case a crash left it off.
    static func restore() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        if run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", "0"]) {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
