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
  `CGSSetSymbolicHotKeyEnabled` to take ⌘Tab and ⇧⌘3/4/5 from macOS, `SetsCursorInBackground`
  so the capture overlay can set the cursor without activating the app, and IOReport (through
  `dlopen`) for System Stats' CPU and GPU watts, subscribed to only while the power stat is read.
- Root only through one narrow rule: Keep Awake's lid-closed option asks for the admin password once
  and installs `/etc/sudoers.d/macos-toolkit`, which allows `pmset -a disablesleep 0/1` and removing
  itself, checked with `visudo` first (`LidSleep.swift`). Nothing runs as root otherwise.

## Layout

- `Sources/Toolkit/App`: shell. `main.swift` (dev flags, single instance), `AppDelegate` (the menu
  bar item's segments, the mixer popover, the main window), `MenuBar` (the one menu bar item), `AppModel` (`AppSection`, the sidebar sections),
  `MainView`, `GeneralConfig` (the app's own settings, such as the menu bar spacing),
  `SettingsTransfer` (export and import of all settings), `Snapshot`, and `WindowUnderPointer`
  (which app owns the window under a point, for tools that act on it).
- `Sources/Toolkit/Mouse`, `Switcher`, `Layout`, `Mixer`, `Finder`, `Capture`, `Awake`, `Stats`: one folder per tool. Screen
  Capture uses ScreenCaptureKit for stills and recordings (AVAssetWriter, H.264), Carbon hotkeys for
  ⇧⌘3/4/5, and non-activating panels (`CapturePanel`) so the app being captured keeps focus.
- `Sources/FinderExtension`: the Finder extension. It is sandboxed, so it only builds the right-click
  menu (reading `finder.json`, which its entitlements allow) and opens a `macos-toolkit://` URL that
  `FinderController.handle` acts on. Its `Info.plist` and entitlements are in `Resources/FinderExtension`.
- `Sources/Toolkit/UI/Components.swift`: shared settings-page building blocks (`Page`, `Card`,
  `SettingRow`, `ToggleRow`, `Banner`, `ViewState`, ...). Use these rather than new ad-hoc styling.
- `Resources`: `Info.plist` (the only place the version lives), app icon.
- `CHANGELOG.md`: what each version adds, changes and fixes (see Versions and releases).
- `LICENSE`: the Apache License 2.0, unchanged; the copyright line is in the README and on About.
- `scripts`: `build.sh`, `make-cert.sh` (local signing identity), `make-icon.swift` (the app icon;
  `KitIcon` in `Components.swift` and `MenuBarArt.toolkit` draw it too, keep them in step).
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
- **Adding a tool:** a case in `AppSection` (title, symbol, colour), a view in `MainView`, a field in
  `SettingsFile` (optional, so old exports still import), a section in `README.md`.
- **Import merges, setting by setting** (`SettingsTransfer.merge`): what a file lacks stays as it is
  here. A setting that only holds on this Mac, because it goes with a grant made here (the lid-closed
  admin rule), goes in `SettingsTransfer.localOnly`: never exported, never imported.
- **Settings pages** use `Page` and `Card`. Controls that change behaviour go through the config.
  A tool's page starts with `ToolHeader` (its name and the Enabled switch, bound to the config's
  `enabled`) and wraps the rest in `WhenEnabled`. Shortcuts are `Shortcut` values set with
  `ShortcutRow` (`UI/Shortcut.swift`); a tool lets its own shortcuts through while
  `ShortcutRecording.active`, so they can be recorded.
- **Linked settings** (`UI/LinkedSettings.swift`): when one setting holds another (Stay available
  keeps the display on), pass a `SettingLink` to both rows while it's in force, `.heldBy(...)` on the
  held one, which locks its control, and `.holds(...)` on the holder, and mark each row with
  `.settingAnchor(_:)`. Both show a badge, and clicking one scrolls to the other row and lights it up.
  The held setting keeps its own stored value, so it comes back when the link ends.
- **`@State` does not compile** here: in the macOS 27 SDK it is a macro and the Command Line Tools lack
  its plugin. Use `@StateObject private var x = ViewState(value)` instead (`ViewState` is in
  `Components.swift`). `@GestureState` and `@StateObject` are fine.
- **Event taps** go through `EventTap` (`App/EventTap.swift`), which runs each on a thread of its
  own: a tap in the path of the events holds up every key or click until it returns. The callback
  decides from state it owns or from `Locked` values the main thread keeps current, and hands
  anything else to the main queue; it never reads a controller's main-thread state directly.
  Returning nil swallows the event, so a handler that means to pass it returns it; never
  `?? Unmanaged.passUnretained(event)` a result that is nil on purpose. The front app comes from
  `FrontApp` (start it on the main thread before any tap), not from `NSWorkspace` on the tap thread.
- **The menu bar is one item** (`MenuBarItem` in `App/MenuBar.swift`): each tool that shows there
  adds a `MenuBarSegment`, drawn as real views (`MenuBarPartView`), not a picture of them. Clicks
  arrive as if at the button's centre, so the part is found from `NSEvent.mouseLocation`. macOS
  ignores the button's highlight and state, so menus open with `MenuBarItem.open` (it sets the
  item's menu and clicks it, which keeps the item lit); panels hang from a part with
  `MenuBarPopover`, which lights it and closes on a click elsewhere or Esc.
  - **No `NSTextField` in it**, not even a hidden one: on macOS 27 a text field inside a status item
    keeps the whole item redrawing, at 25–90% of a core while nothing changes. Text is
    `MenuBarText`, a view that draws its own; it's vibrant like the icons unless it has a colour of
    its own, which vibrancy would wash out. `--test-menu-bar-idle` puts real items in the menu bar
    and should read 0.0% for each kind of part.
  - **Parts don't change width** as their figures change: a segment's `widthOf` (or a column line's)
    is the widest its text gets, and the part keeps that width with the text against its right edge
    (`--test-menu-bar-widths`). Keep templates as small as what's really shown (stats stop at 99%).
    The volume is the exception: it changes only when you change it, and room for "100%" left a gap.
  - The spacing setting goes between parts only, not at the item's two ends, where macOS leaves its
    own gap as for any item.
  - An update costs about 8 ms (`--test-menu-bar`), most of it macOS taking a new picture of the
    item, so only when something shown changes; System Stats updates it every couple of seconds.
  - `MenuBarArt` keeps every image it draws by what's in it, so only a fixed set goes through
    `cached`. An image with a changing time or figure in it goes through `latest`, which keeps the
    last one only: cached, the Keep Awake pill grew by ~80 MB a day.
- **Overlays are layers.** Full-screen overlays build `CALayer`s, not `draw(_:)`, which keeps a
  bitmap the size of each display (about 100 MB on large displays). Panels that call back into
  their owner hold it, or themselves, weakly; a cycle there kept every overlay alive.
- **Accessibility values are type-checked** (`attribute<T>` in `LayoutWindow` and
  `WindowCatalog`): an app can answer with anything, and a forced cast crashes the toolkit.
- **The Finder extension's URLs carry a token** that the app writes at launch (`finder-token`,
  0600) and checks in constant time; any app can open a `macos-toolkit://` URL. Actions only ever
  work on folders.
- **Memory and CPU:** the settings window is released when it closes. Background work runs on
  change or on a slow timer, not on a fast poll; check with `--measure-idle` and `footprint`.
- Clean up after yourself: anything the app changes outside itself (Cmd-Tab, the screenshot keys,
  macOS's window tiling, device properties, Core Audio taps, `pmset disablesleep`) is restored on quit, on `kill`, and at the next launch if the
  app crashed.
- Comments say why, not what; match the surrounding density. Prose in the UI and README is plain and
  short, no marketing words.
- Permissions: Accessibility (mouse wheel and buttons, switcher, Window Layout, Finder cut and swipes, the capture's Content
  Only window style, Keep Awake's Stay available, whose posted events macOS drops without it), System Audio Recording (mixer), Screen Recording (capture, and the switcher's
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
.build/debug/Toolkit --snapshot out.png stats-bar [light]       # System Stats in each look and layout, from made-up readings
.build/debug/Toolkit --snapshot out.png stats-panel [cpu|memory|network|disk|gpu|power ...] [light]
.build/debug/Toolkit --snapshot out.png menu-bar-strip [light]  # the item in a drawn menu bar, for the top of the README
.build/debug/Toolkit --snapshot out.png layout-grid [light]     # the Window Layout grid over a drawn desktop
.build/debug/Toolkit --snapshot out.png layout-slots [light]    # its layouts bar while dragging
.build/debug/Toolkit --snapshot out.png layout-suggest [light]  # the windows it offers for the rest of a display
.build/debug/Toolkit --snapshot out.png layout-tabs [light]     # windows sharing a slot, with their tabs
.build/debug/Toolkit --snapshot out.png layout [tabs|keyboard] [light]  # that tab of the Window Layout page
.build/debug/Toolkit --test-capture <folder> [app]   # each screenshot kind and short recordings, with a report
.build/debug/Toolkit --test-recording        # the app's recording path: start, stop button, discard
.build/debug/Toolkit --test-layout [report]  # geometry, then a helper's windows placed for real (run with open -n)
.build/debug/Toolkit --measure-idle <file>   # memory idle, with the settings window, and after (run with open -n, app quit first)
.build/debug/Toolkit --test-wheel <report>   # one scroll notch through the installed app's wheel tap: what comes out (open -n)
.build/debug/Toolkit --test-menu-bar         # CPU per update of a real menu bar item, minus the idle loop
.build/debug/Toolkit --test-menu-bar-clicks  # every point across the item goes to the part it's over
.build/debug/Toolkit --test-menu-bar-idle    # each kind of part, in a real menu bar item, costs nothing left alone
.build/debug/Toolkit --test-menu-bar-widths  # each part keeps its width as its figure changes
.build/debug/Toolkit --test-menu-bar-tint <png>   # coloured text in a real menu bar item, captured (open -n; delete the png)
.build/debug/Toolkit --test-stats            # every stat read from this Mac, what a reading costs, and nothing read while off
.build/debug/Toolkit --test-stats-panels     # each stats panel costs nothing left alone
.build/debug/Toolkit --test-taps [report]    # a tap keeps up while the main thread is stuck (run with open -n)
.build/debug/Toolkit --test-awake <report>   # Keep Awake's assertion, times, lid rule (visudo) and one mouse drift (open -n)
.build/debug/Toolkit --test-nudge <report>   # which posted input resets the idle time chat apps read (open -n; leave the mouse alone)
.build/debug/Toolkit --test-settings        # export leaves out local-only settings; import merges and keeps the rest
.build/debug/Toolkit --test-shortcuts        # config migration, and which macOS screenshot shortcuts clash
.build/debug/Toolkit --test-toolbar          # the capture toolbar's panel against its content
.build/debug/Toolkit --test-overlay [png]    # what the capture overlay costs in memory; with open -n, a picture of it
.build/debug/Toolkit --test-highlight        # the window highlight sits right above its window
.build/debug/Toolkit --test-switcher-previews   # times the grid's pictures of real windows; keeps none
.build/debug/Toolkit --list-windows [--counts <file>]   # what the Window Switcher would list; with --counts, how many and the lookups it took
.build/debug/Toolkit --list-suggestions [file]  # per display, what Window Layout would offer for the rest
.build/debug/Toolkit --dump-menus <app> [file]  # an app's menu items with key equivalents and identifiers
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
  is one more than at the last release (a plain integer build number, never reset). The **Overview**
  page reads `CFBundleShortVersionString`, so don't hard-code a version anywhere else.
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
