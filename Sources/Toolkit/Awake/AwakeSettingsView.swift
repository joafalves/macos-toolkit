import AppKit
import SwiftUI

/// The "Keep Awake" section.
struct AwakeSettingsView: View {
    @ObservedObject var awake: AwakeController
    @ObservedObject var mouse: MouseController

    /// Rows that linked settings go to.
    private enum Anchor {
        static let keepDisplayOn = "awake.keepDisplayOn"
        static let stayAvailable = "awake.stayAvailable"
    }

    var body: some View {
        Page {
            ToolHeader(section: .awake, subtitle: "Keeps the Mac from sleeping, for a while or until you turn it off.",
                       enabled: $awake.config.enabled)

            if awake.config.enabled, awake.config.stayAvailable, !awake.accessibility {
                Banner(text: "Stay available needs the Accessibility permission.",
                       button: "Grant Access…") { mouse.requestAccessibility() }
            }

            WhenEnabled(enabled: awake.config.enabled) {
                Card {
                    SettingRow(title: .verbatim(awake.status),
                               caption: awake.isOn ? nil : awake.cantStart.map { .verbatim($0) } ?? "Start one here, from the menu bar, or with the shortcut.") {
                        if awake.isOn {
                            Button("Turn Off") { awake.turnOff() }
                        } else {
                            Menu("Turn On") {
                                Button("Until I Turn It Off") { awake.turnOn(for: nil) }
                                Divider()
                                Menu("Minutes") {
                                    ForEach(AwakeController.minutes, id: \.self) { minutes in
                                        Button(AwakeController.title(minutes: minutes)) { awake.turnOn(for: TimeInterval(minutes * 60)) }
                                    }
                                }
                                Menu("Hours") {
                                    ForEach(AwakeController.hours, id: \.self) { hours in
                                        Button(AwakeController.title(hours: hours)) { awake.turnOn(for: TimeInterval(hours * 3600)) }
                                    }
                                }
                                Button("Until a Time…") { DispatchQueue.main.async { awake.askUntil() } }
                            }
                            .fixedSize()
                            .disabled(awake.batteryLow)
                        }
                    }
                    // Ticks with the minutes left.
                    .id(awake.minute)
                }

                Card(title: "Options") {
                    SettingRow(title: "In the menu bar", caption: "A pill fills with the time left; with no end it's full. The cup alone is filled while it's on.") {
                        Picker("Menu bar icon", selection: $awake.config.menuBarIcon) {
                            Text("None").tag(AwakeMenuBarIcon.none)
                            Text("Pill").tag(AwakeMenuBarIcon.pill)
                            Text("Cup and time").tag(AwakeMenuBarIcon.cupAndTime)
                            Text("Cup").tag(AwakeMenuBarIcon.cup)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    // The cup alone shows no time to count with.
                    if awake.config.menuBarIcon != .none, awake.config.menuBarIcon != .cup {
                        RowDivider()
                        ToggleRow(title: "Count up with no end",
                                  caption: "When it's on until you turn it off, the menu bar shows how long it's been on.",
                                  isOn: $awake.config.showElapsed)
                    }
                    RowDivider()
                    ShortcutRow(title: "Shortcut", caption: "Turns it on with no end, or off again.",
                                shortcut: $awake.config.shortcut, defaultValue: .none)
                    if awake.shortcutFailed {
                        Text("macOS didn't accept this shortcut; another app may have it.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                    RowDivider()
                    ToggleRow(title: "Keep the display on",
                              caption: "Off lets the display sleep while the Mac stays awake, for downloads and long jobs.",
                              isOn: Binding(get: { awake.config.displayStaysOn }, set: { awake.config.keepDisplayOn = $0 }),
                              link: awake.config.stayAvailable ? .heldBy("On while Stay available is on", anchor: Anchor.stayAvailable) : nil)
                        .settingAnchor(Anchor.keepDisplayOn)
                    RowDivider()
                    ToggleRow(title: "Stay awake with the lid closed",
                              caption: "On battery too. Asks for your password once, to allow it. A closed Mac in a bag can get hot; Keep Awake stops if it does.",
                              isOn: Binding(get: { awake.config.lidClosed && awake.lidReady }, set: { awake.setLidClosed($0) }))
                    RowDivider()
                    SettingRow(title: "Stop on battery below", caption: "And don't start below it. Charging never stops it.") {
                        Picker("Stop on battery below", selection: $awake.config.batteryFloor) {
                            Text("Never").tag(0)
                            ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                Card(title: "When It Ends", footnote: "When its time is up, or the battery or the heat stops it. Not when you turn it off.") {
                    ToggleRow(title: "Notification", isOn: $awake.config.notifyAtEnd)
                    RowDivider()
                    ToggleRow(title: "Sound", isOn: $awake.config.soundAtEnd)
                }

                Card(title: "Status") {
                    ToggleRow(title: "Stay available",
                              caption: "Your status stays available while the Mac is awake.",
                              isOn: $awake.config.stayAvailable,
                              link: awake.config.stayAvailable ? .holds("Keeps the display on", anchor: Anchor.keepDisplayOn) : nil)
                        .settingAnchor(Anchor.stayAvailable)
                    if awake.config.stayAvailable {
                        RowDivider()
                        OptionRow(title: "Method",
                                  caption: awake.config.stayAvailableMethod == .signal
                                      ? "Nothing on screen changes."
                                      : "The pointer drifts to a spot nearby. Any key or mouse move takes it back.",
                                  selection: $awake.config.stayAvailableMethod,
                                  options: [(.signal, "Signal only"), (.mouseMove, "Mouse move")])
                        RowDivider()
                        SettingRow(title: "Every", caption: "Only after this long without a key or mouse move.") {
                            Picker("Every", selection: $awake.config.stayAvailableEvery) {
                                ForEach([60.0, 120, 180, 240, 300], id: \.self) { Text("\(Int($0 / 60)) min").tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }
}
