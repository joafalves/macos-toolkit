import SwiftUI

/// The "Window Switcher" section.
struct SwitcherSettingsView: View {
    @ObservedObject var switcher: SwitcherController
    @ObservedObject var mouse: MouseController

    private var shortcut: Shortcut { switcher.config.shortcut }
    /// The keys held to keep the list open, like "⌘".
    private var held: String { Shortcut.glyphs(shortcut.flags.subtracting(.shift)) }
    private var key: String { shortcut.key }

    private var keys: [(String, String)] {
        let back = shortcut.flags.contains(.shift) ? "↑" : "⇧\(key)  ↑"
        return [
            ("Next window", "\(key)  ↓"),
            ("Previous window", back),
            ("Go straight to one of the first nine", "1 – 9"),
            ("Go to the selected window", "release \(held)"),
            ("Cancel", "esc"),
            ("Close the window", "W"),
            ("Minimize the window", "M"),
            ("Hide the app", "H"),
            ("Quit the app", "Q"),
            ("Quit every dimmed app", "X"),
        ]
    }

    var body: some View {
        Page {
            ToolHeader(section: .switcher, subtitle: "\(shortcut.display) through windows instead of apps.", enabled: $switcher.config.enabled)

            if switcher.config.enabled {
                if !mouse.accessibilityGranted {
                    Banner(text: "The switcher is not active yet. It needs the Accessibility permission to see \(shortcut.display) and your windows.",
                           button: "Grant Access…") { mouse.requestAccessibility() }
                } else if switcher.tapFailed {
                    Banner(text: "Accessibility is granted, but the app has to restart before the switcher takes effect.",
                           button: "Restart") { mouse.relaunch() }
                }
            }

            WhenEnabled(enabled: switcher.config.enabled) {
                Card(title: "Shortcut",
                     footnote: shortcut == .commandTab
                        ? "macOS's app switcher is off while the switcher has ⌘Tab. ⌘` still cycles the windows of the current app."
                        : "macOS's ⌘Tab app switcher works as usual alongside this.") {
                    ShortcutRow(title: "Open the switcher",
                                caption: "Hold \(held) to keep the list open and let go to switch.\(shortcut.flags.contains(.shift) ? "" : " Add ⇧ to go backwards.")",
                                shortcut: $switcher.config.shortcut, defaultValue: .commandTab, optional: false)
                    RowDivider()
                    OptionRow(title: "Show on", caption: "Which display the list opens on.",
                              selection: $switcher.config.placement,
                              options: [(.mainScreen, "Main Display"), (.mouse, "Mouse"), (.activeWindow, "Active Window")])
                }

                Card(title: "While \(held) Is Held",
                     footnote: "Windows are listed most recently used first, across all Spaces. Minimized windows, hidden apps and apps without a window come last.") {
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                        if index > 0 { RowDivider() }
                        SettingRow(title: key.0) {
                            Text(key.1)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
