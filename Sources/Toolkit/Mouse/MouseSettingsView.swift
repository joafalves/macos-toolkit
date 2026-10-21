import SwiftUI

/// The "Mouse" section. The mouse chosen in the header is the one
/// every control below it edits.
struct MouseSettingsView: View {
    @ObservedObject var mouse: MouseController

    var body: some View {
        Page {
            ToolHeader(section: .mouse, subtitle: "Cursor and wheel settings for each mouse.", enabled: $mouse.config.enabled)

            WhenEnabled(enabled: mouse.config.enabled) {
                if let device = mouse.devices.first(where: { $0.id == mouse.selectedID }) {
                    DeviceHeader(mouse: mouse, device: device)
                    ProfileEditor(mouse: mouse, device: device)
                } else {
                    EmptyState()
                }

                Card(title: "All Mice") {
                    ToggleRow(title: "Restore macOS behaviour on quit",
                              caption: "When off, cursor settings stay applied after the app quits, until the mouse reconnects.",
                              isOn: $mouse.config.restoreOnQuit)
                    RowDivider()
                    ToggleRow(title: "Show all pointing devices",
                              caption: "Also list trackpads and keyboards that report a pointer.",
                              isOn: $mouse.config.showAllPointingDevices)
                }
                .padding(.top, 6)
            }
        }
    }
}

/// Ways to give an app its own wheel button: a key held for one press, or
/// always, for the listed apps. Shared by every mouse, since it's about the app.
private struct AutoscrollExceptions: View {
    @ObservedObject var mouse: MouseController

    var body: some View {
        OptionRow(title: "Key for the app's own wheel button",
                  caption: "Hold it while pressing the wheel to get what the app does with it, like its own autoscroll or panning. For every mouse.",
                  selection: $mouse.config.autoscrollBypass,
                  options: ModifierKey.allCases.map { ($0, $0.symbol) })
        RowDivider()
        SettingRow(title: "Leave the wheel button to these apps",
                   caption: "Always, in apps that use it themselves, like panning in design apps.") {
            Menu("Add") {
                ForEach(candidates, id: \.0) { bundleID, name in
                    Button(name) { mouse.config.autoscrollExcluded[bundleID] = name }
                }
            }
            .fixedSize()
        }
        let apps = mouse.config.autoscrollExcluded.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
        ForEach(apps, id: \.key) { bundleID, name in
            RowDivider()
            SettingRow(title: name) {
                Button("Remove") { mouse.config.autoscrollExcluded[bundleID] = nil }
            }
        }
    }

