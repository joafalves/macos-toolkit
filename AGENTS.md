# MacOS Toolkit

Personal macOS tooling, packaged as one menu bar app. Each tool is a section in the sidebar of the
main window, and some also live in the menu bar. `README.md` is the user-facing description of every
tool; keep it in step with the code.

## Stack

- Swift 5 language mode, SwiftUI plus AppKit, Swift Package Manager (`Package.swift`). macOS 15+,
  Apple silicon. No dependencies, no Xcode project. Two executable targets: `Toolkit` (the app) and
  `FinderExtension` (a Finder Sync extension, linked with `NSExtensionMain` as its entry point).
- Built with the Command Line Tools only (`swift build`), then wrapped into an app bundle by
  `scripts/build.sh`, which also puts the extension in `Contents/PlugIns` with the app's version and
  signs it (sandboxed, with its entitlements) before the app. The app runs as an accessory (menu bar) app and only shows a Dock icon while its
  main window is open.
- Uses private APIs on purpose: SkyLight and others for the Window Switcher, TCC for the audio
  permission check, `responsibility_get_pid_responsible_for_pid` for grouping helper processes,
  `CGSSetSymbolicHotKeyEnabled` to take ⌘Tab and ⇧⌘3/4/5 from macOS, and `SetsCursorInBackground`
  so the capture overlay can set the cursor without activating the app.

## Layout

- `Sources/Toolkit/App`: shell. `main.swift` (dev flags, single instance), `AppDelegate` (the menu
  bar item's segments, the mixer popover, the main window), `MenuBar` (the one menu bar item), `AppModel` (`AppSection`, the sidebar sections),
  `MainView`, `SettingsTransfer` (export and import of all settings), `Snapshot`.
- `Sources/Toolkit/Mouse`, `Switcher`, `Layout`, `Mixer`, `Finder`, `Capture`: one folder per tool. Screen
  Capture uses ScreenCaptureKit for stills and recordings (AVAssetWriter, H.264), Carbon hotkeys for
  ⇧⌘3/4/5, and non-activating panels (`CapturePanel`) so the app being captured keeps focus.
- `Sources/FinderExtension`: the Finder extension. It is sandboxed, so it only builds the right-click
  menu (reading `finder.json`, which its entitlements allow) and opens a `macos-toolkit://` URL that
  `FinderController.handle` acts on. Its `Info.plist` and entitlements are in `Resources/FinderExtension`.
- `Sources/Toolkit/UI/Components.swift`: shared settings-page building blocks (`Page`, `Card`,
  `SettingRow`, `ToggleRow`, `Banner`, `ViewState`, ...). Use these rather than new ad-hoc styling.
- `Resources`: `Info.plist` (the only place the version lives), app icon.
- `CHANGELOG.md`: what each version adds, changes and fixes (see Versions and releases).
- `scripts`: `build.sh`, `make-cert.sh` (local signing identity), `make-icon.swift`.
- `docs/images`: the README's screenshots. **None of them is a screenshot of the desktop**: every
  one is rendered from the app's own views with `--snapshot`, through the tools' `preview()`
  controllers, which use made-up data (a "Wireless Mouse", invented mixer apps and outputs, invented
  switcher rows, every known terminal rather than the installed ones, default shortcuts and
  folders). Never commit an image that shows anything from this Mac: real devices, apps, windows,
  window titles, files or folders. Screen captures made while testing stay in a scratch folder and
  are deleted.

## Conventions

- **A tool = a controller plus a config.** The controller is an `ObservableObject` that owns a
  `@Published var config` whose `didSet` saves it and applies the change. The config is a `Codable`
  struct with a tolerant `init(from:)` (every key optional, with a default) stored as JSON in
  `~/Library/Application Support/MacOS Toolkit/<tool>.json`.
- **Adding a tool:** a case in `AppSection` (title, symbol), a view in `MainView`, a field in
  `SettingsFile` (optional, so old exports still import), a section in `README.md`.
- **Settings pages** use `Page` and `Card`. Controls that change behaviour go through the config.
  A tool's page starts with `ToolHeader` (its name and the Enabled switch, bound to the config's
  `enabled`) and wraps the rest in `WhenEnabled`. Shortcuts are `Shortcut` values set with
  `ShortcutRow` (`UI/Shortcut.swift`); a tool lets its own shortcuts through while
  `ShortcutRecording.active`, so they can be recorded.
