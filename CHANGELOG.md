# Changelog

What each version adds, changes and fixes, newest first. The version at the top is the one being
worked on; it gets its date when it's released.

## 0.25.0 (unreleased)

### Added

- **Audio Mixer:** the mixer can run through an audio driver of its own, as a preview you turn on in
  its settings: nothing records, so there's no purple dot and no System Audio Recording permission,
  and a microphone never waits for the mixer. Installing it asks for your password. Off, the mixer
  works as before. A later release with a new driver turns the mixer off until the driver is updated,
  with an alert and a warning in the sidebar; sound keeps playing as usual.
- **Window Switcher:** App Colours, off by default, gives each app a flat colour of its own on its rows,
  also in Window Layout's suggestions. Colours are made to look different from those of the apps open with them, close to the
  icon's where there's room, and an app keeps its colour unless it's open beside one too like it. Rows of minimized windows and hidden apps keep the colour; only their content fades.
- **Window Switcher:** type while the list is open to search what it lists, apps by name and windows by
  title, and to open an app it doesn't list. ⌘ and the key above Tab lists only the windows of the current app.
- **Window Switcher:** App Icons picks how the grid, and Window Layout's suggestions, show each app's icon:
  large in the top right corner of the picture, with the app's badge, or small in the bar. Tiles are a
  little taller, with the app's name above the window's title.
- **Window Switcher:** Grid Width sets how much of a display the grid can use, so you don't have to turn
  your head; windows that don't fit go on another row. Each display keeps its own, a new one starts with
  what suits its size, and one display's width can be used on all of them.
- **Window Switcher:** rows show the number on an app's Dock icon. It's read once the list is up, so
  the list never waits for it.

### Changed

- **Window Switcher:** closing, minimizing, hiding and quitting from the list are now ⇧W, ⇧M, ⇧H, ⇧Q and
  ⇧X, since letters on their own now search.
- **Window Switcher:** Previews is the default style. A style you've already chosen stays.

### Fixed

- **Window Switcher:** apps that draw their windows in a helper process are listed with their windows.
  They seemed to have none, and with only one display's windows listed they were missing.
- **Window Switcher:** ⇧X no longer quits an app whose only normal window is on another display, when the
  list only shows one display's.
- **Window Switcher:** an app that didn't answer when the toolkit started is asked again, and anything
  the list has missed is looked for when it opens. Its windows could be missing until you switched to it.
- **Window Layout:** a window snapped or maximized on one display when another arrives and becomes the
  main one is snapped again where macOS leaves it, filling that display. It no longer stays at the old
  display's size, and a drag no longer shrinks it to its size from before it was snapped.

## 0.24.5 (2026-10-30)

### Added

- **Screen Capture:** Menu Bar While Recording picks what shows beside the stop button: the time,
  the size, both or neither, and both on one line or on two of small text, which take less room
  beside the notch.
- **System Stats:** a stat can be in the panel only, rather than in the menu bar too: it shows
  under the stat you click, read only while the panel is open (its chart starts then), and with
  every stat in the panel only, an icon in the menu bar opens it.

### Changed

- **System Stats:** what the CPU and GPU draw is read only while the power panel is open, not all
  the time, which was most of what System Stats cost on a MacBook; those lines read “–” until the
  figures arrive, a moment after the panel opens, so it keeps its height. Desktops, which have no
  battery to report the whole draw, read it as before.
- **System Stats:** a panel too tall for the display scrolls with the thin scroll bar that shows
  while scrolling, also with a mouse connected, rather than a thick one that took width from it.

### Fixed

- **System Stats:** a panel from the menu bar could stay behind after it closed, out of sight but
  drawing again with every reading, which kept costing CPU and memory until the toolkit quit. A
  closed panel now lets go of what it showed.
- **Audio Mixer:** on macOS 26, a call app's preview should stall for about a second instead of 14
  seconds, which 0.24.3 only brought it down to, and for every preview. The mixer now takes the
  app's waiting tap away first, which lets the microphone's start go on, then makes a running one.
  A second app using the microphone is no longer missed while another is recording, and macOS 27
  no longer runs any of this.
