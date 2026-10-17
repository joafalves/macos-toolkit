<h1 align="center">
  <img src="Resources/AppIcon-preview.png" width="112" alt=""><br>
  MacOS Toolkit
</h1>

<p align="center">
  <b>The little things macOS never shipped, in one menu bar app.</b><br>
  A volume slider for every app. A ⌘Tab that lists windows. Mouse settings that stick, per mouse.
</p>

<p align="center">
  <a href="https://github.com/joafalves/macos-toolkit/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/joafalves/macos-toolkit?label=release&color=3478f6"></a>
  <img alt="macOS 15 or later" src="https://img.shields.io/badge/macOS-15%2B-555">
  <img alt="Swift, no dependencies" src="https://img.shields.io/badge/Swift-no%20dependencies-f05138">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mixer-dark.png">
    <img src="docs/images/mixer-light.png" width="300" alt="The audio mixer panel: main volume, output device, and a slider for each app">
  </picture>
  &nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mixer-outputs-dark.png">
    <img src="docs/images/mixer-outputs-light.png" width="300" alt="The same panel with the output device list open">
  </picture>
</p>

I missed a few things from Windows and from third-party apps, and I didn't want three more apps
running to get them. So this is one small app, written in Swift with no dependencies, where each
tool is a section in the sidebar and (where it makes sense) an entry in the menu bar.

