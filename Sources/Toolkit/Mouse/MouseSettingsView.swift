import SwiftUI

/// The "Mouse" section: the list of mice and the settings for all of them,
/// or, once one is clicked, that mouse's own page, as System Settings does
/// for a Bluetooth device.
struct MouseSettingsView: View {
    @ObservedObject var mouse: MouseController
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Group {
            if mouse.config.enabled, let device = mouse.devices.first(where: { $0.id == mouse.openID }) {
                Page {
                    MousePage(mouse: mouse, device: device)
                }
            } else {
                Page {
                    ToolHeader(section: .mouse, subtitle: "Cursor and wheel settings for each mouse.", enabled: $mouse.config.enabled,
                               menuBar: MenuBarSwitch(isOn: $mouse.config.menuBarIcon, caption: "A click shows each mouse and its charge."))

                    if mouse.config.enabled, !permissions.isGranted(.accessibility) {
                        Banner(text: "Wheel and button settings are not active yet. They need the Accessibility permission.",
                               button: "Grant Access…") { mouse.requestAccessibility() }
                    }

                    WhenEnabled(enabled: mouse.config.enabled) {
                        MiceList(mouse: mouse)

                        Card(title: "All Mice") {
                            ToggleRow(title: "Restore macOS behavior on quit",
                                      caption: "When off, cursor settings stay applied after the app quits, until the mouse reconnects.",
                                      isOn: $mouse.config.restoreOnQuit)
                            RowDivider()
                            ToggleRow(title: "Show all pointing devices",
                                      caption: "Also list trackpads and keyboards that report a pointer.",
                                      isOn: $mouse.config.showAllPointingDevices)
                        }
                    }
                }
            }
        }
        // Coming back to the section starts at the list.
        .onDisappear { if !mouse.isPreview { mouse.openID = nil } }
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
            SettingRow(title: .verbatim(name)) {
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

/// Every mouse the toolkit knows: those connected, then those it keeps
/// settings for while they're away. A click on one opens its page.
private struct MiceList: View {
    @ObservedObject var mouse: MouseController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mice").font(.headline)
                Spacer()
                Button {
                    mouse.refresh(force: false)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Look for connected mice again")
            }
            .padding(.leading, 2)

            Card(footnote: mouse.devices.isEmpty ? nil : "Click a mouse to change its settings.") {
                if mouse.devices.isEmpty {
                    EmptyState()
                } else {
                    // As tall as its rows up to five, then it scrolls, with
                    // half the sixth showing there's more.
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollView { rows }
                    }
                    .frame(maxHeight: 5.5 * (MouseRow.height + 1))
                }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(mouse.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { RowDivider() }
                MouseRow(mouse: mouse, device: device)
            }
        }
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
        .padding(.vertical, 28)
    }
}

/// Whether a mouse is connected, and how.
struct MouseConnection: View {
    let device: MouseDevice
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(device.connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(device.connected ? "Connected · \(MouseController.shortTransport(device.transport))" : "Not connected")
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A mouse's charge, red when it's low.
struct MouseBattery: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(level))
            Text(verbatim: "\(level)%").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(level <= 20 ? Color.red : Color.primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .help("Battery level")
    }

    private static func symbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// One mouse in the list, the whole row a button to its page, lit while
/// the pointer is on it.
private struct MouseRow: View {
    /// Fixed, so the list knows how tall five are.
    static let height: CGFloat = 54
    @ObservedObject var mouse: MouseController
    let device: MouseDevice
    @StateObject private var hovered = ViewState(false)

    var body: some View {
        Button {
            mouse.openID = device.id
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: AppSection.mouse.symbol, color: device.connected ? AppSection.mouse.color : .gray, size: 30)
                    .opacity(device.connected ? 1 : 0.6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: mouse.label(for: device))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MouseConnection(device: device)
                }
                Spacer(minLength: 0)
                if let level = mouse.battery(for: device) {
                    MouseBattery(level: level)
                }
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(hovered.value ? .secondary : .tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .background(hovered.value ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Show this mouse's settings")
    }
}

/// One mouse's page: back to the list, its name, its settings, and what
/// can be done with it.
private struct MousePage: View {
    @ObservedObject var mouse: MouseController
    let device: MouseDevice
    @StateObject private var renaming = ViewState(false)
    @StateObject private var newName = ViewState("")
    @StateObject private var forgetting = ViewState(false)