- **Logs:** the mixer logs each step of a microphone's start: who started it, on which device, and
  what became of each tap, with the IDs that tell a new tap from the one it replaces.

## 0.24.4 (2026-10-28)

### Fixed

- **Audio Mixer:** the volume keys no longer get stuck on an output that rounds its volume to steps
  of its own, such as a display's speakers over USB, where they stopped at 59% going up and 55%
  going down. The volume is the one the keys or the slider set, 60% rather than the 59.3% the
  output rounds it to, until it's changed somewhere else.

## 0.24.3 (2026-10-28)

### Fixed

- **Audio Mixer:** a call app's preview, such as Slack's before a huddle, no longer freezes the first
  time after the mixer is turned on, which 0.24.1 and 0.24.2 didn't fix. On macOS 26 an app can't
  start its microphone while the tap that takes its sound waits for sound, whatever the devices.
  The mixer now checks once a second which apps use the microphone and runs their taps, so a start
  held up goes on within a second.

## 0.24.2 (2026-10-28)

### Fixed

- **Audio Mixer:** a call app's preview, such as Slack's before a huddle, no longer freezes the first
  time after the mixer is turned on, which 0.24.1 didn't fix. The mixer's taps now take only the
  sound going to the current output, so an app's microphone has nothing to do with them. With an
  output that has a microphone of its own (AirPods, a headset), the tap of an app using it runs.
- **Audio Mixer:** an app that sends its sound to another output than the current one (an audio
  interface, AirPlay, the Mac's speakers) is heard there again, at that output's volume, instead of
  being brought to the current output.
- **Logs:** the toolkit's lines in the system log can be read: they showed as `<private>`. Each
  tool logs under its own category, and the mixer now logs what each tap takes and when it runs.

## 0.24.1 (2026-10-28)

### Fixed

- **Audio Mixer:** a call app's preview, such as Slack's before a huddle, no longer freezes the first
  time after the mixer is turned on. On macOS 26 the app couldn't start its microphone while the
  tap that takes its sound waited for sound; that tap now runs while the app uses the microphone.

## 0.24.0 (2026-10-25)

### Added

- **Tweaks:** a new page under **System** in the settings, with macOS settings that System Settings
  doesn't show: background tasks (Photos' analysis, People and Memories, Game Center, Tips), and
  hidden Dock, Finder, typing, dialog and device settings. Each switch shows what's set on this Mac
  now, says when it isn't macOS's default, and can put it back. What's set stays set without the
  toolkit.
- **Finder:** its page links to Tweaks for Finder's own settings, such as hidden files.
- **Mouse:** with **Navigate**, **Change…** sets which of a mouse's buttons go back and forward,
  for mice that don't use the usual fourth and fifth.
- **Audio Mixer:** the Classical, Hip-Hop and Pop equalizer presets, as in the Music app.

### Changed

- **Audio Mixer:** the Bass Boost, Bass Reducer, Treble Boost, Treble Reducer, Vocal, Rock,
  Electronic and Acoustic presets have the Music app's values. An equalizer set to one of them
  before moves to its new values.

### Fixed

- **Settings:** a mouse's back and forward buttons, and a three-finger swipe, go back and forward
  in the settings window, as a two-finger swipe and ⌘[ ⌘] do.
- **Mouse:** with **Navigate**, the back and forward buttons work in System Settings too.
- **Window Switcher:** with That display, it no longer shows an empty box on a display with no
  windows.

## 0.23.0 (2026-10-25)

### Added

- **Menu bar:** **Settings → Separator** picks what goes between two tools: a line (the default),
  a dot or nothing. **Separator within a tool** does the same between one tool's own parts, as
  System Stats' stats (a dot by default, or the same as between tools).
- **System Stats:** a **Small pill** look for CPU, memory, GPU and disk: the pill without the
  number, where the fill shows the share.
- **Audio Mixer:** a **Small volume pill** look: the speaker and the fill, without the number.

### Changed

- **Menu bar:** every pill is drawn the same way and is the same width, whatever the tool or what
  it shows, so pills side by side line up; the small pills share one width too. They're a little
  smaller, with their symbol and text centred.
