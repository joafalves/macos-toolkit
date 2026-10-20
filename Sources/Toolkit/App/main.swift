import AppKit
import ServiceManagement

// Maintenance flags, used by the build script when the app is replaced.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}
if CommandLine.arguments.contains("--register-login-item") {
    try? SMAppService.mainApp.register()
    exit(0)
}

// Development aid: `--snapshot <png> [section] [light]` renders the main window
// to an image without showing it, so layout can be checked from the terminal.
// `switcher-list` in place of a section renders the window switcher's list,
// `mixer-popover [outputs] [software] [equalizer]` the menu bar mixer,
// `capture-toolbar [video]` the Screen Capture toolbar.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
    let rest = Array(CommandLine.arguments[(flag + 1)...])
    if rest.contains("switcher-list") {
        Snapshot.writeSwitcher(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("mixer-popover") {
        Snapshot.writeMixer(to: rest[0], light: rest.contains("light"), outputs: rest.contains("outputs"), software: rest.contains("software"), equalizer: rest.contains("equalizer"))
        exit(0)
    }
    if rest.contains("capture-toolbar") {
        Snapshot.writeCaptureToolbar(to: rest[0], light: rest.contains("light"), video: rest.contains("video"))
        exit(0)
    }
    Snapshot.write(to: rest[0], section: rest.dropFirst().compactMap(AppSection.init).first ?? .mouse, light: rest.contains("light"))
    exit(0)
}

// Development aid: `--list-windows` prints the rows the window switcher would show.
if CommandLine.arguments.contains("--list-windows") {
    SwitcherController.dumpWindows()
    exit(0)
}

// Development aid: `--list-audio` prints the apps the audio mixer sees.
if CommandLine.arguments.contains("--list-audio") {
    MixerController.dumpApps()
    exit(0)
}

// Development aid: `--test-capture <folder> [app name]` takes each kind of
// screenshot (of the app's biggest window) and a short recording, and writes them with a report to the folder. Run it with
// `open -n` so the Screen Recording permission is the app's own.
if let flag = CommandLine.arguments.firstIndex(of: "--test-capture"), CommandLine.arguments.count > flag + 1 {
    let app = CommandLine.arguments.count > flag + 2 ? CommandLine.arguments[flag + 2] : nil
    CaptureController.selfTest(into: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), app: app)
    exit(0)
}

if CommandLine.arguments.contains("--test-shortcuts") {
    CaptureController.shortcutTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-recording") {
    CaptureController.recordingTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-highlight") {
    CaptureController.highlightTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-toolbar") {
    CaptureController.toolbarTest()
    exit(0)
}

// Development aid: `--show-hud` shows the volume bar for a few seconds.
if CommandLine.arguments.contains("--show-hud") {
    VolumeHUD.demo()
    exit(0)
}

// Two instances would fight over the same device properties.
let bundleID = Bundle.main.bundleIdentifier ?? "dev.jalves.macos-toolkit"
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
