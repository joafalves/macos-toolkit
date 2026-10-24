import SwiftUI

/// The "Finder" section.
struct FinderSettingsView: View {
    @ObservedObject var finder: FinderController
    @ObservedObject var mouse: MouseController
    @ObservedObject private var permissions = Permissions.shared

    /// What's installed here; the preview lists every known terminal, so
    /// images don't show what's on this Mac.
    private var terminals: [(id: String, name: String)] {
        finder.isPreview ? Terminals.known : Terminals.installed
    }

    private var terminalName: String {
        finder.isPreview ? Terminals.known[0].name : Terminals.resolve(finder.config.terminal).name
    }

    private var terminalOptions: [(String, String)] {
        [("", String(localized: "Automatic"))] + terminals.map { ($0.id, $0.name) }
    }

    var body: some View {
        Page {
            ToolHeader(section: .finder, subtitle: "Cut and paste files, swipe back and forward, and more in the right-click menu.", enabled: $finder.config.enabled)

            if finder.config.enabled, finder.config.cut || finder.config.swipe, !finder.isPreview {
                if !permissions.isGranted(.accessibility) {
                    Banner(text: "Cut and swiping are not active yet. They need the Accessibility permission to see the keys you press and the swipes you make in Finder.",
                           button: "Grant Access…") { mouse.requestAccessibility() }
                } else if finder.tapFailed {
                    Banner(text: "Accessibility is granted, but the app has to restart before Cut and swiping take effect.",
                           button: "Restart") { Relaunch.now() }
                }
            }

            WhenEnabled(enabled: finder.config.enabled) {
                Card(title: "Cut",
                     footnote: "Finder has no Cut, so this copies the selection and the next ⌘V in Finder moves it (Move Item Here, ⌥⌘V). A short sound says the files were cut, since Finder has no way to mark them. Copying something else first cancels the cut.") {
                    ToggleRow(title: "Cut and paste files",
                              caption: "Select files, press ⌘X or choose Cut from the right-click menu, open another folder, press ⌘V.",
                              isOn: $finder.config.cut)
                }

                Card(title: "Trackpad",
                     footnote: "Scrolling is never changed: a swipe over something that can still scroll sideways, like the column view, scrolls it. The swipe goes back or forward once it's at the edge.") {
                    ToggleRow(title: "Swipe back and forward",
                              caption: "Two fingers to the right go back, to the left go forward, as in a browser. In System Settings too.",
                              isOn: $finder.config.swipe)
                }

                Card(title: "Right-Click Menu",
                     footnote: "Cut is in the menu too while it's on. Changes show the next time you right-click.") {
                    SettingRow(title: "Finder extension", caption: "Adds these items to Finder's right-click menu. It's turned on with them.") {
                        if finder.extensionEnabled {
                            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Turn On") { finder.enableExtension() }
                        }
                    }
                    RowDivider()
                    ToggleRow(title: "New Text File",
                              caption: "Creates an empty untitled.txt in the folder and starts renaming it.",
                              isOn: $finder.config.newTextFile)
                    RowDivider()
                    ToggleRow(title: "Open in \(terminalName)",
                              caption: "Opens a terminal in the folder you're in, or in the folder you clicked.",
                              isOn: $finder.config.openInTerminal)
                    if finder.config.openInTerminal {
                        RowDivider()
                        OptionRow(title: "Terminal", caption: "Automatic picks the first installed of Ghostty, iTerm and Terminal.",
                                  selection: $finder.config.terminal, options: terminalOptions, menu: true)
                    }
                }
            }
        }
        .onAppear { finder.refreshExtension() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            finder.refreshExtension()
        }
    }
}
