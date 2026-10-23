# Changelog

What each version adds, changes and fixes, newest first. The version at the top is the one being
worked on; it gets its date when it's released.

## 0.18.0 (unreleased)

### Added

- **Window Switcher:** Windows lists every window, or only those on the display the list opens on.
  While the list opens on the main display it lists every window, and the setting says so.
- **Window Layout:** ⌃⌥⌘D shows the desktop, as macOS's own gesture does, and brings every window
  back where it was the next time; snapped windows stay snapped.
- **Window Layout:** when a display goes (unplugged, or the lid closed), the windows snapped on it
  are snapped the same way on the display macOS moves them to, so halves stay halves; when it's
  back, they go back to it, unless you've moved them since.
- **Updates:** the app looks for a new release on GitHub when it starts and once a day, or when you
  press Check Now on About. A new version shows there and at the top of the toolkit panel, and is
  installed only when you ask, if it's signed with the same certificate as the app you have; then
  the app restarts.
- **Languages:** the app is in Portuguese (Portugal) as well as English, in the words macOS itself
  uses. It follows your languages in macOS, or the one picked in Settings → Language; the Finder
  menu and the permission prompts follow too.

### Changed

- **Keep Awake:** its menu in the menu bar is now a panel like the mixer's: the session with its
  switch and a bar of the time left, the lengths as buttons with the one running lit, an end time
  set with − and +, and Keep the display on and Stay available as switches.

- **Menu bar:** the toolkit's mark opens a panel instead of a menu. Every tool is listed with a
  switch to turn it on or off, which leaves the panel open, and its name opens its settings. Screen
  Capture, the Audio Mixer and Keep Awake, when they have no part of their own in the menu bar, are
  tiles at the top: Keep Awake's turns it on or off in one click, with its menu a click away.
- **Window Layout:** the suggestions for the rest of a display fill it with a frosted surface, the
  windows straight on it, instead of a coloured block with a panel on top.
- **Mouse:** shorter wording for the wheel's Fixed distance.

### Fixed

- **Settings:** the Restart buttons (after granting a permission, or changing the language)
  sometimes only quit the app: it now opens again once it has fully quit.

- **Menu bar:** the toolkit's item is centred on a laptop's own display, beside the notch, where it
  sat a point low. With several displays it's centred on the main one and no longer moves as you
  switch between displays.
- **Window Layout:** a window just snapped often couldn't be snapped again, or put back to its old
  size, when dragged straight away: the outline of the suggestions coming up for the rest of the
  display was taken for a window in the way, and the drag went unseen.
- **Window Layout:** dragging a window that was maximized, or snapped after a maximize, sometimes
  showed no snap for the whole drag: macOS gives it back its old size as the drag starts, and that
  was taken for a resize.
- **Window Layout:** a maximized window had macOS's own margin of 8 points rather than the gap, so
  it didn't line up with the halves beside it. Maximize no longer asks for macOS's Fill: the toolkit
  places the window itself, the same with any gap and in any app. The menu bar above it no longer
  turns dark, which macOS does only for windows it filled.
- **Window Layout:** a new gap now reaches a maximized window too, and any window still in macOS's
  tiling; they kept the old one.
- **Window Layout:** what's snapped where is no longer lost when the app restarts, updates or
  crashes: Restore, a drag out and a new gap keep working for those windows.
- **Window Layout:** Restore after a snap by dragging put the window back where it was let go, half
  off the display; it goes back where it was before you picked it up.
- **Window Layout:** a window nearly as tall as its display, made a few points shorter (a bigger gap,
  say), kept its height when there's another display below; it takes it now.
- **Window Layout:** the toolkit's own settings window, maximized by a drag to the top, is filled by
  macOS as after a double-click on its title bar, menu bar and all, like any other window.

## 0.17.0 (2026-10-23)

### Added

- **Mouse:** the wheel's distance is one setting: macOS's own, scaled; Fixed, every notch the same
  number of lines, as on Windows; or Curve, a graph you drag, from how far a single notch scrolls to
  how far a fast spin does, along a line or a curve. Saved speed and acceleration settings carry
  over.
