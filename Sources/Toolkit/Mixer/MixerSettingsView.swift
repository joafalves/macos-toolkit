import AppKit
import SwiftUI

/// The "Audio Mixer" section.
struct MixerSettingsView: View {
    @ObservedObject var mixer: MixerController
    @ObservedObject private var permissions = Permissions.shared
    /// The page shows the outputs and the bands, which the panel folds away.
    @StateObject private var unfolded = ViewState(true)
    /// With an equalizer for each output, the one the Equalizer card sets; nil for the one in use.
    @StateObject private var equalizerOutput = ViewState<String?>(nil)

    var body: some View {
        Page {
            ToolHeader(section: .mixer, subtitle: "Volume per app, an equalizer, and the volume keys.",
                       enabled: $mixer.config.enabled,
                       menuBar: MenuBarSwitch(isOn: $mixer.config.inMenuBar, caption: "A click opens the mixer."))

            if mixer.config.enabled, mixer.permission != .granted, !mixer.driverActive {
                Banner(text: mixer.permission == .denied
                       ? "System Audio Recording is turned off for MacOS Toolkit, so the mixer can't change the sound."
                       : "The mixer needs the System Audio Recording permission: every app's volume, the equalizer and the software volume go through it.",
                       button: mixer.permission == .denied ? "Open System Settings…" : "Allow…") { mixer.requestPermission() }
            }

            if mixer.config.enabled, !mixer.keysInstalled {
                Banner(text: "The volume keys need Accessibility. Until it's granted, macOS handles them.",
                       button: "Grant Access…") { mixer.requestAccessibility() }
            }

            // Locked, as when off, until it has what it needs.
            WhenEnabled(enabled: mixer.config.enabled && permissions.ready(mixer.permissionNeeds)) {
                // The mixer itself, the same views on the same controller as its
                // menu bar panel: everything can be changed here, and the panel
                // is the quick way to the same.
                Card(title: "Sound", badge: mixer.softwareActive ? "Software volume" : nil) {
                    MixerSoundControls(mixer: mixer, place: .page, showOutputs: unfolded)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }

                Card(title: "Equalizer") {
                    MixerEqualizerControls(mixer: mixer, place: .page, expanded: unfolded, target: equalizerOutput)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }

                Card(title: "Apps", footnote: "Click an app to mute it; right-click it to hide it until it plays again, or to exclude it.") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Each app's volume, on top of the main volume.")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            ResetAppsButton(mixer: mixer)
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                        MixerAppList(mixer: mixer, place: .page)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }

                Card(title: "Options") {
                    // A pop-up rather than segments: five choices don't fit beside a caption.
                    SettingRow(title: "Look in the menu bar", caption: "Shown when it's in the menu bar, which is set at the top of the page.") {
                        Picker("Menu bar icon", selection: $mixer.config.look) {
                            Text("Mixer").tag(MixerMenuBarIcon.mixer)
                            Text("Volume").tag(MixerMenuBarIcon.volume)
                            Text("Volume and percentage").tag(MixerMenuBarIcon.volumePercent)
                            // "Pill", as Keep Awake and System Stats call this look.
                            Text("Volume pill").tag(MixerMenuBarIcon.volumeBadge)
                            Text("Small volume pill").tag(MixerMenuBarIcon.volumeSmallPill)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    RowDivider()
                    ToggleRow(title: "Volume for each output",
                              caption: "Each output keeps its own volume, as macOS does. Off, the volume stays the same when you switch outputs.",
                              isOn: $mixer.config.volumePerOutput)
                    RowDivider()
                    ToggleRow(title: "Equalizer for each output",
                              caption: "Each output keeps its own equalizer, so headphones and speakers can sound different. Off, one equalizer for all of them.",
                              isOn: $mixer.config.equalizerPerOutput)
                }

                Card(title: "Volume Keys") {
                    OptionRow(title: "Each press", caption: "• Fine: 32 presses from silent to full, about 3% each.\n• Round: 20 presses, 5% each, so the volume stays on round numbers.\n• Standard: 16 presses, about 6% each, as macOS's own keys.\n• Large: 10 presses, 10% each.",
                              selection: $mixer.config.keyStep,
                              options: [(.fine, "Fine"), (.round, "Round"), (.standard, "Standard"), (.large, "Large")])
                    RowDivider()
                    SettingRow(title: "With ⇧⌥", caption: "How much a press moves the volume while Shift and Option are held.") { EmptyView() } extra: {
                        let range = MixerConfig.fineStepRange
                        ValueSlider(value: Binding(get: { Double(mixer.config.fineStep) }, set: { mixer.config.fineStep = Int($0.rounded()) }),
                                    range: Double(range.lowerBound)...Double(range.upperBound), step: 1, low: "Smaller", high: "Larger") {
                            "\(Int($0))"
                        }
                    }
                }

                Card(title: "Excluded Apps",
                     footnote: "These apps are hidden from the mixer and always play at the main volume.") {
                    let ignored = mixer.config.ignored.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
                    ForEach(Array(ignored.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 { RowDivider() }
                        SettingRow(title: .verbatim(entry.value)) {
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

            // Not locked with the rest: with the driver, the permission isn't needed.
            WhenEnabled(enabled: mixer.config.enabled) {
                Card(title: "Audio Driver", footnote: driverNote) {
                    ToggleRow(title: "Use the audio driver",
                              caption: "Apps play to a device of the toolkit's, so nothing records: no purple dot, no System Audio Recording, and a microphone never waits for the mixer. Installing it asks for your password, and sound stops for a moment.",
                              isOn: Binding(get: { mixer.config.usesDriver }, set: { mixer.setUsesDriver($0) }),
                              badge: "Preview")
                    if mixer.driverInstall == .outdated, mixer.config.usesDriver {
                        RowDivider()
                        SettingRow(title: "Update the audio driver", caption: "This version of the app comes with another driver. Updating it asks for your password, and sound stops for a moment.") {
                            Button("Update…") { mixer.setUsesDriver(true) }
                                .disabled(mixer.driverBusy)
                        }
                    }
                    if [.current, .outdated].contains(mixer.driverInstall), !mixer.config.usesDriver {
                        RowDivider()
                        SettingRow(title: "Remove the audio driver", caption: "It stays out of the way while it's off, and macOS keeps a small process for it. Removing it asks for your password.") {
                            Button("Remove…") { mixer.removeDriver() }
                                .disabled(mixer.driverBusy)
                        }
                    }
                }
            }
        }
    }

    private var driverNote: LocalizedStringKey? {
        switch mixer.driverProblem {
        case .none: return nil
        case .notInApplications: return "The driver only answers an app in the Applications folder, so the mixer is using taps."
        case .refused: return "The driver didn't accept this copy of the app, so the mixer is using taps."
        case .notInstalled: return "The driver isn't installed, so the mixer is using taps."
        case .outdated: return "The installed driver isn't the one this version of the app needs, so the mixer is using taps until it's updated."
        case .installFailed: return "The driver wasn't installed."
        case .noDevice: return "The driver's device didn't appear, so the mixer is using taps."
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
