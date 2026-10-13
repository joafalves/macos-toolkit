import SwiftUI

private let generalTag = "general"

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section("Mice") {
                    if state.devices.isEmpty {
                        Text("No mouse connected").foregroundStyle(.secondary)
                    }
                    ForEach(state.devices) { device in
                        DeviceRow(device: device).tag(device.id)
                    }
                }
                Section {
                    Label("General", systemImage: "gearshape").tag(generalTag)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            if state.selection == generalTag {
                GeneralView(state: state)
            } else if let device = state.devices.first(where: { $0.id == state.selection }) {
                ProfileView(state: state, device: device)
            } else {
                Text("Select a mouse").foregroundStyle(.secondary)
            }
        }
        .onAppear { selectDefault() }
        .onChange(of: state.devices) { selectDefault() }
        .frame(minWidth: 720, minHeight: 560)
    }

    private func selectDefault() {
        if state.selection == generalTag || state.devices.contains(where: { $0.id == state.selection }) { return }
        state.selection = state.devices.first?.id ?? generalTag
    }
}

private struct DeviceRow: View {
    let device: MouseDevice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "computermouse")
                .foregroundStyle(device.connected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                Text(device.connected ? device.transport : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(device.connected ? 1 : 0.6)
    }
}

// MARK: - Per-mouse settings

private struct ProfileView: View {
    @ObservedObject var state: AppState
    let device: MouseDevice

    private var profile: Binding<Profile> {
        Binding(get: { state.profile(for: device) }, set: { state.setProfile($0, for: device) })
    }

    var body: some View {
        let p = profile
        Form {
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
            } footer: {
                if p.wrappedValue.rewritesWheelEvents, !state.accessibilityGranted {
                    PermissionNote(text: "Direction, speed and smoothing need the Accessibility permission to take effect.",
                                   button: "Grant Access…") { state.requestAccessibility() }
                } else if p.wrappedValue.rewritesWheelEvents, state.needsInputMonitoring {
                    PermissionNote(text: "With several mice connected, Input Monitoring lets Tiller tell which one is scrolling.",
                                   button: "Allow…") { state.requestInputMonitoring() }
                }
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
        .formStyle(.grouped)
        .navigationTitle(device.name)
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
        .padding(.top, 4)
    }
}

// MARK: - General

private struct GeneralView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                Toggle(isOn: $state.config.restoreOnQuit) {
                    Text("Restore macOS behaviour on quit")
                    Text("When off, cursor settings stay applied after Tiller quits until the mouse reconnects.")
                }
                Toggle(isOn: $state.config.showAllPointingDevices) {
                    Text("Show all pointing devices")
                    Text("Includes trackpads and keyboards that report a pointer.")
                }
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if state.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { state.requestAccessibility() }
                    }
                }
                Text("Needed for wheel direction, speed and smoothing. Cursor settings work without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