- **System Stats:** a pill shows 100 at full rather than stopping at 99.
- **System Stats:** the CPU and memory panels show the top apps' CPU about a second after they
  open, rather than after three to five.
- **Audio Mixer:** muted, the volume pill is empty with the speaker crossed out and keeps the
  volume, rather than showing "off".
- **Keep Awake:** its icon is macOS's wake symbol, and sleep while it's off, in place of the cup:
  in the sidebar, its panel, the toolkit panel and the menu bar. **Cup and time** is now **Icon
  and time**.
- **Keep Awake:** the pill stays a pill when it's off, empty with the sleep symbol and zzz: ∞ with
  no end, and whole hours (12h) for 10 hours and more. **Cup** is now **Small pill**: the same
  pill without the time, where the fill shows what's left.
- **Keep Awake:** in its panel, Stay available has no caption under it, like Keep the display on,
  unless it needs Accessibility.

### Fixed

- **System Stats:** the dot between stats was darker than the line between tools; it's as faint now.

## 0.22.1 (2026-10-25)

### Fixed

- **Menu bar:** while the settings window was open, a panel from the menu bar opened out of sight
  when another app was in full screen. Panels now open over full-screen apps too.

## 0.22.0 (2026-10-25)

### Added

- **Audio Mixer:** its page in the settings has the mixer itself: the main volume and the output,
  the equalizer, and every app's volume, the same controls as the menu bar panel, which stays as the
  quick way to them. Settings search finds them.
- **Audio Mixer:** with **Equalizer for each output** on, the page sets any output's equalizer,
  starting with the one in use; the panel's is always the one in use.
- **Audio Mixer:** the equalizer has a **Simple** mode: Bass, Mid and Treble, each moving a region of
  the same ten bands, so a preset sounds the same in both modes. Chosen on the mixer's page, for
  every output; the panel follows.
- **Audio Mixer:** dragging an equalizer band with ⌥ held moves the bands beside it too, less the
  further they are.

### Changed

- **Audio Mixer:** the equalizer's sliders are macOS's own, as in the Music app's equalizer, with a
  tick at 0 dB. In the panel a dB scale beside them takes the place of a value over every band.

## 0.21.2 (2026-10-25)

### Fixed

- **Audio Mixer:** the toolkit's own sounds, Finder's Cut sound and Screen Capture's shutter, skipped
  the mixer: on an output with no volume of its own they played at full volume whatever the volume
  was, and without the equalizer. They're now played as macOS plays its interface sounds, so they
  follow the volume and the equalizer, and Sound settings' "Play user interface sound effects".

## 0.21.1 (2026-10-25)

### Fixed

- **System Stats:** the panel with every stat (the compact layout) no longer runs off a display
  too short for it: it stops above the Dock and scrolls, with Activity Monitor and Settings kept
  at the bottom.
- **Screen Capture:** a panel from the menu bar (System Stats, the mixer, the others) stays open
  while you pick an area or window to capture it, and Esc cancels the capture rather than closing
  the panel.

## 0.21.0 (2026-10-24)

### Added

