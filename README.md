<h1 align="center">
  <img src="Resources/AppIcon-preview.png" width="112" alt=""><br>
  MacOS Toolkit
</h1>

<p align="center">
  <b>The little things macOS never shipped, in one menu bar app.</b><br>
  A volume slider for every app. A ⌘Tab that lists windows. Windows snapped to halves or a grid,
  from the keyboard or by dragging. Mouse settings that stick, per mouse.
  ⌘X and a better right-click menu in Finder. Screenshots and small screen recordings on ⇧⌘3/4/5.
</p>

<p align="center">
  <a href="https://github.com/joafalves/macos-toolkit/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/joafalves/macos-toolkit?label=release&color=3478f6"></a>
  <img alt="macOS 15 or later" src="https://img.shields.io/badge/macOS-15%2B-555">
  <img alt="Swift, no dependencies" src="https://img.shields.io/badge/Swift-no%20dependencies-f05138">
</p>

<table>
  <tr>
    <td align="center" width="50%">
      <a href="#audio-mixer">
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="docs/images/mixer-dark.png">
          <img src="docs/images/mixer-light.png" width="380" alt="The audio mixer: main volume, output device and a slider for each app">
        </picture><br>
        <b>Audio Mixer</b>
      </a>
    </td>
    <td align="center" width="50%">
      <a href="#window-switcher">
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="docs/images/switcher-dark.png">
          <img src="docs/images/switcher-light.png" width="380" alt="The window switcher: one row per window">
        </picture><br>
        <b>Window Switcher</b>
      </a>
    </td>
  </tr>
  <tr>
    <td align="center" colspan="2">
      <a href="#window-layout">
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="docs/images/layout-grid-dark.png">
          <img src="docs/images/layout-grid-light.png" width="620" alt="The Window Layout grid over a display: a key on each cell, and the block picked with two keys highlighted">
        </picture><br>
        <b>Window Layout</b>
      </a>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <a href="#mouse-settings">
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="docs/images/mouse-dark.png">
          <img src="docs/images/mouse-light.png" width="380" alt="Mouse settings: cursor speed and acceleration, wheel direction, speed and smoothing">
        </picture><br>
        <b>Mouse Settings</b>
      </a>
    </td>
    <td align="center" width="50%">
      <a href="#finder">
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="docs/images/finder-dark.png">
          <img src="docs/images/finder-light.png" width="380" alt="Finder settings: cut and paste files, and the items added to the right-click menu">
        </picture><br>
        <b>Finder</b>
      </a>
    </td>
  </tr>
  <tr>
    <td align="center" colspan="2">
      <a href="#screen-capture">
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="docs/images/capture-toolbar-dark.png">
          <img src="docs/images/capture-toolbar-light.png" width="480" alt="The Screen Capture toolbar: display, window or area, screenshot or recording, options, and Capture">
        </picture><br>
        <b>Screen Capture</b>
      </a>
    </td>
  </tr>
</table>

I missed a few things from Windows and from third-party apps, and I didn't want three more apps
running to get them. So this is one small app, written in Swift with no dependencies, where each
tool is a section in the sidebar and (where it makes sense) an entry in the menu bar.

