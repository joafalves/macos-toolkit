import AppKit
import SwiftUI

/// The "Audio Mixer" section.
struct MixerSettingsView: View {
    @ObservedObject var mixer: MixerController

    var body: some View {
        Page {
            ToolHeader(section: .mixer, subtitle: "Volume per app, an equalizer, and the volume keys.",
                       enabled: $mixer.config.enabled)

            if mixer.config.enabled, mixer.permission != .granted {
                Banner(text: mixer.permission == .denied
                       ? "System Audio Recording is turned off for MacOS Toolkit, so volume changes made here have no effect."
                       : "Volume changes need the System Audio Recording permission. macOS asks for it the first time you turn an app down.",
                       button: mixer.permission == .denied ? "Open System Settings…" : "Allow…") { mixer.requestPermission() }
            }

            if mixer.config.enabled, !mixer.keysInstalled {
                Banner(text: "The volume keys go through the mixer, with its own volume bar, once the toolkit has the Accessibility permission. Until then macOS handles them, and outputs with no volume control can't be changed from the keyboard.",
                       button: "Grant Access…") { mixer.requestAccessibility() }
            }

            WhenEnabled(enabled: mixer.config.enabled) {
                Card(title: "Options") {
                    // A pop-up rather than segments: four choices don't fit beside a caption.
                    SettingRow(title: "Menu bar icon", caption: "Opens the mixer in one click.") {
                        Picker("Menu bar icon", selection: $mixer.config.menuBarIcon) {
                            Text("None").tag(MixerMenuBarIcon.none)
                            Text("Mixer").tag(MixerMenuBarIcon.mixer)
                            Text("Volume").tag(MixerMenuBarIcon.volume)
                            Text("Volume and percentage").tag(MixerMenuBarIcon.volumePercent)
                            Text("Volume badge").tag(MixerMenuBarIcon.volumeBadge)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    RowDivider()
                    ToggleRow(title: "Software volume",
                              caption: "Lets the toolkit control the sound itself when an output has no volume control of its own, as many monitors don't.",
                              isOn: $mixer.config.softwareVolume)
                }

                Card(title: "Never Touch",
                     footnote: "These apps are hidden from the mixer and always play at the main volume.") {
                    let ignored = mixer.config.ignored.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
                    ForEach(Array(ignored.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 { RowDivider() }
                        SettingRow(title: entry.value) {
                            Button("Remove") { mixer.unignore(entry.key) }
                        }
                    }
                    if !ignored.isEmpty { RowDivider() }
                    SettingRow(title: "Add an app", caption: "Choose from the apps that are open.") {
                        Menu("Add") {
                            ForEach(candidates, id: \.0) { bundleID, name in
                                Button(name) { mixer.ignore(bundleID: bundleID, name: name) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// Open apps that aren't in the list yet.
    private var candidates: [(String, String)] {
        var seen = Set(mixer.config.ignored.keys)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }
}