- **System Stats:** the CPU panel's top apps say what their figures are out of: per core, as
  Activity Monitor counts them, up to 100% for each core. A setting shows them as a share of the
  whole CPU instead, up to 100%.

### Changed

- **Mouse:** a slow notch of the wheel scrolls a real distance with Fixed and Curve: with its own
  acceleration off, macOS made it a tenth of a line, a single point, so a notch barely moved.
- **Menu bar:** on a display that isn't active, the toolkit's item dims like macOS's own icons do.

### Fixed

- **System Stats:** the CPU panel's top apps no longer count the panel's own opening, which put the
  toolkit near the top each time it opened: they're measured from a couple of seconds in, saying
  Measuring… until then, and their CPU is an average of the last five seconds, so a moment's spike
  doesn't top the list.
- **Settings window:** the sidebar's Tools section can no longer be hidden by clicking its header.
- **Menu bar:** the toolkit's item sits centred in the menu bar of the display you're working on,
  like macOS's own icons, rather than a point high.
- **Menu bar:** the item's icons and text are the colour of macOS's own, rather than taking a tint
  from the desktop behind the menu bar.
- **Menu bar:** the item's icons, pills and the toolkit's mark are sharp on a non-Retina display,
  where some fell between pixels, and so is the copy macOS shows on your other displays, which was
  blurry on a Retina display beside a non-Retina one.

## 0.16.0 (2026-10-22)

### Added

- **Menu bar:** Settings → Order sets the order of the toolkit's parts in the menu bar, the toolkit
  menu included: drag them into place. Default Order puts them back. Each tool there also has a
  switch for its place in the menu bar, or an Open… button while the tool is off.

### Changed

- **About:** the version shows the commit it was built from in place of the build number.

### Fixed

- **Audio Mixer:** its menu bar look Volume badge is now Volume pill, as Keep Awake and System Stats
  call the same look.
- **Settings window:** the sidebar's names no longer sit right against their icons.

## 0.15.1 (2026-10-22)

### Added

- **Keep Awake:** Cup in the menu bar: only the cup, filled while it's on, without the time.

### Changed

- **Menu bar:** System Stats' own parts are set apart by a dot, as a recording's time and size are,
  rather than a short line; the lines between tools are back to their height before 0.15.0.
- **Audio Mixer, System Stats:** their panels end the same way: on the left the macOS app they go
  with, System Settings (at Sound) or Activity Monitor, with an arrow; on the right Settings…, with
  the toolkit's mark, for the tool's page. Opening System Settings from the mixer now closes it.
- **Keep Awake:** a clearer menu. The usual durations are one click away and every other one is
  under Other; while it's on, Turn Off says what's left and when it ends; and Keep the Display On
  and Stay Available are switches in it.
- **Menu bar:** the item sits as far from its neighbours as macOS's own items do; the space
  between parts no longer adds to the ends.
- **Menu bar:** the icons are outlines unless they show something is on: the speaker and the power
  bolt are outlines now, and Keep Awake's cup is the same cup, filled while it's on.

### Fixed

- **Audio Mixer:** the volume in the menu bar sits next to its speaker, rather than a digit's width
  away from it, with no gap after it.

## 0.15.0 (2026-10-22)

### Added

- **Settings window:** an About page, with the version, who made it, the license, and links to the
  contributors, the source, what's new and where to report a problem. Also in the toolkit menu.
- **License:** the toolkit is open source, under the Apache License 2.0.
- **Keep Awake:** 50 and 55 minutes among the times to turn it on for.

### Changed

- **Settings window:** a tool that's off is greyed in the sidebar, its tile without colour and its
  name dimmed, as on Overview.
- **System Stats:** the CPU panel shows each core's last minute as a small chart with what it's at
  now, grouped by kind of core with each group's average, in place of the row of small bars.
