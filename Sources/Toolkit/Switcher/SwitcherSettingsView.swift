import SwiftUI

/// The "Window Switcher" section.
struct SwitcherSettingsView: View {
    @ObservedObject var switcher: SwitcherController
    @ObservedObject var mouse: MouseController

    private static let keys: [(String, String)] = [
        ("Next window", "⇥  ↓"),
        ("Previous window", "⇧⇥  ↑"),
        ("Go straight to one of the first nine", "1 – 9"),
        ("Go to the selected window", "release ⌘"),
        ("Cancel", "esc"),
        ("Close the window", "W"),
        ("Minimize the window", "M"),
        ("Hide the app", "H"),
        ("Quit the app", "Q"),
        ("Quit every dimmed app", "X"),
    ]

    var body: some View {
        Page {
            HStack(spacing: 14) {
                IconTile(symbol: AppSection.switcher.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Window Switcher").font(.title2.weight(.semibold))
                    Text("⌘Tab through windows instead of apps.").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if switcher.config.enabled {
                if !mouse.accessibilityGranted {
                    Banner(text: "The switcher is not active yet. It needs the Accessibility permission to see ⌘Tab and your windows.",
                           button: "Grant Access…") { mouse.requestAccessibility() }
                } else if switcher.tapFailed {
                    Banner(text: "Accessibility is granted, but the app has to restart before the switcher takes effect.",
                           button: "Restart") { mouse.relaunch() }
                }
            }

            Card(title: "Shortcut", footnote: "⌘` still cycles the windows of the current app.") {
                ToggleRow(title: "Replace ⌘Tab",
                          caption: "When off, ⌘Tab opens the macOS app switcher.",
                          isOn: $switcher.config.enabled)
                RowDivider()
                OptionRow(title: "Show on", caption: "Which display the list opens on.",
                          selection: $switcher.config.placement,
                          options: [(.mainScreen, "Main Display"), (.mouse, "Mouse"), (.activeWindow, "Active Window")])
            }

            Card(title: "While ⌘ Is Held",
                 footnote: "Windows are listed most recently used first, across all Spaces. Minimized windows, hidden apps and apps without a window come last.") {
                ForEach(Array(Self.keys.enumerated()), id: \.offset) { index, key in
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
