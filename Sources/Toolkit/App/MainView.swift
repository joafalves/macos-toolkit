import SwiftUI

/// A sidebar row as System Settings has them: a small coloured tile, then the name.
private struct SidebarRow: View {
    let section: AppSection

    var body: some View {
        Label {
            Text(section.title)
        } icon: {
            if section == .welcome {
                KitIcon(size: 22)
            } else {
                IconTile(symbol: section.symbol, color: section.color, size: 22)
            }
        }
        .padding(.vertical, 2)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController
    @ObservedObject var switcher: SwitcherController
    @ObservedObject var layout: LayoutController
    @ObservedObject var mixer: MixerController
    @ObservedObject var finder: FinderController
    @ObservedObject var capture: CaptureController
    @ObservedObject var awake: AwakeController
    @ObservedObject var stats: StatsController

    /// Whether a tool is on, for its tile on Welcome.
    private func enabled(_ section: AppSection) -> Bool {
        switch section {
        case .mouse: return mouse.config.enabled
        case .switcher: return switcher.config.enabled
        case .layout: return layout.config.enabled
        case .mixer: return mixer.config.enabled
        case .finder: return finder.config.enabled
        case .capture: return capture.config.enabled
        case .awake: return awake.config.enabled
        case .stats: return stats.config.enabled
        case .welcome, .general: return true
        }
    }

    var body: some View {
        // A plain split rather than NavigationSplitView: that one runs the
        // sidebar up into the title bar, leaving the bar two-toned.
        HStack(spacing: 0) {
            List(selection: $model.section) {
                // Welcome and the app's own settings, then the tools.
                SidebarRow(section: .welcome).tag(AppSection.welcome)
                SidebarRow(section: .general).tag(AppSection.general)
                Section("Tools") {
                    ForEach(AppSection.tools) { SidebarRow(section: $0).tag($0) }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            Group {
                switch model.section ?? .welcome {
                case .welcome: WelcomeView(model: model, mouse: mouse, mixer: mixer, capture: capture, enabled: enabled)
                case .mouse: MouseSettingsView(mouse: mouse)
                case .switcher: SwitcherSettingsView(switcher: switcher, mouse: mouse)
                case .layout: LayoutSettingsView(layout: layout, mouse: mouse)
                case .mixer: MixerSettingsView(mixer: mixer)
                case .finder: FinderSettingsView(finder: finder, mouse: mouse)
                case .capture: CaptureSettingsView(capture: capture)
                case .awake: AwakeSettingsView(awake: awake, mouse: mouse)
                case .stats: StatsSettingsView(stats: stats)
                case .general: GeneralView(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture, awake: awake, stats: stats)
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
    let awake: AwakeController
    let stats: StatsController

    var body: some View {
        Page(goTo: $model.goTo) {
            PageHeader(section: .general, subtitle: "The app's own settings: startup, the menu bar, backups and permissions.")

            Card(title: "Startup") {
                ToggleRow(title: "Launch at login",
                          caption: "Start in the menu bar when you log in.",
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }

            Card(title: "Menu Bar") {
                SettingRow(title: "Space between items", caption: "Between the toolkit's parts in the menu bar. It changes as you drag.") {
                    EmptyView()
                } extra: {
                    ValueSlider(value: $model.general.menuBarSpacing, range: GeneralConfig.menuBarSpacings, step: 2,
                                low: "Tight", high: "Roomy", format: { "\(Int($0)) pt" })
                }
            }

            Card(title: "Backup") {
                SettingRow(title: "Settings file", caption: "Save every setting to a file, or load them from one.") {
                    HStack(spacing: 8) {
                        Button("Export…") { SettingsTransfer.exportSettings(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture, awake: awake, stats: stats) }
                        Button("Import…") { SettingsTransfer.importSettings(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture, awake: awake, stats: stats) }
                    }
                }
            }

            Card(title: "Permissions") {
                SettingRow(title: "Accessibility", caption: "Used by Mouse for the wheel direction, speed and smoothing, by the Window Switcher, by Window Layout to move windows, by Finder for Cut, by Screen Capture to find where a window's content starts, and by Keep Awake to stay available.") {
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
            .settingAnchor(WelcomeView.permissionsAnchor)
        }
    }
}
