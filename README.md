# MacOS Toolkit

Personal macOS tooling.

| Tool | What it does |
| --- | --- |
| [Tiller](tools/tiller) | Per-mouse cursor and wheel settings (a small SteerMouse-style menu bar app). |

## Building

Only the Xcode Command Line Tools are needed. Each tool has its own `scripts/build.sh`.

Tools that need privacy permissions (Accessibility etc.) are signed with a local self-signed
identity so macOS keeps the grant across rebuilds. Create it once:

```bash
./scripts/make-cert.sh
```