    /// Open apps that aren't in the list yet.
    private var candidates: [(String, String)] {
        var seen = Set(mouse.config.autoscrollExcluded.keys)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "computermouse")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No mouse connected").font(.headline)
            Text("Connect a mouse to set it up.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

/// Shows which mouse is being edited, and lets you switch to another.
private struct DeviceHeader: View {
    @ObservedObject var mouse: MouseController
    let device: MouseDevice

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Menu {
                    ForEach(mouse.devices) { other in
                        Button {
                            mouse.selectedID = other.id
                        } label: {
                            if other.id == device.id {
                                Label(mouse.label(for: other), systemImage: "checkmark")
                            } else {
                                Text(mouse.label(for: other))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(device.name).font(.title3.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose which mouse to edit")

                HStack(spacing: 5) {
                    Circle()
                        .fill(device.connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(device.connected ? "Connected · \(Self.shortTransport(device.transport))" : "Not connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if let level = mouse.battery(for: device) {
                HStack(spacing: 5) {
                    Image(systemName: Self.batterySymbol(level))
                    Text("\(level)%").monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(level <= 20 ? Color.red : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .help("Battery level")
            }
        }
    }

    private static func shortTransport(_ transport: String) -> String {
        transport.hasPrefix("Bluetooth") ? "Bluetooth" : transport
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

/// Cursor and wheel settings for one mouse.
private struct ProfileEditor: View {
    @ObservedObject var mouse: MouseController
    let device: MouseDevice

    private var profile: Binding<Profile> {
        Binding(get: { mouse.profile(for: device) }, set: { mouse.setProfile($0, for: device) })
    }

    var body: some View {
        let p = profile

        if p.wrappedValue.needsEventTap {
            if !mouse.accessibilityGranted {
                Banner(text: "Wheel and button settings are not active yet. They need the Accessibility permission.",
                       button: "Grant Access…") { mouse.requestAccessibility() }
            } else if mouse.wheelTapFailed {
                Banner(text: "Accessibility is granted, but the app has to restart before wheel and button settings take effect.",
                       button: "Restart") { mouse.relaunch() }
            } else if mouse.needsInputMonitoring {
                Banner(text: "With several mice connected, Input Monitoring lets the toolkit tell which one is being used.",
                       button: "Allow…") { mouse.requestInputMonitoring() }
            }
        }

        Card(title: "Cursor") {
            OptionRow(title: "Speed", caption: "How far the cursor travels for a given hand movement.",
                      selection: p.cursorSpeedMode, options: [(.macOS, "macOS"), (.custom, "Custom")]) {
                if p.wrappedValue.cursorSpeedMode == .custom {
                    ValueSlider(value: p.cursorSpeed, range: 0.2...3, step: 0.05, low: "Slow", high: "Fast") { String(format: "%.2f×", $0) }
                }
            }
            RowDivider()
            OptionRow(title: "Acceleration", caption: "How much further the cursor goes when you move quickly. Off is 1:1.",
                      selection: p.accelMode, options: [(.macOS, "macOS"), (.off, "Off"), (.custom, "Custom")]) {
                if p.wrappedValue.accelMode == .custom {
                    ValueSlider(value: p.accel, range: 0...3, step: 0.005, low: "Less", high: "More") { String(format: "%.3f", $0) }
                }
            }
        }

        Card(title: "Wheel", footnote: "Trackpad scrolling is never changed.") {
            OptionRow(title: "Vertical direction", selection: p.verticalInverted, options: [(false, "macOS"), (true, "Inverted")])
            RowDivider()
            OptionRow(title: "Horizontal direction", caption: "Tilt wheel or side scrolling.",
                      selection: p.horizontalInverted, options: [(false, "macOS"), (true, "Inverted")])
            RowDivider()
            OptionRow(title: "Speed", caption: "Distance scrolled per notch.",
                      selection: p.scrollSpeedMode, options: [(.macOS, "macOS"), (.custom, "Custom")]) {
                if p.wrappedValue.scrollSpeedMode == .custom {
                    ValueSlider(value: p.scrollSpeed, range: 0.25...5, step: 0.05, low: "Short", high: "Long") { String(format: "%.2f×", $0) }
                }
            }
            RowDivider()
            OptionRow(title: "Acceleration", caption: "How much further fast spins scroll. Off makes every notch equal.",
                      selection: p.scrollAccelMode, options: [(.macOS, "macOS"), (.off, "Off"), (.custom, "Custom")]) {
                if p.wrappedValue.scrollAccelMode == .custom {
                    ValueSlider(value: p.scrollAccel, range: 0...1.7, step: 0.0125, low: "Less", high: "More") { String(format: "%.3f", $0) }
                }
            }
            RowDivider()
            OptionRow(title: "Smoothing", caption: "Glide each notch instead of jumping.",
                      selection: p.smoothScrolling, options: [(false, "macOS"), (true, "Smooth")])
        }

        Card(title: "Buttons", footnote: "Other apps receive the back and forward buttons unchanged; most browsers and editors already handle them. A wheel click without moving stays a normal middle click.") {
            OptionRow(title: "Back and forward buttons", caption: "Go back and forward in Finder, Safari and other Apple apps.",
                      selection: p.navigationButtons, options: [(false, "macOS"), (true, "Navigate")])
            RowDivider()
            OptionRow(title: "Wheel button", caption: "Hold it and move the mouse to scroll, faster the farther you move, in any app.",
                      selection: p.autoscroll, options: [(false, "macOS"), (true, "Autoscroll")]) {
                if p.wrappedValue.autoscroll {
                    ValueSlider(value: p.autoscrollSpeed, range: 0.25...3, step: 0.05, low: "Slow", high: "Fast") { String(format: "%.2f×", $0) }
                }
            }
            if p.wrappedValue.autoscroll {
                RowDivider()
                AutoscrollExceptions(mouse: mouse)
            }
        }

        HStack(spacing: 10) {
            Button("Reset \(device.name) to macOS") { p.wrappedValue.resetToMacOS() }
                .disabled(p.wrappedValue.isAllMacOS)
            if !device.connected {
                Button("Forget This Mouse", role: .destructive) { mouse.forget(device) }
            }
        }
    }
}
