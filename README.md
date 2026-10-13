# MacOS Toolkit

<img src="Resources/AppIcon-preview.png" width="96" alt="">

Personal macOS tooling, packaged as one menu bar app. Each tool is a section in the sidebar.

| Tool | What it does |
| --- | --- |
| Mouse Settings | Per-mouse cursor and wheel settings (SteerMouse-style), plus battery level. |

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

Profiles are keyed by vendor ID, product ID and transport, and stored in
`~/Library/Application Support/MacOS Toolkit/mouse.json`.

Cursor settings need no permission. The wheel settings that go through the event tap need
**Accessibility**. Trackpad scrolling is never modified.

## Building

Only the Xcode Command Line Tools are needed.

```bash
./scripts/make-cert.sh        # once: local signing identity, so macOS keeps permissions across rebuilds
./scripts/build.sh --install  # builds, copies to /Applications and launches
```

`swift scripts/make-icon.swift` regenerates the app icon.

## Layout

- `Sources/Toolkit/App` — app shell: menu bar item, main window, general settings
- `Sources/Toolkit/Mouse` — the Mouse Settings tool