- **Settings window:** Welcome is now called Overview, in the sidebar and in the toolkit menu.
- **Menu bar:** the lines between parts are a little taller, and shorter between System Stats' own
  parts, so the stats read as one group.
- **Settings window:** a new install says every tool starts off and where to turn one on. A tool
  that's off says so under its header, and the header reads On or Off, as Overview does.
- **Settings window:** shorter descriptions in several places, and pop-up menus where a wide row of
  choices squeezed the text beside it. US spelling throughout.
- **Settings window:** Permissions lists the Microphone too, and shows a permission granted in System
  Settings as soon as you come back.
- **Window Layout:** Stacks is marked as a preview, and its tab comes last.
- **Audio Mixer:** its page has a button that opens the mixer. Never Touch is now Exclude, and the
  list Excluded Apps.

### Fixed

- **Audio Mixer:** an app that starts or stops playing shows as such right away. macOS doesn't
  announce it the way the mixer listened for, so it could take many seconds to catch up.
- **Audio Mixer:** if macOS refuses the tap for an app you muted or turned down, it's tried again a
  few seconds later, rather than leaving that app at full volume until its sound output changes.
- **Audio Mixer:** the bars next to a playing app no longer use CPU; with the mixer open they took
  about 10% of a core. With Reduce Motion on they stand still.
- **Keep Awake:** the pill in the menu bar no longer keeps a picture of every minute it has shown,
  which grew the toolkit by about 80 MB a day. The same for the volume and System Stats pills.
- **Menu bar:** a click on a part just after its panel closed (the mixer, or a System Stats panel)
  opens it again instead of being lost, and a click on the part of an open panel always closes it.
- **Mouse:** with the tool off, scrolling and middle clicks no longer pass through the toolkit.
- **Screen Capture:** a capture shortcut pressed while the timer counts down stops the timer,
  instead of capturing now and again when the timer ends.
- **Screen Capture:** a recording stopped as it was starting no longer carries on recording in the
  background with nothing to stop it. And quitting during a recording waits at most ten seconds
  for the file to be finished, so a stuck finish can't hold up logging out.
- **System Stats:** an open panel no longer holds about 40 MB of graphics memory: its charts are
  drawn as shapes, which also brings the panel itself from about 60 MB to about 20.
- **System Stats:** a disk plugged in or ejected no longer shows as one absurd disk speed that
  flattened the chart for five minutes. Network speeds and the top apps are guarded the same way.
- **Settings window:** a settings file with numbers out of range, edited by hand or imported, is kept
  to what the settings offer instead of crashing the toolkit at launch.
- **Settings window:** starting to record a second shortcut stops the first, so tools don't react to
  keys meant for a recorder.
- **Window Switcher:** windows an app keeps out of sight (hidden, see-through, or a few points
  across) are no longer listed as rows that switch to nothing. Window Layout's suggestions too.
- **Window Layout:** quitting with one of the toolkit's own windows in a stack no longer crashes,
  which also skipped putting other things back as the app quit.

## 0.14.0 (2026-10-22)

### Added

- **Keep Awake:** with no end set, the menu bar can show how long it's been on, counting up the
  minutes. Off by default.

### Changed

- **Settings window:** on a new install every tool starts off, to be turned on from its page as
  you want it. An update keeps your tools as they are.
- **Toolkit menu:** Tool Settings lists only the tools that are on; Welcome has them all.
- **System Stats:** memory turning yellow, then red, as it runs short is now a setting, off by
  default: the figure keeps the menu bar's color.

## 0.13.0 (2026-10-22)

### Added

- **Finder:** swipe two fingers right on the trackpad to go back and left to go forward, as in a
  browser, in Finder and System Settings. A swipe over something that can still scroll sideways,
  like the column view, scrolls it until it reaches the edge.
- **Mouse:** autoscroll on the wheel button, as in Windows browsers, in every app: hold it and move
  the mouse to scroll, faster the farther you move, with a speed setting. A wheel click without
  moving is still a middle click. Hold ⌥ while pressing to give the app its own wheel button, or
  list apps that should always get it.
