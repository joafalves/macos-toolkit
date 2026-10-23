import SwiftUI

/// The panel Keep Awake's part of the menu bar opens, laid out like the
/// mixer's: the session on top with its switch, then the lengths to start
/// one for, an end time to pick, and the two settings changed most often.
/// A length picked while it's on counts from now.
struct AwakePanelView: View {
    @ObservedObject var awake: AwakeController
    var openSettings: () -> Void = {}

    /// The end time offered: on the quarter hour, an hour or so from now.
    @StateObject private var until = ViewState(AwakePanelView.soon())
    @StateObject private var hoveringHeader = ViewState(false)

    /// One click away; the rest are under More.
    static let quick = [15 * 60, 30 * 60, 3600, 2 * 3600, 4 * 3600, 8 * 3600]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            session
            lengths
            options
            Divider().padding(.horizontal, 4)
            PanelFooter(openSettings: openSettings)
                .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(width: 300)
    }

    // MARK: - Session

    private var session: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                // The whole header turns it on or off, not only the switch.
                Button(action: flip) {
                    HStack(spacing: 10) {
                        IconTile(symbol: awake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer",
                                 color: awake.isOn ? AppSection.awake.color : .gray, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AppSection.awake.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(awake.status)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
                Toggle(AppSection.awake.title, isOn: Binding(get: { awake.isOn }, set: { $0 ? awake.turnOn(for: nil) : awake.turnOff() }))
                    .toggleStyle(PanelSwitch())
                    .labelsHidden()
            }
            .disabled(!awake.isOn && awake.batteryLow)
            .help("Turns it on with no end, or off again.")
            .padding(6)
            .background(Color.primary.opacity(hoveringHeader.value && !(awake.batteryLow && !awake.isOn) ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { hoveringHeader.value = $0 }
            .padding(-6)
            if awake.isOn, let session = awake.session, session.until != nil {
                // What's left of it, as the pill in the menu bar shows.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(AppSection.awake.color)
                            .frame(width: max(4, geo.size.width * session.fractionLeft()))
                    }
                }
                .frame(height: 4)
            }
            if awake.batteryLow, !awake.isOn {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Battery below \(awake.config.batteryFloor)%")
                        Text("Charge it, or lower the stop level.").foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "battery.25percent").foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(ModuleBackground())
        // Ticks with the minutes left, and the bar with them.
        .id(awake.minute)
    }

    // MARK: - Lengths

    private var lengths: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep awake for")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Self.quick, id: \.self) { seconds in
                    Chip(title: Self.short(seconds), selected: running == seconds) {
                        awake.turnOn(for: TimeInterval(seconds))
                    }
                }
            }
            HStack(spacing: 6) {
                Menu {
                    Section("Minutes") {
                        ForEach(AwakeController.minutes, id: \.self) { minutes in
                            Button(AwakeController.title(minutes: minutes)) { awake.turnOn(for: TimeInterval(minutes * 60)) }
                        }
                    }
                    Section("Hours") {
                        ForEach(AwakeController.hours, id: \.self) { hours in
                            Button(AwakeController.title(hours: hours)) { awake.turnOn(for: TimeInterval(hours * 3600)) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("More")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .chipLabel(selected: false)
                }
                // Drawn as the label is, like the lengths beside it.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                untilRow
            }
        }
        .disabled(awake.batteryLow)
    }

    /// Until a time, set with − and +: a text field in a panel that doesn't
    /// take the keyboard can't be typed in.
    private var untilRow: some View {
        HStack(spacing: 4) {
            Text("Until")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            StepButton(symbol: "minus", label: "Earlier") { step(-1) }
            Text(until.value.formatted(date: .omitted, time: .shortened))
                .monospacedDigit()
                .frame(minWidth: 44)
            StepButton(symbol: "plus", label: "Later") { step(1) }
            Spacer(minLength: 4)
            Button("Start") {
                // Today, or tomorrow if the time has passed by now.
                let parts = Calendar.current.dateComponents([.hour, .minute], from: until.value)
                if let next = Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime) {
                    awake.turnOn(until: next)
                }
            }
            .buttonStyle(.plain)
            .chipLabel(selected: false)
            .fixedSize()
            .help("Today, or tomorrow if the time has passed.")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func flip() {
        awake.isOn ? awake.turnOff() : awake.turnOn(for: nil)
    }

    private func step(_ quarters: Int) {
        until.value = until.value.addingTimeInterval(TimeInterval(quarters) * 900)
    }

    /// The quick length a timed session was started with, to show which.
    private var running: Int? {
        guard awake.isOn, let session = awake.session, let end = session.until else { return nil }
        return Int(end.timeIntervalSince(session.started).rounded())
    }

    static func short(_ seconds: Int) -> String {
        seconds < 3600 ? String(localized: "\(seconds / 60) min") : String(localized: "\(seconds / 3600) h")
    }

    static func soon() -> Date {
        let soon = Date().addingTimeInterval(3600)
        let hour = Calendar.current.dateInterval(of: .hour, for: soon)?.start ?? soon
        return hour.addingTimeInterval((soon.timeIntervalSince(hour) / 900).rounded(.up) * 900)
    }

    // MARK: - Options

    private var options: some View {
        VStack(spacing: 0) {
            OptionSwitch(title: "Keep the display on",
                         caption: awake.config.stayAvailable ? "On while Stay available is on" : nil,
                         isOn: $awake.config.keepDisplayOn)
                // Held on by Stay available, as on the settings page.
                .disabled(awake.config.stayAvailable)
            OptionSwitch(title: "Stay available",
                         caption: awake.config.stayAvailable && !awake.accessibility ? "Needs Accessibility" : "Your status stays available",
                         isOn: Binding(get: { awake.config.stayAvailable }, set: { on in
                             awake.config.stayAvailable = on
                             // Without Accessibility its events are dropped: the settings page says so.
                             if on, !awake.accessibility { openSettings() }
                         }))
        }
    }
}

// MARK: - Parts

/// A length to start a session for.
private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .chipLabel(selected: selected)
        }
        .buttonStyle(.plain)
    }
}

private struct ChipLabel: ViewModifier {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hovering = ViewState(false)

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(selected ? Color.white : isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(AppSection.awake.color) : AnyShapeStyle(Color.primary.opacity(hovering.value && isEnabled ? 0.12 : 0.07)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering.value = $0 }
    }
}

private extension View {
    func chipLabel(selected: Bool) -> some View { modifier(ChipLabel(selected: selected)) }
}

private struct StepButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A setting with its switch, as the toolkit panel's tool rows.
private struct OptionSwitch: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(isEnabled ? 1 : 0.6)
            Spacer(minLength: 6)
            Toggle(title, isOn: $isOn)
                .toggleStyle(PanelSwitch())
                .labelsHidden()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}
