# Tiller

Menu bar app that gives each mouse its own cursor and wheel settings. Every setting has a
**macOS** choice, meaning Tiller leaves that behaviour to System Settings.

| Setting | Options | How |
| --- | --- | --- |
| Cursor speed | macOS / custom multiplier | `HIDPointerResolution` on the device's HID service |
| Cursor acceleration | macOS / off / custom (0–3) | `HIDMouseAcceleration` on the device's HID service |
| Wheel direction (vertical, horizontal) | macOS / inverted | scroll event tap |
| Wheel speed | macOS / custom multiplier | scroll event tap |
| Wheel acceleration | macOS / off / custom | `HIDMouseScrollAcceleration` on the device's HID service |
| Wheel smoothing | macOS / smooth | scroll event tap |

Profiles are keyed by vendor ID, product ID and transport, and stored in
`~/Library/Application Support/Tiller/config.json`.

Cursor settings need no permission. The wheel settings that go through the event tap need
**Accessibility**. Trackpad scrolling is never modified.

## Build and install

```bash
./scripts/build.sh --install
```

This builds `build/Tiller.app`, copies it to `/Applications` and launches it.