- **Window Layout:** stacks, as a preview, off until turned on: several windows in one slot, one
  shown at a time, with tabs to switch between them. Hold ⌃ while dragging a window to see the
  windows it can stack with, and let go over one. Click a tab to switch, or use the shortcuts.

### Changed

- **Window Layout:** the settings are in three tabs: Snapping, Stacks and Keyboard.
- **Window Layout:** windows are offered for the rest of the display as soon as one is dropped,
  rather than once it has finished moving.

### Fixed

- **Window Layout:** a window dropped on an edge sometimes stayed where it was let go.
- **Window Layout:** Maximize, in an app that takes macOS's Fill and doesn't fill, now places the
  window itself.

## 0.12.0 (2026-10-21)

### Added

- **System Stats:** a new tool, in place of the Stats app. CPU, memory, network, disk, GPU and
  power in the menu bar, each as a number, a pill or a small chart, or all in one compact part.
  Click one for its last five minutes, the details, and for CPU and memory the apps using the most.
- **System Stats:** memory shows what apps need, leaving out the files macOS only caches, and turns
  yellow or red when macOS reports memory running short.
- **Window Layout:** after a window snaps to an edge or into a layout from the ⌥ bar, the rest of the
  display offers your other windows to fill it, as Windows' Snap Assist does: click one or press
  its number. Windows from other displays can be offered too, only when there's none left here (the
  default), or always.
- **Settings window:** a Welcome page, with a tile for each tool and whether it's on, and a warning
  while a permission a tool needs is missing, which leads to the list in Settings. The window opens
  on it the first time and after an update, and otherwise where it was left.

### Changed

- **Window Layout:** the gap starts at 8 points, macOS's own margin, and macOS's tiling margins follow
  it: with no gap, double-clicking a title bar fills the whole display. ⌃⌥↩ with a gap of up to 8
  points is macOS's own Fill.
- **Settings window and toolkit menu:** the tools are listed by name.
- **Settings window:** General is now Settings, under Welcome, with only the app's own settings; the
  version is on Welcome. The toolkit menu lists the tools under Tool Settings, then Welcome and
  Settings.

### Fixed

- **Menu bar:** the toolkit's item no longer uses CPU while nothing changes. Text in it kept macOS
  redrawing the whole item, at up to most of a core.
- **Menu bar:** the volume percentage and Keep Awake's time keep their width as they change, so
  the menu bar no longer shifts when a number gains or loses a digit.

## 0.11.0 (2026-10-21)

### Added

- **Keep Awake:** a new tool, in place of Amphetamine. Keeps the Mac awake until you turn it off, for
  5 minutes to 24 hours, or until a time, from the menu bar, its settings or a shortcut. Sessions
  carry on after a restart. The display can stay on or sleep.
- **Keep Awake:** in the menu bar, a pill that empties as the time runs out, or the cup with the
  time beside it.
- **Keep Awake:** optional awake with the lid closed, on battery too, after your password once. Ends
  below a battery level you pick, and if the Mac gets too hot, with a sound or a notification.
- **Keep Awake:** Stay available keeps Slack, Teams and the like from switching you to away, with a
  signal that changes nothing on screen or a small mouse move. It keeps the display on while it's on.
- **General:** the space between the toolkit's parts in the menu bar can be set, from tight to roomy.

### Changed

- **General:** importing settings keeps anything the file doesn't have as it is, instead of putting
  it back to its default.

## 0.10.0 (2026-10-21)

### Changed

- **App icon:** a new icon, four tools in four colours, and a menu bar glyph to match in place of
  the wrench and screwdriver.
- **Settings window:** each tool has a coloured tile in the sidebar and at the top of its page,
  under Tools and App headings. Mouse Settings is now just Mouse, like the other tools' names.
- **Menu bar:** the toolkit menu lists the settings pages under a Settings header, each by the
  tool's name, instead of some ending in "Settings" and some not.

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