- **`@State` does not compile** here: in the macOS 27 SDK it is a macro and the Command Line Tools lack
  its plugin. Use `@StateObject private var x = ViewState(value)` instead (`ViewState` is in
  `Components.swift`). `@GestureState` and `@StateObject` are fine.
- **Event taps** go through `EventTap` (`App/EventTap.swift`), which runs each on a thread of its
  own: a tap in the path of the events holds up every key or click until it returns. The callback
  decides from state it owns or from `Locked` values the main thread keeps current, and hands
  anything else to the main queue; it never reads a controller's main-thread state directly.
- Clean up after yourself: anything the app changes outside itself (Cmd-Tab, the screenshot keys,
  macOS's window tiling, device properties, Core Audio taps) is restored on quit, on `kill`, and at the next launch if the
  app crashed.
- Comments say why, not what; match the surrounding density. Prose in the UI and README is plain and
  short, no marketing words.
- Permissions: Accessibility (mouse wheel and buttons, switcher, Window Layout, Finder cut, the capture's Content
  Only window style), System Audio Recording (mixer), Screen Recording (capture, and the switcher's
  previews) and Microphone (capture). The Finder extension is a separate switch macOS keeps off
  until it is turned on
  (`pluginkit -e use -i dev.jalves.macos-toolkit.finder`, which the Finder page's button runs).
  The app is signed with a local self-signed identity (`MacOS Toolkit Dev`) so macOS keeps the grants
  across rebuilds; ad-hoc signing makes macOS forget them.

## Building and checking

```bash
swift build                                  # compile check
./scripts/build.sh                           # build "build/MacOS Toolkit.app"
./scripts/build.sh --install                 # also copy to /Applications and relaunch (and Finder, if the extension is on)
.build/debug/Toolkit --snapshot out.png [mouse|switcher|layout|mixer|finder|capture|general] [light]
.build/debug/Toolkit --snapshot out.png mixer-popover [light] [outputs] [software] [equalizer]
.build/debug/Toolkit --snapshot out.png capture-toolbar [light] [video]
.build/debug/Toolkit --snapshot out.png switcher-grid [light]   # drawn stand-ins, no real windows
.build/debug/Toolkit --snapshot out.png menu-bar [light]        # the menu bar item in a few states, on a drawn strip
.build/debug/Toolkit --snapshot out.png layout-grid [light]     # the Window Layout grid over a drawn desktop
.build/debug/Toolkit --snapshot out.png layout-slots [light]    # its layouts bar while dragging
.build/debug/Toolkit --test-capture <folder> [app]   # each screenshot kind and short recordings, with a report
.build/debug/Toolkit --test-recording        # the app's recording path: start, stop button, discard
.build/debug/Toolkit --test-layout [report]  # geometry, then a helper's windows placed for real (run with open -n)
.build/debug/Toolkit --measure-idle <file>   # memory idle, with the settings window, and after (run with open -n, app quit first)
.build/debug/Toolkit --test-wheel <report>   # one scroll notch through the installed app's wheel tap: what comes out (open -n)
.build/debug/Toolkit --test-taps [report]    # a tap keeps up while the main thread is stuck (run with open -n)
.build/debug/Toolkit --test-shortcuts        # config migration, and which macOS screenshot shortcuts clash
.build/debug/Toolkit --test-toolbar          # the capture toolbar's panel against its content
.build/debug/Toolkit --test-overlay [png]    # what the capture overlay costs in memory; with open -n, a picture of it
.build/debug/Toolkit --test-highlight        # the window highlight sits right above its window
.build/debug/Toolkit --test-switcher-previews   # times the grid's pictures of real windows; keeps none
.build/debug/Toolkit --list-windows [--counts <file>]   # what the Window Switcher would list; with --counts, how many and the lookups it took
.build/debug/Toolkit --list-audio            # what the Audio Mixer sees
.build/debug/Toolkit --show-hud              # the volume bar, for a few seconds
```

There is no test suite. Check UI changes by rendering `--snapshot` images in both light and dark and
looking at them, and check behaviour by running the installed app. Keep idle CPU near zero: a hidden
SwiftUI view that animates still costs CPU, and Core Audio taps show macOS's purple recording
indicator, so run them only when needed.

## Versions and releases

Version `X.Y.Z` follows semver. A version goes through three stages: it's **worked on**, it's
**released** (a local commit and tag), and it may be **published** (pushed to GitHub). Only the user
starts a release or a publish.

### While a version is worked on

The version being worked on is the one after the last release: the **next minor** by default
(`0.9.0` after `0.8.0`). It's a major only when the user says so, and a patch only when the user
asks for a fix-only release. From the first change after a release:

- `Resources/Info.plist` carries it: `CFBundleShortVersionString` is `X.Y.Z`, and `CFBundleVersion`
  is one more than at the last release (a plain integer build number, never reset). The **General**
  page header reads `CFBundleShortVersionString`, so don't hard-code a version anywhere else.
- `CHANGELOG.md` has it as its top entry, headed `## X.Y.Z (unreleased)`.
- Every user-visible change goes into that entry **in the same commit as the change**, under
  `### Added`, `### Changed` or `### Fixed` (leave out a heading with nothing under it). Each item
  starts with the bold tool name (`- **Window Layout:** …`) and is a line or two in the README's
  plain voice. Internal-only changes (refactors, dev flags, tests) stay out.

### Releasing X.Y.Z

When the user asks for a release, in one commit:

1. `CHANGELOG.md`: replace `(unreleased)` with the release date, so the heading reads
   `## X.Y.Z (YYYY-MM-DD)`. Check the entry covers everything user-visible since the last tag
   (`git log vPREVIOUS..HEAD`), and drop empty headings. If the user wants a different number than
   the one worked on, rename the entry and the plist to it here.
2. `Resources/Info.plist`: confirm it says `X.Y.Z`. Search for the previous version with
   `grep -rIn "<previous>" . --exclude-dir=.git --exclude-dir=.build --exclude-dir=build` and update
   any other hit (README, docs). `CHANGELOG.md` keeps its old versions, of course.
3. `README.md`: the tool table, the tool's section, and the project layout tree if a folder was
   added. If a page changed visibly, render new screenshots into `docs/images` (a `-light` and a
   `-dark` image each, from `--snapshot`) so the README doesn't show an old UI.
4. Look at every image in `docs/images` and check it shows only preview data, nothing from this Mac.
5. Commit as `chore: release X.Y.Z` and tag `vX.Y.Z` on that commit. Both stay local until the user
   asks to publish.

### Publishing

Only when asked; it pushes to GitHub:

```bash
./scripts/build.sh
ditto -c -k --keepParent --norsrc "build/MacOS Toolkit.app" "MacOS-Toolkit-X.Y.Z.zip"
git push origin main vX.Y.Z
gh release create vX.Y.Z "MacOS-Toolkit-X.Y.Z.zip" --title "X.Y.Z" --notes-file notes.md
```

The release is named `X.Y.Z` with tag `vX.Y.Z`. Its notes are the version's `CHANGELOG.md` entry
(without the heading), then the install block from the previous release (unzip into
`/Applications`, `xattr -dr com.apple.quarantine`, grant Accessibility; the app is self-signed, not
notarized), ending with the Claude Code attribution line. Delete the zip and notes file afterwards.

### After a release

The next change starts the next version: bump `Resources/Info.plist` to the next minor (and
`CFBundleVersion` up by one), and add a new `## X.Y.Z (unreleased)` entry at the top of
`CHANGELOG.md`, in the same commit as that first change.

## Git

Conventional commit subjects (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`), lowercase, no period;
a body when the why isn't obvious. Commit to `main` directly for this personal repo, unless asked for
a branch. Don't push, tag-and-push or publish a release without being asked.
