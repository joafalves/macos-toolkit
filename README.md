# MacOS Toolkit

<img src="Resources/AppIcon-preview.png" width="96" alt="">

Personal macOS tooling, packaged as one menu bar app. Each tool is a section in the sidebar.

| Tool | What it does |
| --- | --- |
| Mouse Settings | Per-mouse cursor and wheel settings (SteerMouse-style), plus battery level. |
| Window Switcher | Replaces ⌘Tab with a list of windows instead of apps (AltTab-style). |
| Audio Mixer | A volume for each app, from the menu bar (like the Windows volume mixer). |

## Mouse Settings

Every setting has a **macOS** choice, meaning the toolkit leaves that behaviour to System Settings.

| Setting | Options | How |
| --- | --- | --- |
| Cursor speed | macOS / custom multiplier | `HIDPointerResolution` on the device's HID service |
| Cursor acceleration | macOS / off / custom (0–3) | `HIDMouseAcceleration` on the device's HID service |
| Wheel direction (vertical, horizontal) | macOS / inverted | scroll event tap |
| Wheel speed | macOS / custom multiplier | scroll event tap |
| Wheel acceleration | macOS / off / custom | `HIDMouseScrollAcceleration` on the device's HID service |
| Wheel smoothing | macOS / smooth | scroll event tap |
| Back and forward buttons | macOS / navigate | event tap; sends a navigation swipe to Apple apps |

Profiles are keyed by vendor ID, product ID and transport, and stored in
`~/Library/Application Support/MacOS Toolkit/mouse.json`.

Cursor settings need no permission. The wheel and button settings that go through the event tap
need **Accessibility**. Trackpad scrolling is never modified.

## Window Switcher

⌘Tab opens a list with one row per window, never grouped by app, across all Spaces and displays.
Rows are in most recently used order, so row 1 is the window you are in and a quick ⌘Tab goes
back to the previous one without showing the list at all. Minimized windows, hidden apps and
apps without a window come last, dimmed.

| Key (while ⌘ is held) | Action |
| --- | --- |
| ⇥ / ⇧⇥, ↓ / ↑ | Next / previous row |
| 1 – 9 | Go straight to that row |
| release ⌘, or click | Go to the selected row |
| esc | Cancel |
| W, M | Close / minimize the window |
| H, Q | Hide / quit the app |
| X | Quit every app that only has dimmed rows (hidden, no windows, or all minimized), except Finder |

The list opens on the main display, the display with the pointer, or the one with the active
window, as chosen in the settings.

It needs **Accessibility**, and relies on private macOS APIs to find windows on other Spaces,
to focus a single window, and to switch the system's own ⌘Tab off (it is switched back on when
the toolkit quits or the tool is turned off). ⌘` is left alone.

## Audio Mixer

**Audio Mixer** in the menu bar menu opens a panel with the main volume, the output device, and a
row for every Dock app that has sound open, playing or not (like the Windows mixer), so Spotify is
listed before you press play. Menu bar apps are listed only once they've played, since many keep
audio open without ever making a sound.
Apps playing right now come first, marked with moving bars, then the most recently heard. "Playing"
means actually making sound: many apps (paused Safari, Discord, games) keep their audio output running
in silence, so while an app's output runs the toolkit listens to it to tell sound from silence. Browser and Electron helper
processes are grouped under their app, and system sounds (Finder, Control Center, alerts) are left
out. Click the speaker at the start of a slider to mute.

- App volumes are **relative** to the main volume: an app at 50% plays at half the main volume, and
  the volume keys still change everything.
- **Reset** puts every app back to 100%, so they all follow the main volume again.
- Volumes are remembered per app (by bundle ID) and stored in
  `~/Library/Application Support/MacOS Toolkit/mixer.json`.
- Right-click an app to hide it until it plays again, or for **Never Touch**, which hides it for
  good and leaves its sound alone.
- The panel closes on a click anywhere else or with Esc.
- **Own menu bar icon** (in the mixer's settings) adds a separate mixer icon to the menu bar that
  opens the panel in one click; the toolkit menu then drops its Audio Mixer entry. The mixer's
  settings are under **Audio Mixer Settings…** in the toolkit menu either way.

macOS has no setting for one app's volume, so the mixer captures the app's sound with a Core Audio
process tap, which silences the original, and plays it again at the chosen volume. This needs
**System Audio Recording**, which macOS asks for the first time an app is turned down. Apps at 100%
and not muted play exactly as before: their sound is never rerouted, only listened to. A tapped app's sound is delayed by
about one audio buffer; the actual figure is written to the log when a tap starts
(`log stream --predicate 'process == "Toolkit"'`). Taps are removed when the toolkit quits, and any
left behind by a crash are removed at the next launch.

## Installing on a Mac

Needs macOS 15 or later. Nothing is downloaded prebuilt: the app is compiled on the Mac it runs on.

1. Install the Xcode Command Line Tools (skip if `swift --version` already works):

   ```bash
   xcode-select --install
   ```

2. Clone the repo (it is private, so sign in first with `gh auth login`):

   ```bash
   gh repo clone joafalves/macos-toolkit && cd macos-toolkit
   ```

3. Create the local signing identity. This is per Mac and only needed once; it lets macOS keep
   the app's permissions across rebuilds. macOS may ask for the login keychain password.

   ```bash
   ./scripts/make-cert.sh
   ```

4. Build, install to `/Applications` and launch:

   ```bash
   ./scripts/build.sh --install
   ```

5. In the app: **General → Grant Access…** and enable *MacOS Toolkit* under
   System Settings → Privacy & Security → Accessibility. Turn on **Launch at login** if wanted.
   System Audio Recording is asked for later, the first time you turn an app down in the mixer.

6. To carry settings over, use **General → Export…** on the old Mac and **Import…** on the new
   one. Mouse profiles are per mouse model and connection, so they apply as soon as the same
   mouse is connected.

To update later: `git pull && ./scripts/build.sh --install`.

`swift scripts/make-icon.swift` regenerates the app icon.

## Layout

- `Sources/Toolkit/App` — app shell: menu bar item, main window, general settings
- `Sources/Toolkit/Mouse` — the Mouse Settings tool
- `Sources/Toolkit/Switcher` — the Window Switcher tool
- `Sources/Toolkit/Mixer` — the Audio Mixer tool
