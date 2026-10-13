import SwiftUI

/// The "Mouse Settings" section: pick a mouse, then edit its profile.
struct MouseSettingsView: View {
    @ObservedObject var mouse: MouseController

    var body: some View {
        Form {
            Section("All Mice") {
                Toggle(isOn: $mouse.config.restoreOnQuit) {
                    Text("Restore macOS behaviour on quit")
                    Text("When off, cursor settings stay applied after the app quits until the mouse reconnects.")
                }
                Toggle(isOn: $mouse.config.showAllPointingDevices) {
                    Text("Show all pointing devices")
                    Text("Includes trackpads and keyboards that report a pointer.")
                }
            }

            if let device = mouse.devices.first(where: { $0.id == mouse.selectedID }) {
                ProfileSections(state: mouse, device: device)
            } else {
                Section {
                    Text("No mouse connected").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Mouse Settings")
    }
}

/// The form sections for one mouse: picker, battery, cursor and wheel.
private struct ProfileSections: View {
    @ObservedObject var state: MouseController
    let device: MouseDevice

    private var profile: Binding<Profile> {
        Binding(get: { state.profile(for: device) }, set: { state.setProfile($0, for: device) })
    }

    var body: some View {
        let p = profile
        Group {
            Section {
                Picker("Mouse", selection: $state.selectedID) {
                    ForEach(state.devices) { device in
                        Text(state.label(for: device)).tag(Optional(device.id))
                    }
                }
                if let level = state.battery(for: device) {
                    LabeledContent("Battery") {
                        Label("\(level)%", systemImage: Self.batterySymbol(level))
                            .foregroundStyle(level <= 20 ? .red : .secondary)
                    }
                }
            }

            if p.wrappedValue.rewritesWheelEvents {
                if !state.accessibilityGranted {
                    PermissionNote(text: "Wheel direction, speed and smoothing are not active yet: the toolkit needs the Accessibility permission.",
                                   button: "Grant Access…") { state.requestAccessibility() }
                } else if state.wheelTapFailed {
                    PermissionNote(text: "Accessibility is granted, but the app has to restart before wheel settings take effect.",
                                   button: "Restart") { state.relaunch() }
                } else if state.needsInputMonitoring {
                    PermissionNote(text: "With several mice connected, Input Monitoring lets the toolkit tell which one is scrolling.",
                                   button: "Allow…") { state.requestInputMonitoring() }
                }
            }

            Section("Cursor") {
                OptionRow(title: "Speed", caption: "How far the cursor travels for a given hand movement.",
                          selection: p.cursorSpeedMode, options: [(.macOS, "macOS"), (.custom, "Custom")]) {
                    if p.wrappedValue.cursorSpeedMode == .custom {
                        ValueSlider(value: p.cursorSpeed, range: 0.2...3, step: 0.05) { String(format: "%.2f×", $0) }
                    }
                }
                OptionRow(title: "Acceleration", caption: "How much faster the cursor goes when you move the mouse quickly. Off is 1:1.",
                          selection: p.accelMode, options: [(.macOS, "macOS"), (.off, "Off"), (.custom, "Custom")]) {
                    if p.wrappedValue.accelMode == .custom {
                        ValueSlider(value: p.accel, range: 0...3, step: 0.005) { String(format: "%.3f", $0) }
                    }
                }
            }

            Section {
                OptionRow(title: "Vertical direction", caption: "Applies to this mouse only; the trackpad keeps the macOS setting.",
                          selection: p.verticalInverted, options: [(false, "macOS"), (true, "Inverted")]) { EmptyView() }
                OptionRow(title: "Horizontal direction", caption: "Tilt wheel or side scrolling.",
                          selection: p.horizontalInverted, options: [(false, "macOS"), (true, "Inverted")]) { EmptyView() }
                OptionRow(title: "Speed", caption: "Distance scrolled per notch.",
                          selection: p.scrollSpeedMode, options: [(.macOS, "macOS"), (.custom, "Custom")]) {
                    if p.wrappedValue.scrollSpeedMode == .custom {
                        ValueSlider(value: p.scrollSpeed, range: 0.25...5, step: 0.05) { String(format: "%.2f×", $0) }
                    }
                }
                OptionRow(title: "Acceleration", caption: "How much further fast spins scroll. Off makes every notch equal.",
                          selection: p.scrollAccelMode, options: [(.macOS, "macOS"), (.off, "Off"), (.custom, "Custom")]) {
                    if p.wrappedValue.scrollAccelMode == .custom {
                        ValueSlider(value: p.scrollAccel, range: 0...1.7, step: 0.0125) { String(format: "%.3f", $0) }
                    }
                }
                OptionRow(title: "Smoothing", caption: "Glide each notch instead of jumping.",
                          selection: p.smoothScrolling, options: [(false, "macOS"), (true, "Smooth")]) { EmptyView() }
            } header: {
                Text("Wheel")
            }

            Section {
                HStack {
                    Button("Reset to macOS") { p.wrappedValue.resetToMacOS() }
                        .disabled(p.wrappedValue.isAllMacOS)
                    if !device.connected {
                        Button("Forget This Mouse", role: .destructive) { state.forget(device) }
                    }
                    Spacer()
                }
            }
        }
    }

    private static func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// A setting with a segmented choice (always including "macOS") and optional
/// extra controls shown underneath.
private struct OptionRow<Value: Hashable, Extra: View>: View {
    let title: String
    let caption: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            extra()
        }
        .padding(.vertical, 2)
    }
}

private struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Slider(value: $value, in: range, step: step)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

private struct PermissionNote: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Spacer()
            Button(button, action: action)
        }
    }
}