- **Permissions:** turning a tool on, from its page or the toolkit panel, opens a short sheet listing
  the permissions it needs and what each is for. Its button asks for the next one missing, with
  macOS's own prompt or System Settings, and each turns green once granted. One that only works
  after a restart (Screen Recording) is left for the end, with one Restart button for all of them.
  If the app restarts part way through (macOS's own Quit & Reopen), the sheet comes back.
- **Permissions:** a tool's settings stay locked, as when it's off, until it has the permissions it
  can't work without: Accessibility for the Window Switcher and Window Layout, System Audio
  Recording for the Audio Mixer, Screen Recording for Screen Capture. One that only a feature needs
  is marked Optional in the sheet and locks nothing; the feature says so on its own. A tool that's
  on without one it can't work without has a warning beside its name in the sidebar.
- **Permissions:** a page of its own in the sidebar, under Settings, with every permission, what
  uses it and whether it's granted. Revoke… resets one, Revoke All… every one, and the app
  restarts; where macOS doesn't allow it, it says where to turn it off.
- **Audio Mixer:** **Equalizer for each output**, in the settings: each output keeps its own
  equalizer, so headphones and speakers can sound different.
- **Audio Mixer:** **Volume for each output**, in the settings, for each output to keep its own
  volume, as macOS does.

### Changed

- **Finder:** the extension behind the right-click menu is turned on with the menu: as the tool or
  a first item in it is turned on, and once for a setup that already had items on with it off.
  Turned off in System Settings later, a relaunch leaves it off.
- **Audio Mixer:** the equalizer has ten bands an octave apart, 32 Hz to 16 kHz, as the Music app's,
  and each slider is what the sound gets at its band; before, the outer two worked mostly below
  45 Hz and above 14 kHz. A Preamp beside them sets the volume of everything, as in the Music app.
  The presets are redone for the new bands, with Treble Reducer added. An equalizer set before
  keeps its sound.
- **Audio Mixer:** dragging an equalizer band or picking a preset glides, without clicks.
- **Audio Mixer:** while it's on, all sound goes through it, each app through a tap of its own that
  it moves into while it's quiet. Changing an app's volume, putting it back to 100% and turning the
  equalizer on or off no longer click or pop while something plays; the equalizer fades in and out.
- **Audio Mixer:** the software volume is always on for outputs with no volume control of their
  own, and its setting is gone. macOS shows its recording indicator while the mixer is on.
- **Audio Mixer:** System Audio Recording is asked for as the mixer is turned on, no longer the first
  time an app is turned down.
- **Audio Mixer:** the volume stays the same when you switch outputs, unless **Volume for each
  output** is on: headphones that connect are set to the volume in use, not left at their own.

### Fixed

- **Audio Mixer:** once sound had gone through the mixer (an app turned down, the equalizer, or the
  software volume), the output kept running after it stopped, which kept the Mac from sleeping and
  Core Audio busy until the output changed. It's let go two seconds after the sound stops.
- **Audio Mixer:** on an output whose stereo pair isn't its first two channels (as set in Audio
  MIDI Setup), sound through the mixer came out of the first two.
- **Audio Mixer:** the equalizer distorted loud music: everything over 80% of full scale was
  rounded off, even with every band cut, and a peak over full scale was turned down on the spot,
  which crackled. A look-ahead limiter now turns down only what would go over, smoothly, 1.5 ms
  ahead.
- **Permissions:** Screen Recording turned on in System Settings no longer shows as missing until
  the app restarts: it says it's waiting for a restart, with a button for it, on Overview, the
  Permissions page, the sheet, and the Window Switcher's and Window Layout's previews.
- **Permissions:** every Grant Access… or Open System Settings… button asks macOS first, which puts
  the app back in System Settings' list after a refusal or a revoke, so it's always there to turn
  on; System Settings opens too only once it was refused.
- **Overview:** the warning about missing permissions follows each tool's settings: the mixer's
  volume keys, Keep Awake's Stay available and Screen Capture's Content Only and microphone count,
  and Finder doesn't ask for Accessibility with Cut and swipes off. The names are in Portuguese too.
- **Screen Capture:** Content Only says when it needs Accessibility. Asking for Screen Recording
  shows macOS's prompt while it has no answer, which also puts the app back in System Settings'
  list after a revoke, and opens System Settings only once it was refused, rather than both at once.
- **Window Switcher:** granting Accessibility while the app was running left the switcher with no
  windows until a restart, when Window Layout's suggestions were on; and the toolkit's own window,
  in front at the time, was listed last instead of first.
- **Mouse:** without Accessibility, the list of mice says so, and a mouse's wheel and button
  settings are locked until it's granted; cursor settings still work.
- **Mouse:** with two mice, one that reconnected (Bluetooth LE mice drop off when idle) could be
  counted as away for up to a minute, and the other mouse's settings took its clicks: back and
  forward stopped navigating until a setting was changed. It's counted again within two seconds.
- **Mouse:** no longer asks for Input Monitoring to tell several mice apart: macOS gives it with
  Accessibility, which the wheel and button settings need anyway, and lets no app ask for it alone.
  Granted while the app runs, it's used straight away; before, each mouse waited for a reconnect.

