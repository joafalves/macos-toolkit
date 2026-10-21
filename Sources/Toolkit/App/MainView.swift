import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController
    @ObservedObject var switcher: SwitcherController
    @ObservedObject var layout: LayoutController
    @ObservedObject var mixer: MixerController
    @ObservedObject var finder: FinderController
    @ObservedObject var capture: CaptureController

    var body: some View {
        // A plain split rather than NavigationSplitView: that one runs the
        // sidebar up into the title bar, leaving the bar two-toned.
        HStack(spacing: 0) {
            List(selection: $model.section) {
                ForEach(AppSection.allCases.filter { $0 != .general }) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
                // The tools above, the app's own settings below.
                Divider()
                    .padding(.vertical, 2)
                Label(AppSection.general.title, systemImage: AppSection.general.symbol).tag(AppSection.general)
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            Group {
                switch model.section ?? .mouse {
                case .mouse: MouseSettingsView(mouse: mouse)
                case .switcher: SwitcherSettingsView(switcher: switcher, mouse: mouse)
                case .layout: LayoutSettingsView(layout: layout, mouse: mouse)
                case .mixer: MixerSettingsView(mixer: mixer)
                case .finder: FinderSettingsView(finder: finder, mouse: mouse)
                case .capture: CaptureSettingsView(capture: capture)
                case .general: GeneralView(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture)
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
    let switcher: SwitcherController
    let layout: LayoutController
    @ObservedObject var mixer: MixerController
    let finder: FinderController
    @ObservedObject var capture: CaptureController

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
                        Button("Export…") { SettingsTransfer.exportSettings(mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture) }
                        Button("Import…") { SettingsTransfer.importSettings(mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture) }
                    }
                }
            }

            Card(title: "Permissions") {
                SettingRow(title: "Accessibility", caption: "Used by Mouse Settings for wheel direction, speed and smoothing, by the Window Switcher, by Window Layout to move windows, by Finder for Cut, and by Screen Capture to find where a window's content starts.") {
                    if mouse.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { mouse.requestAccessibility() }
                    }
                }
                RowDivider()
                SettingRow(title: "System Audio Recording", caption: "Used by the Audio Mixer to change the volume of each app.") {
                    if mixer.permission == .granted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(mixer.permission == .denied ? "Open System Settings…" : "Grant Access…") { mixer.requestPermission() }
                    }
                }
                RowDivider()
                SettingRow(title: "Screen Recording", caption: "Used by Screen Capture for screenshots and recordings.") {
                    if capture.screenPermission {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { capture.requestScreenPermission() }
                    }
                }
            }
        }
    }
}
