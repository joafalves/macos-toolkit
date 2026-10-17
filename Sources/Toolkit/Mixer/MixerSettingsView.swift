import AppKit
import SwiftUI

/// The "Audio Mixer" section.
struct MixerSettingsView: View {
    @ObservedObject var mixer: MixerController

    var body: some View {
        Page {
            HStack(spacing: 14) {
                IconTile(symbol: AppSection.mixer.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio Mixer").font(.title2.weight(.semibold))
                    Text("A volume for each app, from the menu bar.").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if mixer.config.enabled, mixer.permission != .granted {
                Banner(text: mixer.permission == .denied
                       ? "System Audio Recording is turned off for MacOS Toolkit, so app volumes have no effect."
                       : "App volumes need the System Audio Recording permission. macOS asks for it the first time you turn an app down.",
                       button: mixer.permission == .denied ? "Open System Settings…" : "Allow…") { mixer.requestPermission() }
            }

            Card(title: "Mixer",
                 footnote: "App volumes are relative to the main volume: an app at 50% plays at half of whatever the main volume is.") {
                ToggleRow(title: "Volume per app",
                          caption: "Adds Audio Mixer to the menu bar menu. When off, every app plays at the main volume.",
                          isOn: $mixer.config.enabled)
                RowDivider()
                ToggleRow(title: "Own menu bar icon",
                          caption: "Show the mixer as an icon of its own in the menu bar, one click away.",
                          isOn: $mixer.config.standaloneIcon)
                    .disabled(!mixer.config.enabled)
            }

            Card(title: "Remembered Volumes",
                 footnote: "Apps at 100% and not muted play exactly as before. Their sound is never rerouted, only listened to, to tell when they're playing.") {
                let apps = mixer.config.apps.sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }
                if apps.isEmpty {
                    SettingRow(title: "No app has its own volume yet.") { EmptyView() }
                } else {
                    ForEach(Array(apps.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 { RowDivider() }
                        SettingRow(title: entry.value.name,
                                   caption: entry.value.muted ? "Muted" : "\(Int((entry.value.volume * 100).rounded()))%") {
                            Button("Forget") { mixer.forget(entry.key) }
                        }
                    }
                    RowDivider()
                    SettingRow(title: "Reset all", caption: "Put every app back to 100%.") {
                        Button("Reset") { mixer.resetAll() }
                    }
                }
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