| Tool | What it does |
| --- | --- |
| 🎚️ **[Audio Mixer](#audio-mixer)** | A volume for each app, like the Windows volume mixer, plus an equalizer and volume control for outputs that have none. |
| 🪟 **[Window Switcher](#window-switcher)** | ⌘Tab lists *windows*, not apps (AltTab-style), across all Spaces. |
| 🔲 **[Window Layout](#window-layout)** | Rectangle's shortcuts for halves, quarters and thirds, a grid you place windows on with two keys, and snapping by dragging. |
| 🖱️ **[Mouse Settings](#mouse-settings)** | Cursor and wheel settings per mouse (SteerMouse-style), plus battery level. |
| 📁 **[Finder](#finder)** | ⌘X to cut files, and New Text File and Open in Terminal in the right-click menu. |
| 📸 **[Screen Capture](#screen-capture)** | ⇧⌘3/4/5 screenshots and screen recordings (CleanShot-style), with window backdrops and small H.264 files. |

Each tool can be turned off or left on its macOS defaults, and anything the app changes outside
itself is put back when it quits. No accounts, no telemetry, no network code. Settings are plain JSON in
`~/Library/Application Support/MacOS Toolkit`, and **General → Export…** saves them all to one file.

## Audio Mixer

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mixer-dark.png">
    <img src="docs/images/mixer-light.png" width="300" alt="The audio mixer panel: main volume, output device, and a slider for each app">
  </picture>
  &nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mixer-equalizer-dark.png">
    <img src="docs/images/mixer-equalizer-light.png" width="300" alt="The same panel with the five-band equalizer open">
  </picture>
</p>

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
- A **menu bar icon** of its own, one click away, set in the mixer's settings: none, the mixer glyph,
  **Volume**, a speaker that follows the volume and shows when it's muted, **Volume and
  percentage**, or **Volume badge**, a pill that fills with the volume like the battery, with the speaker and the
  number cut out of it.
- **The volume keys** go through the mixer on every output while it's on, so they always behave the
  same: 5% a press (1% with ⇧⌥), mute toggles, and the toolkit's own on-screen bar in place of
  macOS's. On outputs with a volume of their own that volume is set directly; on the rest it's the
  software volume. ⌥ with a volume key still opens Sound settings. Needs **Accessibility**.
- **Software volume** for outputs that have no volume control of their own (see below).
- An **equalizer** under the main volume: five bands (60 Hz to 12 kHz, ±12 dB) with presets such as
  Bass Boost, Vocal, Loudness and Late Night. Drag a band, or double-click it for 0 dB. While it's on
  and not flat, all sound goes through the toolkit, the same way as the software volume, so macOS
  shows its recording indicator. Strong boosts are kept from clipping with a little headroom and a
  soft limiter.

### Outputs with no volume control

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mixer-outputs-dark.png">
    <img src="docs/images/mixer-outputs-light.png" width="300" alt="The mixer with the output device list open">
  </picture>
</p>

Many monitors over HDMI or DisplayPort show up in macOS with no volume at all: the slider is greyed
out and the volume keys show a "not allowed" icon. For those outputs the mixer takes over:

- The **main slider** works there too, marked with a small chip icon.
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
to the previous one without showing the list at all. When the list does appear, the previous window
is selected, or the one you're in with **Open on the previous window** off. Minimized windows, hidden apps and apps without
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

### Previews

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/switcher-grid-dark.png">
    <img src="docs/images/switcher-grid-light.png" width="620" alt="The window switcher as a grid: a picture of each window with its app and title along the bottom">
  </picture>
</p>

With **Style: Previews** in the settings, the list becomes a grid with a picture of each window, its
app and title along the bottom. ← → step through the tiles, ↑ ↓ go to the row above and below, and
the other keys work as in the list. Minimized windows keep their last picture, dimmed; hidden apps
and apps without a window show their icon.

- **Size**: Small, Medium or Large is the largest a tile gets, and tiles shrink when there are more
  windows than fit, so there's never any scrolling. **Fit** makes them as large as the display allows.
- **Pictures**: **Cached** shows the last picture of each window at once and a new one a moment later,
  **Fresh** shows the app's icon until the new picture arrives, and **Live** keeps them updating
  while the switcher is open (more power).
- Pictures are only taken while the switcher is on screen, so a quick ⌘Tab takes none, and they're
  kept in memory only. They need the **Screen Recording** permission; without it the switcher shows
  the list.

⌘Tab is the default; the shortcut can be changed in the settings to any key with ⌘, ⌥ or ⌃. Its
modifiers are what you hold to keep the list open, and ⇧ goes backwards. With a shortcut other than
⌘Tab, macOS's own app switcher keeps working alongside.

It needs **Accessibility**, and relies on private macOS APIs to find windows on other Spaces, to
focus a single window, and to switch the system's own ⌘Tab off while the switcher has it. That is
switched back on when the toolkit quits or the tool is turned off.

## Window Layout

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/layout-grid-dark.png">
    <img src="docs/images/layout-grid-light.png" width="620" alt="The grid over a display: a key on each cell, the block from Q to D highlighted, the window's name at the top and the keys at the bottom">
  </picture>
  <br><br>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/layout-dark.png">
    <img src="docs/images/layout-light.png" width="520" alt="Window Layout settings: the grid shortcut and each display's grid">
  </picture>
</p>

Snaps the focused window to part of its display. The keys are Rectangle's, so coming from it nothing
changes; each one can be changed or cleared in the settings.

| Key | Action |
| --- | --- |
| ⌃⌥ ← → | Left or right half. Again to move it on to the next display that way, as its near half. At the outer edge it stops, or goes through ⅔ and ⅓ with **Sizes at the outer edge** on |
| ⌃⌥↑ | Top half. Again to maximize, and again to move it, maximized, to the display above |
| ⌃⌥↓ | Bottom half, maximized windows too. Again to move it to the top half of the display below |
| ⌃⌥ U I J K | Top left, top right, bottom left, bottom right quarter |
| ⌃⌥ D F G | First, center, last third (down the display on one that stands upright) |
| ⌃⌥ E T | First, last two thirds |
| ⌃⌥↩ | Maximize. Almost maximize (nine tenths, centred) is there too, without a key |
| ⌃⌥⇧↑ | Maximize the height, keeping the width |
| ⌃⌥C | Center |
| ⌃⌥= ⌃⌥- | Larger, smaller: 30 points on every side |
| ⌃⌥⌫ | Restore the size and place it had before it was snapped |
| ⌃⌥⌘ ← → | Previous, next display. A snapped window stays snapped the same way |

The arrows go by where the window is, however it got there: a window you maximized yourself goes
straight to the display above with ⌃⌥↑, and one already at the left half moves on to the display on
the left with ⌃⌥←.

### The grid

**⌃⌥⌘Space** lays a grid over the display with the focused window, a key on each cell. Type the key
of one corner, then the key of the opposite corner, and the window fills that block: on the 4 × 3
grid like the one above, Q then D is three quarters wide and two thirds high.

| Key (in the grid) | Action |
| --- | --- |
| two letter keys | One corner, then the other. The same key twice is one cell |
| ← → ↑ ↓ | Move the selection |
| ⇧ ← → ↑ ↓ | Grow or shrink it |
| ↩ or space | Place the window |
| ⌫ | Start the corners again |
| ⇥ | Move the grid to the next display, to send the window there |
| esc | Cancel |

Dragging across the cells with the mouse works too.

- The keys go by **where they sit on the keyboard**, not by letter: the top left cell is always the
  key right of Tab, on any keyboard layout, and the cells show what your layout types there. Up to
  three rows use the letter rows; a fourth adds the number row.
- **Each display has its own grid**, up to 10 columns and 4 rows, set in the settings. Until it has
  one, a display gets halves (2 × 1), an ultrawide quarters (4 × 1), and one standing upright 1 × 2.
  Grids are kept per monitor, so two monitors that take turns on the same cable each keep theirs.

### Dragging

- **Snap at the edges**: drag a window to a side of the display or the bottom for half of it, to a
  corner for a quarter, or to the top to fill it. A preview shows where it will go. The menu bar and
  the Dock count as part of their edge, so the top snaps as soon as the pointer reaches the menu bar.
  Sides against another display snap too, in a strip 24 points wide (8 at the outer edges): stop
  short of the edge and let go. Keep going and the window crosses over as usual.
- **Layouts while dragging**: hold ⌥ while dragging and a bar of small layouts appears by the
  pointer: the whole display, halves both ways, thirds, ⅔ and ⅓, quarters, and on an ultrawide
  fourths and a wide middle. Move onto a part of one, and the screen shows where the window will go;
  let go to put it there.
- **Grid while dragging**: hold ⇧ while dragging and the grid appears. The cell under the pointer
  is one corner: move to the other and let go. Let go of ⇧ to start the corners again.
- **Esc** during the drag drops the window where it is, without snapping. Both keys can be changed
  or turned off in the settings.
- **Stop at the edge between displays** (off unless turned on): while a window is dragged, the
  pointer stops where one display meets another, so the snap on that edge is easy to hit. Moving
  away or along the edge lets go at once, and pushing on for a moment crosses over. Once through,
  the rest of that drag moves freely between the displays. A
  fast flick is held as long as a steady push. Only while dragging; the pointer moves between
  displays as usual otherwise.
- A snapped window you drag away gets back the size it had before, with the pointer at the same
  place on it.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/layout-slots-dark.png">
    <img src="docs/images/layout-slots-light.png" width="620" alt="A window being dragged with ⌥ held: a bar of small layouts by the pointer, the ⅔ part of one picked, and the left two thirds of the display highlighted">
  </picture>
</p>

A **gap** of up to 40 points can go between windows and around the edges. A window that can't take
the size (it has a minimum, or can't be resized) gets as close as it goes, centred on the spot.
Windows in full screen, panels, dialogs and sheets are left alone.

It needs **Accessibility**. While any kind of dragging is on, macOS's own tiling by dragging
(System Settings → Desktop & Dock → Windows) is switched off. Turning the tool or its dragging off
turns macOS's tiling on, so windows still snap; when the toolkit quits, it's put back as it was. If Rectangle is running, the settings offer to quit it, since the
two would fight over the same keys and drags.

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

## Finder

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/finder-dark.png">
    <img src="docs/images/finder-light.png" width="520" alt="Finder settings: cut and paste files, and the items added to the right-click menu">
  </picture>
</p>

Finder has no Cut. The usual way to move files with the keyboard is ⌘C, then ⌥⌘V ("Move Item Here")
in the destination. This does it with ⌘X and ⌘V:

1. Select files in Finder and press **⌘X** (or choose **Cut** from the right-click menu). They are
   copied, and marked as a cut.
2. Open the destination and press **⌘V**. Finder moves them there instead of copying.

Only keys pressed while Finder is in front are touched, and not while a name or the search field is
being edited, where ⌘X and ⌘V keep their text meaning. Copying anything else in between cancels the
cut, and a ⌘V somewhere other than Finder just pastes a copy. Finder can't dim the cut files the way
Windows does, so a short sound says the cut worked instead. Cut needs **Accessibility**.

The right-click menu gets these items, each of which can be turned off in the Finder settings:

| Item | What it does |
| --- | --- |
| Cut | The same as ⌘X, on the files you right-clicked. |
| New Text File | Makes an empty `untitled.txt` in the folder and starts renaming it (the rename needs **Accessibility**). |
| Open in Terminal | Opens a terminal in the folder you clicked, or the one you're in. The item is named after the terminal: Ghostty, iTerm or Terminal, the first one installed, or the one picked in the settings. |

The menu comes from a **Finder extension** inside the app. macOS keeps new Finder extensions off, so
turn it on once with **Turn On** in the Finder settings (or under System Settings → General → Login
Items & Extensions). The extension runs in its own sandboxed process and only builds the menu and
hands each choice to the app, which does the work. Creating a file in a protected folder such as
Documents may make macOS ask for access the first time.

## Screen Capture

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/capture-toolbar-dark.png">
    <img src="docs/images/capture-toolbar-light.png" width="480" alt="The Screen Capture toolbar">
  </picture>
  <br><br>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/capture-dark.png">
    <img src="docs/images/capture-light.png" width="520" alt="Screen Capture settings: shortcuts, screenshot folder and format">
  </picture>
</p>

It takes over macOS's screenshot keys, with the same habits, and adds screen recordings small
enough to paste into a chat or a GitHub issue. The keys below are the defaults; each one can be
changed or cleared in the settings, and ⌃ added to the display or area shortcut always copies.

| Key | Action |
| --- | --- |
| ⇧⌘3 | Screenshot of the display under the pointer |
| ⇧⌘4 | Drag out an area. **Space** switches to clicking a window |
| ⇧⌘5 | The toolbar: display, window or area, screenshot or recording, timer and options. Stops a recording |
| hold ⌃ | Copy to the clipboard instead of saving a file. It counts if it's held when the capture happens, so it can be pressed mid-drag |
| esc | Cancel |

- **Screenshots** are saved to `~/Pictures/Capture` (or a folder you pick) as PNG, JPEG or HEIC.
  With ⌃ they go to the clipboard instead, and optionally to the folder as well. A thumbnail shows
  in the corner: drag it into an app, click it to open it, or let it go.
- **Windows** come out in one of three styles, picked in the toolbar's options: **Content Only**
  (without the title bar and toolbar, found through Accessibility; apps that draw their own title
  bar may keep part of it), **Plain** (no shadow), or **With Backdrop**: the window with a soft
  shadow on a blurred piece of your desktop picture or a solid color.
- **Recordings** are H.264 MP4, which plays inline almost everywhere, at 30 fps (15 and 60 in the
  settings). Three qualities: **Standard** records at point size (a quarter of the pixels on a
  Retina display) for small files, **High** keeps every pixel so small text stays sharp while it
  scrolls, and **Maximum** has detail to spare for code and tutorials. The settings show what a
  minute of constant motion costs on your display; frames are only written when something changes,
  so a mostly still screen costs far less. Optional system audio and microphone (mixed into one
  track), cursor and click rings. A window recording follows the window when it moves, and windows
  on top of it don't show.
- While recording, the menu bar shows a **stop button with the time and size** so far. Right-click
  it to pause, resume or discard. ⇧⌘5 stops too. When it stops, the file is saved to
  `~/Movies/Capture` (or a folder you pick) and put on the clipboard as a file, ready to paste.
- The toolbar remembers the last area. The toolkit's own toolbar, outline and thumbnails never show
  up in a capture.
- Optionally gets **its own icon** in the menu bar, which opens the toolbar.

It needs the **Screen Recording** permission (and the microphone one, if you turn the mic on). macOS
asks again every so often to confirm it for apps that aren't Apple's. macOS's own screenshot
shortcuts are switched off only where they clash with the toolkit's, and back on when the toolkit
quits or the tool is turned off.

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
  Accessibility. This is for the window switcher, Window Layout, the Finder cut, and the mouse wheel and button settings.
- System Audio Recording is asked for later, the first time you turn an app down in the mixer, and
  Screen Recording the first time you take a screenshot.
- For the Finder right-click menu, press **Turn On** in the Finder settings.
- Turn on **Launch at login** if you want it always there.
- To carry your settings to another Mac, use **General → Export…** and **Import…**.

To remove it, quit the app, delete it from `/Applications`, and delete
`~/Library/Application Support/MacOS Toolkit`.

## Good to know

- It uses **private macOS APIs** (window discovery for the switcher, the permission check for the
  mixer, grouping helper processes under their app, switching off the system's ⌘Tab and screenshot
  keys). They can change in any macOS update, and this
  is a personal tool, so expect to rebuild when they do.
- It is **not notarized**, which is why the install steps above remove the quarantine flag.
- Anything the toolkit changes outside itself (⌘Tab, the screenshot keys, macOS's window tiling,
  device properties, audio taps) is put back when it quits, when it is killed, and at the next launch if it crashed.

## Project layout

```
Sources/Toolkit
├── App        menu bar items, main window, general settings, settings export
├── Mouse      the Mouse Settings tool
├── Switcher   the Window Switcher tool
├── Layout     the Window Layout tool
├── Mixer      the Audio Mixer tool
├── Finder     the Finder tool
├── Capture    the Screen Capture tool
└── UI         shared settings-page components
Sources/FinderExtension   the Finder extension behind the right-click menu
scripts        build.sh, make-cert.sh, make-icon.swift
docs/images    the screenshots above
```

What each version added and fixed is in [`CHANGELOG.md`](CHANGELOG.md). A tool is a controller plus a config, stored as JSON. [`AGENTS.md`](AGENTS.md) has the conventions,
the dev flags (`--snapshot` renders any page to an image, `--list-windows` and `--list-audio` print
what the tools see, `--test-capture` runs the screenshot and recording code without the UI, `--test-layout` places a helper's windows), and how versions and releases are made.
