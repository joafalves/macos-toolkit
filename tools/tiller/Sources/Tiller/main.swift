import AppKit

// Two instances would fight over the same device properties.
let bundleID = Bundle.main.bundleIdentifier ?? "dev.jalves.tiller"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
