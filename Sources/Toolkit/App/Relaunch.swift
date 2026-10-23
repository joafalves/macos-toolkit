import AppKit

/// Quits and opens the app again once this process is gone. Opening the new
/// copy straight away raced our own quitting: the new one's single-instance
/// check (main.swift) gives up after a few seconds, and quitting can take
/// longer (putting ⌘Tab back, saving, closing audio), so both were gone.
enum Relaunch {
    /// `restartingFinder`: also restart Finder if the extension is on, since
    /// Finder keeps an old copy of it loaded (after an update).
    static func now(_ app: URL = Bundle.main.bundleURL, restartingFinder: Bool = false) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let id = (Bundle.main.bundleIdentifier ?? "") + ".finder"
        let finder = restartingFinder ? """
        if /usr/bin/pluginkit -m -i '\(id)' | /usr/bin/grep -q '^+'; then
          /usr/bin/pkill -f FinderExtension.appex; /usr/bin/killall Finder
        fi
        """ : ""
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        \(finder)
        /usr/bin/open "$1"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