## 0.20.1 (2026-10-24)

### Changed

- **Window Layout:** the menu bar panel lights up the picture of where Window Layout put the window
  in front, while it's still there.

### Fixed

- **Menu bar:** clicking in a panel from the menu bar (the toolkit panel's quick buttons, the mixer,
  System Stats, Keep Awake, Mouse, Window Layout) no longer brings the settings window forward,
  then or when the panel closes for the next one.
- **Window Layout:** the menu bar panel's pictures put the window in front exactly where they show.
  Top half on a maximized window moved it to the display above instead, as ⌃⌥↑ does.

## 0.20.0 (2026-10-24)

### Added

- **Settings:** a search field at the top of the sidebar, as in System Settings. It lists the pages
  and settings that match, in English or Portuguese, each with the page it's on; a click opens the
  page there and lights the setting up.
- **Menu bar:** Mouse and Window Layout can have a part in the menu bar too. Mouse's panel lists each
  connected mouse with its charge and opens its settings. Window Layout's places the window in front
  (halves, quarters, thirds, maximize), restores it, opens the grid, shows the desktop, or moves it to
  the next display.
- **Mouse:** the page lists every mouse, connected ones first, with its charge and a Refresh button
  to look for them again. Clicking one opens its own page, with its settings and buttons to reset,
  rename or forget it; forgetting puts it back to macOS's settings.

### Changed

- **All tools:** the app looks as apps built for the current macOS do: the settings window, its
  toolbar and sidebar, the panels and the controls. The build named an old macOS as the one it was
  made for, so macOS drew everything in the style from before macOS 26.
- **Settings:** the window is laid out like System Settings: the sidebar runs its full height, and
  the toolbar has back and forward beside the page's title. They retrace every page shown, from the
  sidebar, a link or the menu bar, as do ⌘[ and ⌘] and a two-finger swipe right or left.
- **Menu bar:** every tool that can be in the menu bar has **Show in the menu bar** in the same place,
  under its On switch at the top of its page, with what a click on it does. Keep Awake and the Audio
  Mixer keep their look in their options; Screen Capture's Menu Bar section is gone.
- **Menu bar:** the toolkit panel's quick tools are a row of icons, with the name and how it is on
  hover, so more fit. Keep Awake's opens its panel, where its switch is.

### Fixed

- **Settings:** ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z work in text fields, such as search and renaming a mouse. The
  app had no Edit menu, which is where macOS takes them from.
- **Mouse:** two mice of the same model are told apart, each with its own settings and charge. They
  were one entry, and one's settings went to both. A mouse is known by its Bluetooth address or
  serial number now, so an Apple mouse keeps its settings on its cable too. Settings saved for a
  model go to each mouse of it connected the first time the app starts after the update.

## 0.19.4 (2026-10-24)

### Fixed

- **Screen Capture:** the coordinates beside the pointer follow it as it moves. They lagged behind
  and caught up only every few seconds, since most moves go to the app being captured.
- **Screen Capture:** a shot taken with the toolbar's Capture no longer shows the area's knobs and
  outline along its edges.

## 0.19.3 (2026-10-24)

### Changed

- **Keep Awake:** Stay awake with the lid closed is gone. It ran macOS's sleep setting as an admin
  through a rule that any app on this Mac could use too, to keep the Mac from sleeping with the lid
  closed. On a Mac that had it, the rule is removed and sleep turned back on when the app starts.
  With power and a display connected, macOS already keeps a closed Mac awake.

## 0.19.2 (2026-10-24)

### Added

- **Menu bar:** About in the toolkit panel, beside Settings, for the version and updates.

### Changed

- **Audio Mixer:** turned on for the first time, it's in the menu bar, as Volume, rather than only in
  the toolkit panel. Settings already made are kept.
- **Settings window:** in Portuguese, About is now called Sobre.

### Fixed

- **Security:** other apps on this Mac can no longer use the toolkit's permissions (Accessibility,
  Screen Recording, the microphone) to capture the screen, read window titles or send input. The
  development flags that allowed it are left out of released builds, and the app is signed with
  macOS's hardened runtime, which keeps other processes from loading code into it.