    var body: some View {
        // As System Settings heads a device's page: the toolbar has its name,
        // and the card on top says what it is and how it's doing.
        HStack(spacing: 12) {
            IconTile(symbol: AppSection.mouse.symbol, color: device.connected ? AppSection.mouse.color : .gray, size: 40)
                .opacity(device.connected ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: mouse.label(for: device))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                MouseConnection(device: device, font: .subheadline)
            }
            Spacer(minLength: 0)
            if let level = mouse.battery(for: device) {
                MouseBattery(level: level)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

        ProfileEditor(mouse: mouse, device: device)

        HStack(spacing: 10) {
            Button("Reset to macOS") { mouse.reset(device) }
                .disabled(mouse.profile(for: device).isAllMacOS)
            Button("Rename…") {
                newName.value = device.name
                renaming.value = true
            }
            Spacer()
            Button("Forget This Mouse…", role: .destructive) { forgetting.value = true }
                .disabled(mouse.config.profiles[device.id] == nil)
        }
        .alert("Rename Mouse", isPresented: $renaming.value) {
            TextField("Name", text: $newName.value)
            Button("Rename") { mouse.rename(device, to: newName.value) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty for the name macOS gives it, \(mouse.systemName(of: device)).")
        }
        .confirmationDialog(Text("Forget \(mouse.label(for: device))?"), isPresented: $forgetting.value) {
            Button("Forget", role: .destructive) {
                mouse.openID = nil
                mouse.forget(device)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(device.connected ? "Its settings go back to macOS's." : "Its settings go back to macOS's, and it leaves this list.")
        }
    }
}

/// Cursor and wheel settings for one mouse.
private struct ProfileEditor: View {
    @ObservedObject var mouse: MouseController
    @ObservedObject private var permissions = Permissions.shared
    let device: MouseDevice

    private var profile: Binding<Profile> {
        Binding(get: { mouse.profile(for: device) }, set: { mouse.setProfile($0, for: device) })
    }

    private static func distanceCaption(_ mode: ScrollMode) -> LocalizedStringKey {
        switch mode {
        case .macOS: return "macOS's own: a slow notch barely moves, fast spins go further. The slider scales it."
        case .fixed: return "Every notch the same distance, however fast the wheel turns."
        case .curve: return "A single notch goes one distance and fast spins further, along the graph."
        }
    }

    var body: some View {
        let p = profile

        // Locked below until granted; cursor settings work without it.
        if !permissions.isGranted(.accessibility) {
            Banner(text: "Wheel and button settings are not active yet. They need the Accessibility permission.",
                   button: "Grant Access…") { mouse.requestAccessibility() }
        } else if p.wrappedValue.needsEventTap, mouse.wheelTapFailed {
            Banner(text: "Accessibility is granted, but the app has to restart before wheel and button settings take effect.",
                   button: "Restart") { Relaunch.now() }
        }

        Card(title: "Cursor") {
            OptionRow(title: "Speed", caption: "How far the cursor travels for a given hand movement.",
                      selection: p.cursorSpeedMode, options: [(.macOS, "macOS"), (.custom, "Custom")]) {
                if p.wrappedValue.cursorSpeedMode == .custom {
                    ValueSlider(value: p.cursorSpeed, range: 0.2...3, step: 0.05, low: "Slow", high: "Fast") { String(format: "%.2f×", locale: .current, $0) }
                }
            }
            RowDivider()
            OptionRow(title: "Acceleration", caption: "How much further the cursor goes when you move quickly. Off is 1:1.",
                      selection: p.accelMode, options: [(.macOS, "macOS"), (.off, "Off"), (.custom, "Custom")]) {
                if p.wrappedValue.accelMode == .custom {
                    ValueSlider(value: p.accel, range: 0...3, step: 0.005, low: "Less", high: "More") { String(format: "%.2f", locale: .current, $0) }
                }
            }
        }

        // Every wheel and button setting goes through the event tap, which
        // needs Accessibility: locked, as when the tool is off, until then.
        WhenEnabled(enabled: permissions.isGranted(.accessibility)) {
            Card(title: "Wheel", footnote: "Trackpad scrolling is never changed. Fixed and Curve set how far the wheel scrolls up and down; sideways, a tilt scrolls a line at a time.") {
                OptionRow(title: "Vertical direction", selection: p.verticalInverted, options: [(false, "macOS"), (true, "Inverted")])
                RowDivider()
                OptionRow(title: "Horizontal direction", caption: "Tilt wheel or side scrolling.",
                          selection: p.horizontalInverted, options: [(false, "macOS"), (true, "Inverted")])
                RowDivider()
                OptionRow(title: "Distance", caption: Self.distanceCaption(p.wrappedValue.scrollMode),
                          selection: p.scrollMode, options: [(.macOS, "macOS"), (.fixed, "Fixed"), (.curve, "Curve")]) {
                    switch p.wrappedValue.scrollMode {
                    case .macOS:
                        ValueSlider(value: p.scrollSpeed, range: 0.25...5, step: 0.05, low: "Short", high: "Long") { String(format: "%.2f×", locale: .current, $0) }
                    case .fixed:
                        ValueSlider(value: p.scrollLines, range: Profile.scrollLinesRange, step: 1, low: "Short", high: "Long") {
                            $0 == 1 ? String(localized: "1 line") : String(localized: "\(Int($0)) lines")
                        }
                    case .curve:
                        HStack {
                            Text("Shape")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Shape", selection: p.scrollCurve.afterUpdate) {
                                Text("Linear").tag(ScrollCurve.linear)
                                Text("Curve").tag(ScrollCurve.curve)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        WheelCurveEditor(start: p.scrollCurveStart, end: p.scrollCurveEnd, bend: p.scrollCurveBend,
                                         curved: p.wrappedValue.scrollCurve == .curve)
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
                        ValueSlider(value: p.autoscrollPace, range: Profile.autoscrollPaceRange, step: 0.05, low: "Slow", high: "Fast") { String(format: "%.2f×", locale: .current, $0) }
                    }
                }
                if p.wrappedValue.autoscroll {
                    RowDivider()
                    AutoscrollExceptions(mouse: mouse)
                }
            }
        }
    }
}