| Tool | What it does |
| --- | --- |
| 🎚️ **[Audio Mixer](#audio-mixer)** | A volume for each app, like the Windows volume mixer. |
| 🪟 **[Window Switcher](#window-switcher)** | ⌘Tab lists *windows*, not apps (AltTab-style). |
| 🖱️ **[Mouse Settings](#mouse-settings)** | Cursor and wheel settings per mouse (SteerMouse-style), plus battery level. |

No accounts, no telemetry, no network code. Settings are plain JSON in
`~/Library/Application Support/MacOS Toolkit`.

## Audio Mixer

macOS has one volume for everything. The mixer adds the missing part: open it from the menu bar and
every app that has sound gets its own slider.

- **Main volume and output device** at the top, so it replaces a trip to Control Center.
- **A row per app**: every Dock app that has sound open (so Spotify is there before you press play),
  and menu bar apps once they've actually played. Apps making sound right now come first, with
  moving bars. Browser and Electron helpers are folded into their app.
- **Relative to the main volume**: an app at 50% plays at half of whatever the main volume is, and
  the volume keys still move everything.
- **Click an app's icon or row to mute** (0% counts as muted, and unmuting restores where it was).
- **Reset** puts every app back to 100%, so they all follow the main volume again.
- Volumes are remembered per app. Right-click an app to hide it until it plays again, or to
  **Never Touch** it.
- Optionally gets **its own icon** in the menu bar, one click away, in the mixer's settings.
- **Software volume** for outputs that have no volume control of their own (see below).
- An **equalizer** under the main volume: five bands (60 Hz to 12 kHz, ±12 dB) with presets such as
  Bass Boost, Vocal, Loudness and Late Night. Drag a band, or double-click it for 0 dB. While it's on
  and not flat, all sound goes through the toolkit, the same way as the software volume, so macOS
  shows its recording indicator. Strong boosts are kept from clipping with a little headroom and a
  soft limiter.

### Outputs with no volume control

Many monitors over HDMI or DisplayPort show up in macOS with no volume at all: the slider is greyed
out and the volume keys show a "not allowed" icon. For those outputs the mixer takes over:

- The **main slider** works, marked with a small chip icon, and the **volume keys** (up, down, mute,
  5% a press, 1% with ⇧⌥) are caught and show a small on-screen bar. Outputs that have a volume of
  their own are left to macOS, keys and all.
- It lowers the sound in software: one tap on everything that plays to that output, scaled down and
  played again. Per-app volumes keep working on top. Each output remembers its own volume.
- The tap stays up at 100%, passing the sound through untouched, because taking it down there would
  reroute the audio mid-playback and click. So for as long as it is on, macOS shows its purple
  recording indicator and the sound is delayed by about one audio buffer.
- It needs the **System Audio Recording** permission and, for the keys, **Accessibility**. It is
  built for macOS 26 and later; on macOS 15 it may not start.
- Turn it off in the mixer's settings under **Software volume**.

<details>
<summary><b>How it works, and what it costs</b></summary>

<br>

macOS has no setting for one app's volume, so the mixer uses Core Audio *process taps*: it captures
an app's sound (which silences the original) and plays it again at the volume you chose. That needs
the **System Audio Recording** permission, which macOS asks for the first time you turn an app down.

- Apps at 100% and not muted are never rerouted. They play exactly as before. An app put back to
  100% keeps its tap until its sound stops, and so does the equalizer when it's turned off, because
  removing a tap mid-playback reroutes the audio and clicks.
- To tell real sound from an app that keeps its output open in silence (a paused Safari tab, Discord,
  games), the panel listens to each running app, but only while it is open.
- macOS shows its purple recording indicator whenever a tap runs. Outside the panel that means only
  while an app you turned down or muted is making sound.
- A tapped app's sound is delayed by about one audio buffer, a few milliseconds on built-in and wired
  outputs. The real figure is logged when a tap starts
  (`log stream --predicate 'process == "Toolkit"'`). Bluetooth outputs may add more; I haven't
  measured that.
- Taps are removed when the toolkit quits, and any a crash left behind are removed at the next launch.
  Volumes are stored in `mixer.json`.

</details>

## Window Switcher

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/switcher-dark.png">
    <img src="docs/images/switcher-light.png" width="520" alt="The window switcher: one row per window, the selected row highlighted, minimized and hidden ones dimmed at the bottom">
  </picture>
</p>

⌘Tab opens a list with **one row per window**, never grouped by app, across all Spaces and displays.
Rows are in most recently used order, so row 1 is the window you are in, and a quick ⌘Tab goes back
to the previous one without showing the list at all. Minimized windows, hidden apps and apps without
a window come last, dimmed.

| Key (while ⌘ is held) | Action |
| --- | --- |
| ⇥ / ⇧⇥, ↓ / ↑ | Next / previous row |
| 1 – 9 | Go straight to that row |
| release ⌘, or click | Go to the selected row |
| esc | Cancel |
| W, M | Close / minimize the window |
| H, Q | Hide / quit the app |
| X | Quit every app that only has dimmed rows (hidden, no windows, or all minimized), except Finder |

The list opens on the main display, the display with the pointer, or the one with the active window,
as you choose in the settings. ⌘\` is left alone.

It needs **Accessibility**, and relies on private macOS APIs to find windows on other Spaces, to
focus a single window, and to switch the system's own ⌘Tab off. That is switched back on when the
toolkit quits or the tool is turned off.

## Mouse Settings

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mouse-dark.png">
    <img src="docs/images/mouse-light.png" width="520" alt="Mouse settings: cursor speed and acceleration, wheel direction, speed, acceleration and smoothing">
  </picture>
</p>

Every setting has a **macOS** choice, meaning the toolkit leaves that behaviour to System Settings.
Profiles are per mouse, keyed by vendor ID, product ID and transport, so your settings come back as
soon as the same mouse is connected.

| Setting | Options | How |
| --- | --- | --- |
| Cursor speed | macOS / custom multiplier | `HIDPointerResolution` on the device's HID service |
| Cursor acceleration | macOS / off / custom (0–3) | `HIDMouseAcceleration` on the device's HID service |
| Wheel direction (vertical, horizontal) | macOS / inverted | scroll event tap |
| Wheel speed | macOS / custom multiplier | scroll event tap |
| Wheel acceleration | macOS / off / custom | `HIDMouseScrollAcceleration` on the device's HID service |
| Wheel smoothing | macOS / smooth | scroll event tap |
| Back and forward buttons | macOS / navigate | event tap; sends a navigation swipe to Apple apps |

Cursor settings need no permission. The wheel and button settings that go through the event tap need
**Accessibility**. Trackpad scrolling is never modified.

## Install

Needs **macOS 15 or later**. The released app is built for Apple silicon.

### Download

1. Grab `MacOS-Toolkit-<version>.zip` from the [latest release](https://github.com/joafalves/macos-toolkit/releases/latest).
2. The app is signed with a self-signed certificate, not an Apple Developer ID, so remove the
   quarantine flag after unzipping:

   ```bash
   unzip ~/Downloads/MacOS-Toolkit-*.zip -d /Applications
   xattr -dr com.apple.quarantine "/Applications/MacOS Toolkit.app"
   open "/Applications/MacOS Toolkit.app"
   ```

### Build it yourself

You only need the Xcode Command Line Tools (`xcode-select --install`, skip if `swift --version`
already works).

```bash
git clone https://github.com/joafalves/macos-toolkit.git && cd macos-toolkit
./scripts/make-cert.sh          # once per Mac: a local signing identity, so macOS keeps the permissions across rebuilds
./scripts/build.sh --install    # builds, copies to /Applications and launches
```

To update later: `git pull && ./scripts/build.sh --install`.

### First run

- **General → Grant Access…** and enable *MacOS Toolkit* under System Settings → Privacy & Security →
  Accessibility. This is for the window switcher and the mouse wheel and button settings.
- System Audio Recording is asked for later, the first time you turn an app down in the mixer.
- Turn on **Launch at login** if you want it always there.
- To carry your settings to another Mac, use **General → Export…** and **Import…**.

To remove it, quit the app, delete it from `/Applications`, and delete
`~/Library/Application Support/MacOS Toolkit`.

## Good to know

- It uses **private macOS APIs** (window discovery for the switcher, the permission check for the
  mixer, grouping helper processes under their app). They can change in any macOS update, and this
  is a personal tool, so expect to rebuild when they do.
- It is **not notarized**, which is why the install steps above remove the quarantine flag.
- Anything the toolkit changes outside itself (⌘Tab, device properties, audio taps) is put back when
  it quits, when it is killed, and at the next launch if it crashed.

## Project layout

```
Sources/Toolkit
├── App        menu bar items, main window, general settings, settings export
├── Mouse      the Mouse Settings tool
├── Switcher   the Window Switcher tool
├── Mixer      the Audio Mixer tool
└── UI         shared settings-page components
scripts        build.sh, make-cert.sh, make-icon.swift
docs/images    the screenshots above
```

A tool is a controller plus a config, stored as JSON. [`AGENTS.md`](AGENTS.md) has the conventions,
the dev flags (`--snapshot` renders any page to an image, `--list-windows` and `--list-audio` print
what the tools see), and how versions and releases are made.
