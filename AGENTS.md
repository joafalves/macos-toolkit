# MacOS Toolkit

Personal macOS tooling, packaged as one menu bar app. Each tool is a section in the sidebar of the
main window, and some also live in the menu bar. `README.md` is the user-facing description of every
tool; keep it in step with the code.

## Stack

- Swift 5 language mode, SwiftUI plus AppKit, Swift Package Manager (`Package.swift`, one executable
  target, `Sources/Toolkit`). macOS 15+, Apple silicon. No dependencies, no Xcode project.
- Built with the Command Line Tools only (`swift build`), then wrapped into an app bundle by
  `scripts/build.sh`. The app runs as an accessory (menu bar) app and only shows a Dock icon while its
  main window is open.
- Uses private APIs on purpose: SkyLight and others for the Window Switcher, TCC for the audio
  permission check, `responsibility_get_pid_responsible_for_pid` for grouping helper processes.

## Layout

- `Sources/Toolkit/App`: shell. `main.swift` (dev flags, single instance), `AppDelegate` (menu bar
  items, the mixer popover, the main window), `AppModel` (`AppSection`, the sidebar sections),
  `MainView`, `SettingsTransfer` (export and import of all settings), `Snapshot`.
- `Sources/Toolkit/Mouse`, `Switcher`, `Mixer`: one folder per tool.
- `Sources/Toolkit/UI/Components.swift`: shared settings-page building blocks (`Page`, `Card`,
  `SettingRow`, `ToggleRow`, `Banner`, `ViewState`, ...). Use these rather than new ad-hoc styling.
- `Resources`: `Info.plist` (the only place the version lives), app icon.
- `scripts`: `build.sh`, `make-cert.sh` (local signing identity), `make-icon.swift`.
- `docs/images`: the README's screenshots, all rendered with `--snapshot`. The mixer and switcher
  use made-up rows; the mouse one is cropped below the header so the real device name stays out.

## Conventions

- **A tool = a controller plus a config.** The controller is an `ObservableObject` that owns a
  `@Published var config` whose `didSet` saves it and applies the change. The config is a `Codable`
  struct with a tolerant `init(from:)` (every key optional, with a default) stored as JSON in
  `~/Library/Application Support/MacOS Toolkit/<tool>.json`.
- **Adding a tool:** a case in `AppSection` (title, symbol), a view in `MainView`, a field in
  `SettingsFile` (optional, so old exports still import), a section in `README.md`.
- **Settings pages** use `Page` and `Card`. Controls that change behaviour go through the config.
- **`@State` does not compile** here: in the macOS 27 SDK it is a macro and the Command Line Tools lack
  its plugin. Use `@StateObject private var x = ViewState(value)` instead (`ViewState` is in
  `Components.swift`). `@GestureState` and `@StateObject` are fine.
- Clean up after yourself: anything the app changes outside itself (Cmd-Tab, device properties,
  Core Audio taps) is restored on quit, on `kill`, and at the next launch if the app crashed.
- Comments say why, not what; match the surrounding density. Prose in the UI and README is plain and
  short, no marketing words.
- Permissions: Accessibility (mouse wheel and buttons, switcher) and System Audio Recording (mixer).
  The app is signed with a local self-signed identity (`MacOS Toolkit Dev`) so macOS keeps the grants
  across rebuilds; ad-hoc signing makes macOS forget them.

## Building and checking

```bash
swift build                                  # compile check
./scripts/build.sh                           # build "build/MacOS Toolkit.app"
./scripts/build.sh --install                 # also copy to /Applications and relaunch
.build/debug/Toolkit --snapshot out.png [mouse|switcher|mixer|general] [light]
.build/debug/Toolkit --snapshot out.png mixer-popover [light] [outputs] [software]
.build/debug/Toolkit --list-windows          # what the Window Switcher would list
.build/debug/Toolkit --list-audio            # what the Audio Mixer sees
```

There is no test suite. Check UI changes by rendering `--snapshot` images in both light and dark and
looking at them, and check behaviour by running the installed app. Keep idle CPU near zero: a hidden
SwiftUI view that animates still costs CPU, and Core Audio taps show macOS's purple recording
indicator, so run them only when needed.

## Versions and releases

Version `X.Y.Z` follows semver: a new tool or user-visible feature bumps the minor (`0.2.0`), a fix
bumps the patch (`0.1.2`).

**Every change that ships a new version updates all of these together:**

1. `Resources/Info.plist`: `CFBundleShortVersionString` to `X.Y.Z`, and `CFBundleVersion` up by one
   (a plain integer build number, never reset).
2. The version text shown in the app: **General** page header ("Version X.Y.Z") reads
   `CFBundleShortVersionString`, so it follows the plist; don't hard-code a version anywhere else.
   Search for the old version with `grep -rIn "<old>" . --exclude-dir=.git --exclude-dir=.build --exclude-dir=build`
   and update any other hit (README, docs).
3. `README.md`: the tool table, the tool's section, and the project layout tree if a folder was added.
   If a page changed visibly, render new screenshots into `docs/images` (a `-light` and a `-dark`
   image each, from `--snapshot`) so the README doesn't show an old UI.
4. Commit as `chore: release X.Y.Z` and tag `vX.Y.Z` on that commit.

To publish (only when asked; it pushes to GitHub):

```bash
./scripts/build.sh
ditto -c -k --keepParent --norsrc "build/MacOS Toolkit.app" "MacOS-Toolkit-X.Y.Z.zip"
git push origin main vX.Y.Z
gh release create vX.Y.Z "MacOS-Toolkit-X.Y.Z.zip" --title "X.Y.Z" --notes-file notes.md
```

The release is named `X.Y.Z` with tag `vX.Y.Z`. Notes list the user-visible changes as bold tool names
with a sentence each, then the install block from the previous release (unzip into `/Applications`,
`xattr -dr com.apple.quarantine`, grant Accessibility; the app is self-signed, not notarized),
ending with the Claude Code attribution line. Delete the zip and notes file afterwards.

## Git

Conventional commit subjects (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`), lowercase, no period;
a body when the why isn't obvious. Commit to `main` directly for this personal repo, unless asked for
a branch. Don't push, tag-and-push or publish a release without being asked.
