import AppKit

// Two instances would fight over the same device properties.
let bundleID = Bundle.main.bundleIdentifier ?? "dev.jalves.tiller"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    // A relaunch starts us while the old instance is still shutting down.
    let deadline = Date().addingTimeInterval(3)
    while others.contains(where: { !$0.isTerminated }), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if others.contains(where: { !$0.isTerminated }) { exit(0) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
