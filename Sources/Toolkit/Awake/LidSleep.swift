import Foundation
import os

/// Keep Awake had a "lid closed" option before 0.19.3. It ran `pmset -a
/// disablesleep` as root through a rule in `/etc/sudoers.d`, and sudo can't
/// tell which program asks, so anything running as this user could turn
/// sleep off with it too. A Mac that had it is put back as it was at launch:
/// sleep on, and the rule gone. The rule allows both, so no password is asked.
enum LidSleep {
    private static let rulePath = "/etc/sudoers.d/macos-toolkit"
    private static let pmset = "/usr/bin/pmset"

    /// Written while the option had sleep off, so a crash could put it back.
    private static var markerURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("awake-sleep-disabled")
    }

    /// Off the main thread: sudo takes a moment.
    static func removeLeftovers() {
        let files = FileManager.default
        let rule = files.fileExists(atPath: rulePath), marker = files.fileExists(atPath: markerURL.path)
        guard rule || marker else { return }
        DispatchQueue.global(qos: .utility).async {
            guard rule else {
                // Taken out by hand while sleep was off: only an admin can turn it back on.
                Log.awake.error("sleep may still be off with the lid closed; `sudo pmset -a disablesleep 0` turns it back on")
                try? files.removeItem(at: markerURL)
                return
            }
            // Sleep back on whatever turned it off, while the rule still allows it.
            if run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", "0"]) { try? files.removeItem(at: markerURL) }
            let removed = run("/usr/bin/sudo", ["-n", "/bin/rm", "-f", rulePath])
            Log.awake.notice("the lid-closed rule from before 0.19.3 removed: \(removed)")
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