- **Audio Mixer:** Volume and percentage in the menu bar keeps one width, at 0% and 100% too, so the
  item no longer shifts as the volume changes.

## 0.19.1 (2026-10-24)

### Fixed

- **Audio Mixer:** the volume keys' bar has as many segments as presses from silent to full (20 with
  Round, 10 with Large), so 20% with Round no longer showed three segments and a sliver. A volume
  between presses lights its segment lighter, rather than cutting it into a thin crescent.
- **Audio Mixer:** turning the equalizer off ends its recording at once, so macOS's purple dot goes
  too. It waited for a moment of silence, which with music playing never came.
- **Audio Mixer:** the equalizer's switch shows its colour while on as soon as the mixer opens, as the
  other panels' switches do; it was grey until the mixer was clicked.

## 0.19.0 (2026-10-24)

### Added

- **Screen Capture:** Copy text from the screen, off until turned on in its settings: ⇧⌘2 copies the
  text in an area, or what a QR code or barcode there holds, read on this Mac. A sentence that wraps
  on screen comes out whole; lists and code keep their lines. Space switches to clicking a window,
  and T in the ⇧⌘4 overlay switches to text (and back). A card in the corner shows what was copied,
  or that there was no text. The reading runs in a process of its own that quits right after, so
  the app's memory stays as it was.
- **Audio Mixer:** Each press, under Volume Keys: Fine, Round, Standard or Large, 32, 20, 16 or 10
  presses from silent to full, and how much a press with ⇧⌥ moves the volume, 1 to 5.

### Changed

- **Audio Mixer:** the volume keys go 16 presses from silent to full, as macOS's own do, rather than
  20 (Round keeps 5% a press). The on-screen bar has 16 segments, one a press, and fills part of
  one for smaller steps.
- **Audio Mixer:** software volume, for outputs with no volume of their own, is even in decibels from
  top to bottom, like macOS's own outputs: low down, a press no longer jumps the sound a lot, nor
  does nothing near the top. Volumes already set sound the same, though the number shown changes.

## 0.18.3 (2026-10-23)

### Changed

- **Mouse:** autoscroll's speed has a new scale: 1 is what 0.25 was, slow enough to read as it goes,
  and the slider goes from 0.25 to 4. A speed you had picked stays as fast; the 1 nobody changed
  is the new, slower 1.
- **Updates:** with versions skipped, About shows what's new in each of them since yours, newest
  first under its number, rather than only the latest's.

## 0.18.2 (2026-10-23)

### Fixed

- **Updates:** on About, a new version's notes showed an item that runs over two lines as two, and
  sat between the card's lines like a setting; they're in a box of their own now, under the version
  on offer, each heading set apart and each item a bullet of its own. The line beside it only says
  which version you have.
- **Updates:** when an update can't be installed, an alert says so and offers its release page, to
  install it by hand.

## 0.18.1 (2026-10-23)

### Changed

- **Keep Awake:** in its panel, a click anywhere on the header, the cup and the name included,
  turns it on or off, as the switch does.

## 0.18.0 (2026-10-23)

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
  tiles at the top: Keep Awake's turns it on or off in one click, with its panel a click away.
- **Window Layout:** the suggestions for the rest of a display fill it with a frosted surface, each
  window on a card of its own, instead of a coloured block with a panel on top.
- **Window Switcher:** each preview sits on a card of its own, so a window with see-through parts
  (a sidebar, a toolbar) no longer looks as if it had no background.
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

## 0.17.0 (2026-10-23)

### Added

- **Mouse:** the wheel's distance is one setting: macOS's own, scaled; Fixed, every notch the same
  number of lines; or Curve, a graph you drag, from how far a single notch scrolls to
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
- **Mouse:** autoscroll on the wheel button, in every app: hold it and move
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
  display offers your other windows to fill it: click one or press
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

- **Keep Awake:** a new tool. Keeps the Mac awake until you turn it off, for
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

- **Window Layout:** a new tool. Shortcuts for halves, quarters,
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
