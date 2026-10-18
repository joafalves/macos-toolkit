import SwiftUI

/// The "Finder" section.
struct FinderSettingsView: View {
    @ObservedObject var finder: FinderController
    @ObservedObject var mouse: MouseController

    private var terminalOptions: [(String, String)] {
        [("", "Automatic")] + Terminals.installed.map { ($0.id, $0.name) }
    }

    var body: some View {
        Page {
            HStack(spacing: 14) {
                IconTile(symbol: AppSection.finder.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Finder").font(.title2.weight(.semibold))
                    Text("Small things Finder is missing.").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if finder.config.cut, !finder.isPreview {
                if !mouse.accessibilityGranted {
                    Banner(text: "Cut is not active yet. It needs the Accessibility permission to see the keys you press in Finder.",
                           button: "Grant Access…") { mouse.requestAccessibility() }
                } else if finder.tapFailed {
                    Banner(text: "Accessibility is granted, but the app has to restart before Cut takes effect.",
                           button: "Restart") { mouse.relaunch() }
                }
            }

            Card(title: "Cut",
                 footnote: "Finder has no Cut, so this copies the selection and the next ⌘V in Finder moves it (Move Item Here, ⌥⌘V). A short sound says the files were cut, since Finder has no way to mark them. Copying something else first cancels the cut.") {
                ToggleRow(title: "Cut and paste files",
                          caption: "Select files, press ⌘X or choose Cut from the right-click menu, open another folder, press ⌘V.",
                          isOn: $finder.config.cut)
            }

            Card(title: "Right-Click Menu",
                 footnote: "Cut is in the menu too while it's on. Changes show the next time you right-click.") {
                SettingRow(title: "Finder extension", caption: "Adds these items to Finder's right-click menu. macOS keeps it off until you turn it on.") {
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
                ToggleRow(title: "Open in \(Terminals.resolve(finder.config.terminal).name)",
                          caption: "Opens a terminal in the folder you're in, or in the folder you clicked.",
                          isOn: $finder.config.openInTerminal)
                if finder.config.openInTerminal {
                    RowDivider()
                    OptionRow(title: "Terminal", caption: "Automatic picks the first installed of Ghostty, iTerm and Terminal.",
                              selection: $finder.config.terminal, options: terminalOptions)
                }
            }
        }
        .onAppear { finder.refreshExtension() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            finder.refreshExtension()
        }
    }
}
