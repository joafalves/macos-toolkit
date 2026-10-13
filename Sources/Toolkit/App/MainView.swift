import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController

    var body: some View {
        // A plain split rather than NavigationSplitView: that one runs the
        // sidebar up into the title bar, leaving the bar two-toned.
        HStack(spacing: 0) {
            List(selection: $model.section) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            Group {
                switch model.section ?? .mouse {
                case .mouse: MouseSettingsView(mouse: mouse)
                case .general: GeneralView(model: model, mouse: mouse)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

private struct GeneralView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Page {
            HStack(spacing: 14) {
                IconTile(symbol: "wrench.and.screwdriver.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacOS Toolkit").font(.title2.weight(.semibold))
                    Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Card(title: "Startup") {
                ToggleRow(title: "Launch at login",
                          caption: "Start in the menu bar when you log in.",
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }

            Card(title: "Backup") {
                SettingRow(title: "Settings file", caption: "Save every setting to a file, or load them from one.") {
                    HStack(spacing: 8) {
                        Button("Export…") { SettingsTransfer.exportSettings(mouse: mouse) }
                        Button("Import…") { SettingsTransfer.importSettings(mouse: mouse) }
                    }
                }
            }

            Card(title: "Permissions") {
                SettingRow(title: "Accessibility", caption: "Used by Mouse Settings for wheel direction, speed and smoothing.") {
                    if mouse.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { mouse.requestAccessibility() }
                    }
                }
            }
        }
    }
}
