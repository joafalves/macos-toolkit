# Changelog

What each version adds, changes and fixes, newest first. The version at the top is the one being
worked on; it gets its date when it's released.

## 0.9.0 (2026-10-21)

### Added

- **Window Layout:** a new tool, in place of Rectangle. Rectangle's shortcuts for halves, quarters,
  thirds, maximize, almost maximize, maximize height, center, larger, smaller, restore, and the
  previous and next display. The arrows go by where the window is: ⌃⌥← → move it on across the
  displays half by half, ⌃⌥↑ maximizes and then moves it up a display, ⌃⌥↓ takes it down.
- **Window Layout:** ⌃⌥⌘Space lays a grid over the display; two keys pick the corners, by their
  place on the keyboard on any layout. Arrows and ⇧ arrows move and grow the selection, ⇥ goes to the
  next display, and dragging across the cells works too. Each display keeps its own grid: halves by
  default, quarters on an ultrawide.
- **Window Layout:** drag a window to an edge or a corner to snap it; the menu bar and the Dock count
  as part of their edge, and edges between displays snap too. Hold ⌥ while dragging for a bar of
  layouts by the pointer, or ⇧ for the grid. Esc drops the window without snapping. A snapped window
  dragged away gets its old size back, with the pointer at the same place on it.
- **Window Layout:** optional sizes at the outer edge (½, ⅔, ⅓) and an optional stop at the edge
  between displays while dragging, once per drag. A gap between windows of up to 40 points.
- **Window Layout:** macOS's own tiling by dragging is off while the tool's dragging is on, and turned
  back on when it's turned off.
- **Audio Mixer:** two more menu bar icons: the speaker with the volume next to it, and a badge that
  fills with the volume.

### Changed

- **Audio Mixer:** opening the mixer from the menu bar no longer brings the settings window to the
  front. Esc closes it from any app.
- **Settings window:** let go of when it's closed, and it opens again where it was.
- **Screen Capture:** a cleaner selection: a crisp edge, round knobs at the corners, pills on the
  sides, and the size in a pill under the corner.
- **Menu bar:** one item for the whole toolkit. The toolkit menu, Screen Capture and the Audio
  Mixer sit side by side in it with hairlines between them, move together, share macOS's highlight,
  and can't be split up by other apps' icons. While one part's menu or panel is open, the others dim.
- **Every tool that reads the keyboard or mouse** (Window Switcher, Finder, Mouse Settings, Audio
  Mixer's volume keys, Window Layout's dragging) does so on a thread of its own, so a busy moment in
  the toolkit can no longer hold up typing or scrolling.
- **Window Switcher:** finds windows on other Spaces with a fifth of the work at login and when apps
  open.
- **Mouse Settings:** looks for mice only when one comes or goes (and once a minute), and reads
  battery levels every half minute, so it uses less CPU while idle.

### Fixed

- **Finder:** the right-click menu's actions are only accepted from the toolkit's own Finder
  extension, and only ever on folders. Before, another app could ask the toolkit to open a file in
  the terminal, which runs it.
- **Screen Capture:** the area's knobs show resize cursors straight away, and the area a hand,
  instead of the crosshair.
- **Screen Capture:** the selection overlay no longer takes about 100 MB while it's up (it held a
  picture of each display), and follows the mouse smoothly.
- **Window Layout, Window Switcher, Screen Capture, Finder:** an app answering Accessibility with
  something unexpected can no longer upset them.

## 0.8.0 (2026-10-20)

### Added

- **Window Switcher:** a Previews style, a grid with a picture of each window, its app and title.
  Small, Medium, Large or Fit tiles; Cached, Fresh or Live pictures. Needs Screen Recording.

### Changed

- **Window Switcher:** Open on the previous window can be turned off.

## 0.7.0 (2026-10-20)

### Added

- **Every tool:** an Enabled switch at the top of its page. Mouse Settings and Finder can be turned
  off as a whole.
- **Window Switcher:** the shortcut can be changed from ⌘Tab.
- **Screen Capture:** each shortcut can be changed or cleared, and recordings come in three
  qualities, with the cost of a minute shown.
- **Audio Mixer:** the menu bar icon can be the mixer or a speaker that follows the volume, and the
  volume keys go through the mixer on every output.

### Fixed

- **Screen Capture:** the toolbar could be empty, recording could crash, the window highlight sat
  off its window, and Discard touched the clipboard.

## 0.6.0 (2026-10-20)

### Added

- **Screen Capture:** a new tool. ⇧⌘3, ⇧⌘4 and ⇧⌘5 for screenshots of the display, an area or a
  window, ⌃ to copy, window styles with a backdrop, and small H.264 recordings from the toolbar.

### Fixed

- **Screen Capture:** ⌃ is read reliably, and the overlay takes clicks on its clear parts.

## 0.5.0 (2026-10-18)

### Added

- **Finder:** a new tool. ⌘X and ⌘V to move files, and Cut, New Text File and Open in Terminal in
  the right-click menu, through a Finder extension.

## 0.4.1 (2026-10-17)

### Fixed

- **Audio Mixer:** no click when an app goes back to 100% or the equalizer is turned off.

## 0.4.0 (2026-10-17)

### Added

- **Audio Mixer:** a five-band equalizer with presets.

### Fixed

- **Audio Mixer:** the panel no longer flickers when the output list opens.

## 0.3.1 (2026-10-17)

### Fixed

- **Audio Mixer:** a faint square behind the on-screen volume bar.

## 0.3.0 (2026-10-17)

### Added

- **Audio Mixer:** software volume and the volume keys for outputs with no volume control.
- A README with screenshots and install steps.

## 0.2.0 (2026-10-17)

### Added

- **Audio Mixer:** a new tool, a volume for each app, with mute by clicking a row.
- **Window Switcher:** a new tool, ⌘Tab through windows instead of apps, and X to quit every dimmed app.
- **Mouse Settings:** back and forward buttons navigate in Apple apps.
- **General:** export and import of every setting.

### Changed

- Settings pages redesigned around shared cards.

## 0.1.0 (2026-10-13)

### Added

- **Mouse Settings:** cursor and wheel settings per mouse, in a menu bar app (first as Tiller).
