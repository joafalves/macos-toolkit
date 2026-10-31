import AppKit
import ServiceManagement

// Screen Capture's text reader: a copy of the app reads one image and quits,
// so Vision's memory goes with it (`TextReader.read`).
if CommandLine.arguments.contains("--read-text") {
    TextReader.serve()
}

// Maintenance flags, used by the build script when the app is replaced.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}
if CommandLine.arguments.contains("--register-login-item") {
    try? SMAppService.mainApp.register()
    exit(0)
}

AppLanguage.apply(GeneralConfig.load().language)

// The development flags below are only in dev builds (`swift build`, or
// `build.sh --dev`). Started through `open`, the app is the one macOS asks
// about, so any process could use them to capture the screen, read window
// titles or post input with the app's permissions, without a prompt.
#if TOOLKIT_DEV
// Development aid: `--snapshot <png> [section] [light]` renders the main window
// to an image without showing it, so layout can be checked from the terminal.
// `switcher-list` in place of a section renders the window switcher's list,
// `mixer-popover [outputs] [software] [equalizer] [per-output]` the menu bar mixer,
// `capture-toolbar [video]` the Screen Capture toolbar, `layout-grid` the
// Window Layout grid over a drawn desktop, `layout-slots` its drag layouts,
// `layout-suggest` the windows it offers for the rest of a display.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
    let rest = Array(CommandLine.arguments[(flag + 1)...])
    // `available`: a new version on offer, for About and the toolkit panel.
    // `available [notes.md | releases.json since=X.Y.Z]`: a new version on
    // offer, with those notes, or what GitHub's list offers a copy at X.Y.Z.
    if rest.contains("available") {
        if let feed = rest.first(where: { $0.hasSuffix(".json") }).flatMap({ FileManager.default.contents(atPath: $0) }),
           let since = rest.first(where: { $0.hasPrefix("since=") })?.dropFirst(6) {
            Updater.shared.preview(feed: feed, since: String(since))
        } else {
            Updater.shared.preview(notes: rest.first { $0.hasSuffix(".md") }.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) })
        }
    }
    if rest.contains("switcher-list") || rest.contains("switcher-grid") {
        if rest.contains("small") { SwitcherPanel.previewIcons = .small }
        Snapshot.writeSwitcher(to: rest[0], light: rest.contains("light"), grid: rest.contains("switcher-grid"), colors: rest.contains("colors"),
                               many: rest.contains("many"), query: rest.first { $0.hasPrefix("search=") }.map { String($0.dropFirst(7)) })
        exit(0)
    }
    if rest.contains("mixer-popover") {
        Snapshot.writeMixer(to: rest[0], light: rest.contains("light"), outputs: rest.contains("outputs"), software: rest.contains("software"), equalizer: rest.contains("equalizer"), perOutput: rest.contains("per-output"))
        exit(0)
    }
    if rest.contains("stats-bar") {
        Snapshot.writeStatsBar(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("stats-panel") {
        let kinds = rest.compactMap(StatKind.init)
        Snapshot.writeStatsPanel(to: rest[0], light: rest.contains("light"), kinds: kinds.isEmpty ? StatKind.allCases : kinds)
        exit(0)
    }
    if rest.contains("mouse-panel") {
        Snapshot.writeMousePanel(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("layout-panel") {
        Snapshot.writeLayoutPanel(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("awake-panel") {
        Snapshot.writeAwakePanel(to: rest[0], light: rest.contains("light"), off: rest.contains("off"))
        exit(0)
    }
    if rest.contains("permissions-sheet") {
        Snapshot.writePermissionsSheet(to: rest[0], light: rest.contains("light"), done: rest.contains("done"), restart: rest.contains("restart"))
        exit(0)
    }
    if rest.contains("toolkit-panel") {
        Snapshot.writeToolkitPanel(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("menu-bar-strip") {
        Snapshot.writeMenuBarStrip(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("menu-bar") {
        Snapshot.writeMenuBar(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("layout-tabs") {
        Snapshot.writeLayoutTabs(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("layout-suggest") {
        Snapshot.writeLayoutSuggest(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("layout-grid") || rest.contains("layout-slots") {
        Snapshot.writeLayoutGrid(to: rest[0], light: rest.contains("light"), slots: rest.contains("layout-slots"))
        exit(0)
    }
    if rest.contains("volume-hud") {
        Snapshot.writeVolumeHUD(to: rest[0], light: rest.contains("light"))
        exit(0)
    }
    if rest.contains("capture-text") {
        Snapshot.writeCaptureText(to: rest[0], light: rest.contains("light"), none: rest.contains("none"), reading: rest.contains("reading"))
        exit(0)
    }
    if rest.contains("capture-toolbar") {
        Snapshot.writeCaptureToolbar(to: rest[0], light: rest.contains("light"), video: rest.contains("video"))
        exit(0)
    }
    // `layout tabs` or `layout keyboard`: that tab of the Window Layout page;
    // `mouse device`: the made-up mouse's own page.
    CaptureController.previewText = rest.contains("text")
    MixerController.previewDriver = rest.first { $0.hasPrefix("driver=") }.map { String($0.dropFirst(7)) }
    MouseController.previewOpen = rest.contains("device")
    MainView.previewSearch = rest.first { $0.hasPrefix("search=") }.map { String($0.dropFirst(7)) } ?? ""
    LayoutController.previewPage = rest.contains("tabs") ? .tabs : rest.contains("keyboard") ? .keyboard : nil
    Snapshot.write(to: rest[0], section: rest.dropFirst().compactMap(AppSection.init).first ?? .mouse, light: rest.contains("light"),
                   noAccess: rest.contains("no-access"), tall: rest.contains("tall"))
    exit(0)
}

// Development aid: `--list-windows` prints the rows the window switcher would show.
if CommandLine.arguments.contains("--list-windows") {
    SwitcherController.dumpWindows()
    exit(0)
}

// Development aid: what the switcher finds for what's typed, and app colours,
// from made-up apps.
if CommandLine.arguments.contains("--test-switcher-search") {
    SwitcherSearch.test()
    exit(0)
}
// Development aid: `--list-search <text> [file]`: what the switcher finds for
// that on this Mac, as ranked; with Accessibility (open -n), the open windows too.
if let flag = CommandLine.arguments.firstIndex(of: "--list-search"), CommandLine.arguments.count > flag + 1 {
    _ = NSApplication.shared
    SwitcherSearch.listSearch(CommandLine.arguments[flag + 1], file: CommandLine.arguments.count > flag + 2 ? CommandLine.arguments[flag + 2] : nil)
    exit(0)
}
// Development aid: what the Dock shows on its icons (open -n; Accessibility).
if CommandLine.arguments.contains("--list-badges") {
    _ = NSApplication.shared
    SwitcherSearch.listBadges()
    exit(0)
}

// Development aid: how the switcher's list fills from nothing, and recovers (open -n).
if let flag = CommandLine.arguments.firstIndex(of: "--test-catalog-startup") {
    SwitcherController.catalogStartupTest(report: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}

// Development aid: `--test-switcher-displays [report]` checks the switcher's
// list for each display, with the windows open now (open -n).
if let flag = CommandLine.arguments.firstIndex(of: "--test-switcher-displays") {
    SwitcherController.displaysTest(report: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}

// Development aid: `--test-update <feeds> <copy> [report]` checks and installs
// made-up releases over a copy of the app (run the app bundle).
if let flag = CommandLine.arguments.firstIndex(of: "--test-update"), CommandLine.arguments.count > flag + 2,
   let feeds = URL(string: CommandLine.arguments[flag + 1]) {
    Updater.selfTest(feeds: feeds, copy: URL(fileURLWithPath: CommandLine.arguments[flag + 2]),
                     report: CommandLine.arguments.count > flag + 3 ? CommandLine.arguments[flag + 3] : nil)
    exit(0)
}

// Development aid: `--list-audio` prints the apps the audio mixer sees.
// Development aid: `--test-volume`, the volume keys' steps and saved
// software volumes read onto the even scale.
// `--test-equalizer`: the presets' curves, tones through the filters, the
// limiter, a preset change mid-tone, and five-band equalizers read into ten.
// `--measure-headroom <folder>`: how far each equalizer curve lifts real
// music's peaks, and how the limiter would work with less headroom.
if let flag = CommandLine.arguments.firstIndex(of: "--measure-headroom"), CommandLine.arguments.count > flag + 1 {
    MixerController.measureHeadroom(CommandLine.arguments[flag + 1])
    exit(0)
}
if CommandLine.arguments.contains("--test-equalizer") {
    MixerController.equalizerTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-volume") {
    MixerController.volumeTest()
    exit(0)
}
// `--test-audio-access <report>`: the microphone and an audio tap work as
// signed (the hardened runtime). Run the app bundle with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-audio-access"), CommandLine.arguments.count > flag + 1 {
    MixerController.accessTest(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// `--test-mixer-engine <report>`: the mixer run for real on a tone from a
// helper app: clicks as it pauses, has its volume changed and the equalizer
// switched, and whether the Mac can sleep once it stops. Run with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-mixer-engine"), CommandLine.arguments.count > flag + 1 {
    MixerEngineTest.run(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// The helper that test starts: a copy of this app playing a tone.
if let flag = CommandLine.arguments.firstIndex(of: "--play-tone") {
    MixerEngineTest.playTone(Array(CommandLine.arguments[(flag + 1)...]))
    exit(0)
}
// `--test-driver <report>`: the audio driver, end to end, with it installed:
// a tone through it, what that costs, the microphone. Run with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-driver"), CommandLine.arguments.count > flag + 1 {
    MixerEngineTest.runDriver(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// `--test-driver-sounds <report>`: short sounds through the driver, and what a
// recording's system audio gets. Run with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-driver-sounds"), CommandLine.arguments.count > flag + 1 {
    MixerEngineTest.runDriverSounds(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// `--test-driver-outputs`: where sound goes as outputs come and go on the driver.
if CommandLine.arguments.contains("--test-driver-outputs") {
    DriverRoutes.selfTest()
    exit(0)
}
// `--test-driver-eq <report>`: the same equalizer through taps and through the
// driver, measured band by band. Run with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-driver-eq"), CommandLine.arguments.count > flag + 1 {
    MixerEngineTest.runDriverEqualizer(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// The helper that test starts: a copy of this app playing a file.
if let flag = CommandLine.arguments.firstIndex(of: "--play-file"), CommandLine.arguments.count > flag + 1 {
    MixerEngineTest.playFile(CommandLine.arguments[flag + 1])
    exit(0)
}
// `--test-driver-long <report> <seconds>`: a tone through the driver for a long
// while: what stays queued, how the clocks settle, any gaps. Run with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-driver-long"), CommandLine.arguments.count > flag + 2 {
    MixerEngineTest.runDriverLong(into: CommandLine.arguments[flag + 1], seconds: Double(CommandLine.arguments[flag + 2]) ?? 60)
    exit(0)
}
// `--test-driver-crash <report>`: the driver's device and the default output,
// with the toolkit killed or frozen. Run with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-driver-crash"), CommandLine.arguments.count > flag + 1 {
    MixerEngineTest.runDriverCrash(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// The copy that test kills.
if CommandLine.arguments.contains("--driver-hold") {
    MixerEngineTest.holdDriver()
    exit(0)
}
// `--test-mixer-mic <report>`: a helper opens the microphone alone, with and
// without the mixer's taps waiting: whether its input starts. Run with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-mixer-mic"), CommandLine.arguments.count > flag + 1 {
    MixerEngineTest.runMic(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// The helper that test starts: a copy of this app opening the microphone.
if let flag = CommandLine.arguments.firstIndex(of: "--open-mic") {
    MixerEngineTest.openMic(Array(CommandLine.arguments[(flag + 1)...]))
    exit(0)
}
if CommandLine.arguments.contains("--list-audio") {
    MixerController.dumpApps()
    exit(0)
}

// Development aid: `--test-publishing` changes the Mouse page's controls, as
// a click would, in a window that's never shown, and reports SwiftUI's
// "Publishing changes from within view updates" for each.
if CommandLine.arguments.contains("--test-publishing") {
    PublishingProbe.run()
    exit(0)
}

// Development aid: `--list-mice` prints the mice the Mouse tool sees, with
// what each is keyed by and its charge.
if CommandLine.arguments.contains("--list-mice") {
    MouseController.dumpMice()
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

if CommandLine.arguments.contains("--test-switcher-previews") {
    SwitcherController.previewTest()
    exit(0)
}
// Development aid: `--test-layout [report]` checks Window Layout's geometry
// and places a helper's windows. Run the app bundle with `open -n` so
// Accessibility is the app's own.
if let flag = CommandLine.arguments.firstIndex(of: "--test-layout") {
    LayoutController.selfTest(report: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}
// Development aid: `--test-drag [report]` drags a helper's window for real,
// filled by macOS and not, and resizes it, through the drag watcher (open -n).
if let flag = CommandLine.arguments.firstIndex(of: "--test-drag") {
    LayoutController.dragTest(report: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}
// Development aid: `--test-snap [report]` drags a helper's windows into
// snaps for real, which the installed app's Window Layout makes (open -n).
if let flag = CommandLine.arguments.firstIndex(of: "--test-snap") {
    LayoutController.snapTest(report: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}
// Development aid: `--test-gap [report]` changes the gap under a helper's
// maximized and half windows (open -n).
if let flag = CommandLine.arguments.firstIndex(of: "--test-gap") {
    LayoutController.gapTest(report: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}
// Development aid: `--test-show-desktop [report]` turns macOS's Show Desktop
// on and off with a helper's windows out (every window moves for a moment).
if let flag = CommandLine.arguments.firstIndex(of: "--test-show-desktop") {
    LayoutController.showDesktopTest(report: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}
// Development aid: `--test-persist <step> <helper pid> [report]`, one step of
// scripts/test-persist.sh (the installed app restarted in between).
if let flag = CommandLine.arguments.firstIndex(of: "--test-persist"), CommandLine.arguments.count > flag + 2,
   let pid = pid_t(CommandLine.arguments[flag + 2]) {
    LayoutController.persistTest(step: CommandLine.arguments[flag + 1], helper: pid,
                                 report: CommandLine.arguments.count > flag + 3 ? CommandLine.arguments[flag + 3] : nil)
    exit(0)
}
// Development aid: `--test-displays [report]` makes a display a mirror for a
// moment, as if unplugged, with a helper's windows snapped on it (open -n).
if let flag = CommandLine.arguments.firstIndex(of: "--test-displays") {
    LayoutController.displaysTest(report: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--list-suggestions") {
    LayoutController.dumpSuggestions(CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--dump-menus"), CommandLine.arguments.count > flag + 1 {
    let output = CommandLine.arguments.count > flag + 2 ? CommandLine.arguments[flag + 2] : nil
    if let output { freopen(output, "w", stdout) }
    LayoutController.dumpMenus(CommandLine.arguments[flag + 1])
    exit(0)
}
if CommandLine.arguments.contains("--layout-test-window") {
    LayoutController.runTestWindows()
    exit(0)
}
// Development aid: `--test-text`, drawn text and codes through the text
// reader: what comes out against what went in. Needs no permission.
if CommandLine.arguments.contains("--test-text") {
    CaptureController.textTest()
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
// Development aid: `--test-wheel <report>`, one notch through the installed
// app's wheel tap. Run the app bundle with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-wheel"), CommandLine.arguments.count > flag + 1 {
    WheelProbe.run(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// Development aid: `--log-wheel <file> [seconds]`, every scroll event as macOS
// hands it over and as apps get it. Run the app bundle with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--log-wheel"), CommandLine.arguments.count > flag + 1 {
    let seconds = CommandLine.arguments.count > flag + 2 ? Double(CommandLine.arguments[flag + 2]) ?? 30 : 30
    WheelProbe.log(into: CommandLine.arguments[flag + 1], seconds: seconds)
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--test-menu-bar-tint"), CommandLine.arguments.count > flag + 1 {
    MenuBarRow.tintTest(into: CommandLine.arguments[flag + 1])
    exit(0)
}
if CommandLine.arguments.contains("--test-menu-bar-widths") {
    MenuBarRow.widthTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-menu-bar-idle") {
    MenuBarRow.idleTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-menu-bar-clicks") {
    MenuBarRow.clickTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-menu-bar") {
    MenuBarRow.selfTest()
    exit(0)
}
// Development aid: `--test-taps [report]`, the event taps keep up while the
// main thread is stuck. Run the app bundle with `open -n` so Accessibility is
// the app's own; the report goes to the file.
if let flag = CommandLine.arguments.firstIndex(of: "--test-taps") {
    let path = CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil
    if let path { freopen(path, "w", stdout) }
    EventTap.selfTest()
    fflush(stdout)
    exit(0)
}
// Development aid: `--test-nudge <report>`, which input resets the idle time
// chat apps read. Run the app bundle with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-nudge"), CommandLine.arguments.count > flag + 1 {
    AwakeProbe.run(into: CommandLine.arguments[flag + 1])
    exit(0)
}
// `--test-awake <report>`: Keep Awake's assertion, times and a
// mouse drift. Run the app bundle with `open -n`.
if let flag = CommandLine.arguments.firstIndex(of: "--test-awake"), CommandLine.arguments.count > flag + 1 {
    AwakeController.selfTest(into: CommandLine.arguments[flag + 1])
    exit(0)
}
if CommandLine.arguments.contains("--test-navigation") {
    WheelEngine.navigationSelfTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-tweaks") {
    TweaksModel.selfTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-stats-panels") {
    StatsController.panelTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-stats") {
    StatsController.selfTest()
    exit(0)
}
if CommandLine.arguments.contains("--test-settings") {
    SettingsTransfer.selfTest()
    exit(0)
}
// `--test-overlay [png]`: the capture overlay's memory, and optionally a
// picture of it (run the app bundle with `open -n` for that).
if let flag = CommandLine.arguments.firstIndex(of: "--test-overlay") {
    CaptureController.overlayTest(picture: CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : nil)
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

// Development aid: `--measure-idle <file>` starts as at login (no window),
// then writes the memory used idle, with the settings window, and after it.
let measureIdlePath: String? = CommandLine.arguments.firstIndex(of: "--measure-idle").flatMap {
    CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil
}
#else
let measureIdlePath: String? = nil
#endif

// A fresh install starts with every tool off, to be turned on as wanted.
// Saved straight away, so it holds later; a Mac that has run the toolkit
// before has a settings file for at least one tool and is left as it is
// (its tools without a file stay on, as they were).
let toolFiles = [MouseConfig.fileURL, SwitcherConfig.fileURL, LayoutConfig.fileURL, MixerConfig.fileURL,
                 FinderConfig.fileURL, CaptureConfig.fileURL, AwakeConfig.fileURL, StatsConfig.fileURL, GeneralConfig.fileURL]
if !toolFiles.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
    var mouse = MouseConfig(); mouse.enabled = false; mouse.save()
    var switcher = SwitcherConfig(); switcher.enabled = false; switcher.save()
    var layout = LayoutConfig(); layout.enabled = false; layout.save()
    var mixer = MixerConfig(); mixer.enabled = false; mixer.save()
    var finder = FinderConfig(); finder.enabled = false; finder.save()
    var capture = CaptureConfig(); capture.enabled = false; capture.save()
    var awake = AwakeConfig(); awake.enabled = false; awake.save()
    var stats = StatsConfig(); stats.enabled = false; stats.save()
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
