import SwiftUI

/// A sidebar row as System Settings has them: a small coloured tile, then the
/// name. A tool that's off is greyed, as on Overview.
private struct SidebarRow: View {
    let section: AppSection
    var on = true

    var body: some View {
        Label {
            Text(section.title)
                .foregroundStyle(on ? .primary : .secondary)
        } icon: {
            if section == .welcome {
                KitIcon(size: 22)
            } else {
                // Grey rather than `.saturation(0)`, a filter that `--snapshot`
                // images leave out.
                IconTile(symbol: section.symbol, color: on ? section.color : .gray, size: 22)
                    .opacity(on ? 1 : 0.6)
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

    /// Whether a tool is on, for its tile on Overview and its sidebar row.
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
        case .welcome, .general, .about: return true
        }
    }

    var body: some View {
        // A plain split rather than NavigationSplitView: that one runs the
        // sidebar up into the title bar, leaving the bar two-toned.
        HStack(spacing: 0) {
            List(selection: $model.section) {
                // Overview and the app's own settings, then the tools.
                SidebarRow(section: .welcome).tag(AppSection.welcome)
                SidebarRow(section: .general).tag(AppSection.general)
                SidebarRow(section: .about).tag(AppSection.about)
                Section("Tools") {
                    ForEach(AppSection.tools) { SidebarRow(section: $0, on: enabled($0)).tag($0) }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            Group {
                switch model.section ?? .welcome {
                case .welcome: WelcomeView(model: model, mouse: mouse, mixer: mixer, capture: capture, enabled: enabled,
                                            switcherShortcut: switcher.config.shortcut.active?.display ?? "⌘Tab")
                case .mouse: MouseSettingsView(mouse: mouse)
                case .switcher: SwitcherSettingsView(switcher: switcher, mouse: mouse)
                case .layout: LayoutSettingsView(layout: layout, mouse: mouse)
                case .mixer: MixerSettingsView(mixer: mixer)
                case .finder: FinderSettingsView(finder: finder, mouse: mouse)
                case .capture: CaptureSettingsView(capture: capture)
                case .awake: AwakeSettingsView(awake: awake, mouse: mouse)
                case .stats: StatsSettingsView(stats: stats)
                case .about: AboutView()
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
                SettingRow(title: "Accessibility", caption: "Used by Mouse, the Window Switcher, Window Layout, Finder, Screen Capture and Keep Awake.") {
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
                SettingRow(title: "Screen Recording", caption: "Used by Screen Capture, and for the pictures of windows in the Window Switcher and Window Layout.") {
                    if capture.screenPermission {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { capture.requestScreenPermission() }
                    }
                }
                RowDivider()
                SettingRow(title: "Microphone", caption: "Used by Screen Capture to record your voice. Only needed for that.") {
                    if capture.micPermission == .authorized {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(capture.micPermission == .notDetermined ? "Grant Access…" : "Open System Settings…") { capture.requestMicrophonePermission() }
                    }
                }
            }
            .settingAnchor(WelcomeView.permissionsAnchor)
        }
        // Granted in System Settings meanwhile: shown when coming back.
        .onAppear { capture.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            capture.refreshPermissions()
        }
    }
}
