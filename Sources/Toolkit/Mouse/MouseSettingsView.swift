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
                    ToolHeader(section: .mouse, subtitle: "Pointer, scrolling and buttons for each mouse.", enabled: $mouse.config.enabled,
                               menuBar: MenuBarSwitch(isOn: $mouse.config.menuBarIcon, caption: "A click shows each mouse and its charge."))

                    if mouse.config.enabled, !permissions.isGranted(.accessibility) {
                        Banner(text: "Scrolling and button settings are not active yet. They need the Accessibility permission.",
                               button: "Grant Access…") { mouse.requestAccessibility() }
                    }

                    WhenEnabled(enabled: mouse.config.enabled) {
                        MiceList(mouse: mouse)

                        Card(title: "All Mice") {
                            ToggleRow(title: "Restore macOS behavior on quit",
                                      caption: "When off, pointer settings stay applied after the app quits, until the mouse reconnects.",
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

/// The tabs of a mouse's page. The raw values name them in the search's index.
enum MouseTab: String, CaseIterable {
    case pointer, scrolling, buttons

    var title: String {
        switch self {
        case .pointer: return String(localized: "Pointer")
        case .scrolling: return String(localized: "Scrolling")
        case .buttons: return String(localized: "Buttons")
        }
    }
}

/// One mouse's page: what it is and how it's doing, what can be done with it,
/// and its settings, a tab for each part of the mouse.
private struct MousePage: View {
    @ObservedObject var mouse: MouseController
    @ObservedObject private var permissions = Permissions.shared
    let device: MouseDevice
    @StateObject private var renaming = ViewState(false)
    @StateObject private var newName = ViewState("")
    @StateObject private var forgetting = ViewState(false)
    @StateObject private var copying = ViewState(false)

    var body: some View {
        header
            .alert("Rename Mouse", isPresented: $renaming.value) {
                TextField("Name", text: $newName.value)
                Button("Rename") { mouse.rename(device, to: newName.value) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave it empty for the name macOS gives it, \(mouse.systemName(of: device)).")
            }
            .sheet(isPresented: $copying.value) {
                CopySettingsSheet(mouse: mouse, device: device) { copying.value = false }
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

        // The pointer works without it; scrolling and buttons wait for it.
        if !permissions.isGranted(.accessibility) {
            Banner(text: "Scrolling and button settings are not active yet. They need the Accessibility permission.",
                   button: "Grant Access…") { mouse.requestAccessibility() }
        } else if mouse.profile(for: device).needsEventTap, mouse.wheelTapFailed {
            Banner(text: "Accessibility is granted, but the app has to restart before scrolling and button settings take effect.",
                   button: "Restart") { Relaunch.now() }
        }

        Picker("Page", selection: $mouse.tab.afterUpdate) {
            ForEach(MouseTab.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)

        ProfileEditor(mouse: mouse, device: device, tab: mouse.tab)
    }

    /// As System Settings heads a device's page: the toolbar has its name, the
    /// card says what it is and how it's doing, and its menu what can be done.
    private var header: some View {
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
            Menu {
                Button("Rename…") {
                    newName.value = device.name
                    renaming.value = true
                }
                Button("Copy Settings to Another Mouse…") { copying.value = true }
                    .disabled(!mouse.devices.contains { $0.id != device.id })
                Button("Reset to macOS") { mouse.reset(device) }
                    .disabled(mouse.profile(for: device).isAllMacOS)
                Divider()
                Button("Forget This Mouse…", role: .destructive) { forgetting.value = true }
                    .disabled(mouse.config.profiles[device.id] == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rename, copy, reset or forget this mouse")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The other mice, to give one or more of them this mouse's settings.
struct CopySettingsSheet: View {
    @ObservedObject var mouse: MouseController
    let device: MouseDevice
    let close: () -> Void
    @StateObject private var chosen: ViewState<Set<String>>

    init(mouse: MouseController, device: MouseDevice, chosen: Set<String> = [], close: @escaping () -> Void) {
        self.mouse = mouse
        self.device = device
        self.close = close
        _chosen = StateObject(wrappedValue: ViewState(chosen))
    }

    private var others: [MouseDevice] { mouse.devices.filter { $0.id != device.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: AppSection.mouse.symbol, color: AppSection.mouse.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copy Settings").font(.title3.weight(.semibold))
                    Text("Give other mice the cursor, wheel and button settings of \(mouse.label(for: device)).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(others.enumerated()), id: \.element.id) { index, other in
                    if index > 0 { Divider() }
                    row(other)
                }
            }
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

            Text("Their own settings are replaced. Their names stay.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    mouse.copySettings(of: device, to: others.filter { chosen.value.contains($0.id) })
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.value.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// The checkbox apart from its label, so it sits in the middle of the
    /// row's two lines rather than on the first one's baseline; a click
    /// anywhere on the row ticks it.
    private func row(_ other: MouseDevice) -> some View {
        let isOn = Binding(get: { chosen.value.contains(other.id) },
                           set: { on in if on { chosen.value.insert(other.id) } else { chosen.value.remove(other.id) } })
        return HStack(spacing: 10) {
            Toggle(isOn: isOn) { Text(verbatim: mouse.label(for: other)) }
                .toggleStyle(.checkbox)
                .labelsHidden()
            IconTile(symbol: AppSection.mouse.symbol, color: other.connected ? AppSection.mouse.color : .gray, size: 26)
                .opacity(other.connected ? 1 : 0.6)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: mouse.label(for: other))
                    .lineLimit(1)
                    .truncationMode(.middle)
                MouseConnection(device: other)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }
}

/// What the page calls each button.
enum ButtonNames {
    /// The buttons a mouse keeps to itself that have a name here.
    static let named: Set<UInt16> = [0x00FD, 0x00C3, 0x00C4]

    static func title(_ button: MouseButtonID) -> LocalizedStringResource {
        switch button {
        case .number(2): return "Wheel button"
        case .number(3): return "Back button"
        case .number(4): return "Forward button"
        case .number(let n): return "Button \(n + 1)"
        case .control(0x00FD): return "DPI button"
        case .control(0x00C3): return "Gesture button"
        case .control(0x00C4): return "Wheel mode button"
        case .control(0x0052): return "Wheel button"
        case .control(0x0053): return "Back button"
        case .control(0x0056): return "Forward button"
        case .control(let cid): return "Mouse button \(String(format: "%04X", cid))"
        }
    }
}

extension ButtonAction {
    var title: String {
        switch self {
        case .nothing: return String(localized: "Nothing")
        case .autoscroll: return String(localized: "Autoscroll")
        case .floatingDock: return String(localized: "Floating Dock")
        case .back: return String(localized: "Back")
        case .forward: return String(localized: "Forward")
        case .missionControl: return String(localized: "Mission Control")
        case .showDesktop: return String(localized: "Show Desktop")
        case .shortcut: return String(localized: "Keyboard shortcut")
        case .openApp: return String(localized: "Open an app")
        }
    }
}

/// A mouse's settings, one tab at a time.
private struct ProfileEditor: View {
    @ObservedObject var mouse: MouseController
    @ObservedObject private var permissions = Permissions.shared
    let device: MouseDevice
    let tab: MouseTab

    private var profile: Binding<Profile> {
        Binding(get: { mouse.profile(for: device) }, set: { mouse.setProfile($0, for: device) })
    }

    var body: some View {
        switch tab {
        case .pointer: pointerTab
        // Scrolling and buttons go through the event tap, which needs
        // Accessibility: locked, as when the tool is off, until then.
        case .scrolling: WhenEnabled(enabled: permissions.isGranted(.accessibility)) { scrollingTab }
        case .buttons: WhenEnabled(enabled: permissions.isGranted(.accessibility)) { buttonsTab }
        }
    }

    // MARK: Pointer

    @ViewBuilder
    private var pointerTab: some View {
        let p = profile
        Card {
            SettingRow(title: "Speed", caption: "How far the pointer travels for a given hand movement.") {
                UseMacOSButton(shown: p.wrappedValue.cursorSpeedMode == .custom) { p.wrappedValue.cursorSpeedMode = .macOS }
            } extra: {
                ValueSlider(value: speed, range: 0.2...3, step: 0.05, low: "Slow", high: "Fast") { value in
                    p.wrappedValue.cursorSpeedMode == .macOS ? String(localized: "macOS") : String(format: "%.2f×", locale: .current, value)
                }
            }
            RowDivider()
            OptionRow(title: "Acceleration", caption: "How much further the pointer goes when you move quickly. Off is 1:1.",
                      selection: p.accelMode, options: [(.macOS, "macOS"), (.off, "Off"), (.custom, "Custom")]) {
                if p.wrappedValue.accelMode == .custom {
                    ValueSlider(value: p.accel, range: 0...3, step: 0.005, low: "Less", high: "More") { String(format: "%.2f", locale: .current, $0) }
                }
            }
        }
    }

    /// The speed as the slider shows it: macOS's own is 1×, the resolution
    /// macOS assumes for a mouse, and moving it there hands the speed back.
    private var speed: Binding<Double> {
        let p = profile
        return Binding(get: { p.wrappedValue.cursorSpeedMode == .custom ? p.wrappedValue.cursorSpeed : 1 },
                       set: { value in
                           if abs(value - 1) < 0.001 {
                               p.wrappedValue.cursorSpeedMode = .macOS
                           } else {
                               p.wrappedValue.cursorSpeedMode = .custom
                               p.wrappedValue.cursorSpeed = value
                           }
                       })
    }

    // MARK: Scrolling

    private static func distanceCaption(_ mode: ScrollMode) -> LocalizedStringKey {
        switch mode {
        case .macOS: return "macOS's own: a slow notch barely moves, fast spins go further. The slider scales it."
        case .fixed: return "Every notch scrolls this far on screen, however fast the wheel turns, so most apps scroll alike."
        case .curve: return "A single notch scrolls one distance on screen and fast spins further, along the graph."
        }
    }

    @ViewBuilder
    private var scrollingTab: some View {
        let p = profile
        Card(footnote: "Trackpad scrolling is never changed.") {
            OptionRow(title: "Distance", caption: Self.distanceCaption(p.wrappedValue.scrollMode),
                      selection: Binding(get: { p.wrappedValue.scrollMode }, set: { p.wrappedValue.setScrollMode($0) }),
                      options: [(.macOS, "macOS"), (.fixed, "Fixed"), (.curve, "Curve")]) {
                switch p.wrappedValue.scrollMode {
                case .macOS:
                    ValueSlider(value: p.scrollSpeed, range: 0.25...5, step: 0.05, low: "Short", high: "Long") { String(format: "%.2f×", locale: .current, $0) }
                case .fixed:
                    ValueSlider(value: p.scrollDistance, range: Profile.scrollDistanceRange, step: 5, low: "Short", high: "Long") { WheelCurveEditor.points($0) }
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
                    WheelCurveEditor(start: p.scrollCurveFrom, end: p.scrollCurveTo, bend: p.scrollCurveBend,
                                     curved: p.wrappedValue.scrollCurve == .curve)
                }
            }
            RowDivider()
            SettingRow(title: "Smooth scrolling", caption: "Each notch glides instead of jumping, as far as it would jump.") {
                Toggle("Smooth scrolling", isOn: p.smoothScrolling)
                    .toggleStyle(.switch)
                    .labelsHidden()
            } extra: {
                if p.wrappedValue.smoothScrolling {
                    HStack {
                        Text("Glide")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Glide", selection: p.glide.afterUpdate) {
                            Text("Normal").tag(GlideSpeed.normal)
                            Text("Fast").tag(GlideSpeed.fast)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }

        Card(title: "Direction") {
            ToggleRow(title: "Reverse vertical scrolling", caption: "The opposite of macOS's Natural scrolling, for this mouse only.",
                      isOn: p.verticalInverted)
            RowDivider()
            ToggleRow(title: "Reverse horizontal scrolling", caption: "Tilt wheel or side scrolling.", isOn: p.horizontalInverted)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttonsTab: some View {
        Card(footnote: "Press a button on the mouse to find it here; one that isn't listed is added. The left and right buttons always click.") {
            ButtonList(mouse: mouse, device: device, profile: profile)
        }
    }
}

/// Hands a setting back to macOS: there only while it isn't macOS's.
private struct UseMacOSButton: View {
    let shown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Use macOS's", systemImage: "arrow.uturn.backward")
        }
        .controlSize(.small)
        // Kept in place while hidden, so the row doesn't change height.
        .opacity(shown ? 1 : 0)
        .disabled(!shown)
        .accessibilityHidden(!shown)
    }
}

/// Every button of the mouse worth a row: the wheel, back and forward
/// buttons most mice have, those it keeps to itself, and any other that has
/// an action or was pressed. Each does what macOS does until given one.
private struct ButtonList: View {
    @ObservedObject var mouse: MouseController
    let device: MouseDevice
    @Binding var profile: Profile
    @StateObject private var finder = ButtonFinder()

    private var buttons: [MouseButtonID] {
        var numbered: Set<Int> = [2, 3, 4]
        // Those it keeps to itself by name: a keyboard can report twenty, its
        // function keys among them, which show once pressed or given an action.
        var controls: [UInt16] = (mouse.hidppControls[device.id] ?? []).map(\.cid).filter(ButtonNames.named.contains)
        for button in profile.buttonActions.map(\.button) + finder.found {
            switch button {
            case .number(let n): numbered.insert(n)
            case .control(let cid): if !controls.contains(cid) { controls.append(cid) }
            }
        }
        return numbered.sorted().map { .number($0) } + controls.map { .control($0) }
    }

    var body: some View {
        // One view: on a ForEach, these would be each row's, and a row going
        // (a button set back to Default) would stop the finder.
        VStack(spacing: 0) {
            ForEach(Array(buttons.enumerated()), id: \.element) { index, button in
                if index > 0 { RowDivider() }
                ButtonRow(button: button, assignment: assignment(button), pace: $profile.autoscrollPace, lit: finder.lit == button)
                if button == .number(2), profile.assignment(for: button)?.action == .autoscroll {
                    RowDivider()
                    AutoscrollExceptions(mouse: mouse)
                }
            }
        }
        .onAppear { finder.start(mouse: mouse, deviceID: device.id) }
        .onDisappear { finder.stop() }
    }

    /// Nil while the button does what macOS does.
    private func assignment(_ button: MouseButtonID) -> Binding<ButtonAssignment?> {
        Binding(get: { profile.assignment(for: button) },
                set: { new in
                    if let new {
                        if let i = profile.buttonActions.firstIndex(where: { $0.button == button }) {
                            profile.buttonActions[i] = new
                        } else {
                            profile.buttonActions.append(new)
                        }
                    } else {
                        profile.buttonActions.removeAll { $0.button == button }
                    }
                })
    }
}

/// One button: its action, what that does, and what the action needs.
private struct ButtonRow: View {
    let button: MouseButtonID
    @Binding var assignment: ButtonAssignment?
    @Binding var pace: Double
    /// Lit for a moment as the button is pressed.
    let lit: Bool

    private var action: Binding<ButtonAction?> {
        Binding(get: { assignment?.action },
                set: { action in
                    guard let action else { assignment = nil; return }
                    var new = assignment ?? ButtonAssignment(button: button, action: action)
                    new.action = action
                    assignment = new
                })
    }

    var body: some View {
        SettingRow(title: ButtonNames.title(button), caption: caption) {
            Picker("Action", selection: action) {
                Text("Default").tag(ButtonAction?.none)
                Divider()
                ForEach(ButtonAction.offered(for: button), id: \.self) { Text(verbatim: $0.title).tag(ButtonAction?.some($0)) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } extra: {
            extra
        }
        .background(Color.accentColor.opacity(lit ? 0.16 : 0))
        .animation(.easeOut(duration: lit ? 0.1 : 0.8), value: lit)
    }

    @ViewBuilder
    private var extra: some View {
        switch assignment?.action {
        case .shortcut:
            HStack {
                Text("Keys it presses").foregroundStyle(.secondary)
                Spacer()
                ShortcutRecorder(shortcut: Binding(get: { assignment?.shortcut ?? .none }, set: { assignment?.shortcut = $0 }), defaultValue: .none)
            }
            .font(.subheadline)
        case .openApp:
            HStack {
                Text(verbatim: assignment?.appName ?? String(localized: "No app chosen")).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { choose() }
            }
            .font(.subheadline)
        case .autoscroll:
            ValueSlider(value: $pace, range: Profile.autoscrollPaceRange, step: 0.05, low: "Slow", high: "Fast") { String(format: "%.2f×", locale: .current, $0) }
        default:
            EmptyView()
        }
    }

    /// What the button does: macOS's own until it has an action, then that.
    private var caption: LocalizedStringKey? {
        switch assignment?.action {
        case nil:
            switch button {
            case .number(2): return "A middle click, which opens a link in a new tab."
            case .number(3): return "Browsers and editors go back with it; Apple's apps ignore it."
            case .number(4): return "Browsers and editors go forward with it; Apple's apps ignore it."
            case .number: return "Sent to the app, which most ignore."
            case .control: return "What the mouse does with it on its own."
            }
        case .nothing: return "Does nothing, in every app."
        case .back: return "Goes back in every app, Apple's included."
        case .forward: return "Goes forward in every app, Apple's included."
        case .autoscroll: return "Hold it and move the mouse to scroll, faster the farther you move. A click without moving stays a middle click."
        case .floatingDock: return "Opens the Floating Dock at the pointer."
        case .missionControl, .showDesktop, .shortcut, .openApp: return nil
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assignment?.appPath = url.path
        assignment?.appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Lights a button's row as it's pressed, while the buttons are shown and the
/// toolkit is in front: a press over its windows reaches them rather than
/// doing what it's set to, and one the mouse keeps to itself reports here.
/// Off while another app is in front, so the buttons work there as set.
private final class ButtonFinder: ObservableObject {
    @Published private(set) var lit: MouseButtonID?
    /// Buttons pressed that have no row of their own yet.
    @Published private(set) var found: [MouseButtonID] = []
    private weak var mouse: MouseController?
    private var deviceID = ""
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var dim: DispatchWorkItem?

    func start(mouse: MouseController, deviceID: String) {
        guard !mouse.isPreview, observers.isEmpty else { return }
        self.mouse = mouse
        self.deviceID = deviceID
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.listen(true) },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.listen(false) },
        ]
        listen(NSApp.isActive)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        listen(false)
    }

    private func listen(_ on: Bool) {
        if on, monitor == nil {
            // Not back and forward through the settings window's history.
            SwipeNavigation.paused = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                self?.pressed(.number(event.buttonNumber))
                return nil
            }
            mouse?.identifyButtons(of: deviceID) { [weak self] key, cid in
                guard let self, key == deviceID else { return }
                pressed(.control(cid))
            }
        } else if !on, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            SwipeNavigation.paused = false
            mouse?.identifyButtons(of: deviceID, nil)
        }
    }

    private func pressed(_ button: MouseButtonID) {
        if !found.contains(button) { found.append(button) }
        lit = button
        dim?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lit = nil }
        dim = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    deinit { stop() }
}
