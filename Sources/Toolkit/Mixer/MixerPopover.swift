import SwiftUI

/// The mixer that opens from the menu bar, laid out like a Control Center
/// module: the output and main volume on top, one row per app underneath.
struct MixerPopoverView: View {
    @ObservedObject var mixer: MixerController
    var openSettings: () -> Void = {}

    static let width: CGFloat = 340
    /// Past this many rows the list scrolls instead of growing.
    private static let visibleRows = 9

    @StateObject private var showOutputs: ViewState<Bool>

    init(mixer: MixerController, showOutputs: Bool = false, openSettings: @escaping () -> Void = {}) {
        self.mixer = mixer
        self.openSettings = openSettings
        _showOutputs = StateObject(wrappedValue: ViewState(showOutputs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            outputModule

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle("Apps")
                    Spacer()
                    PillButton(title: "Reset", symbol: "arrow.counterclockwise") { mixer.resetAll() }
                        .disabled(!mixer.hasCustomVolumes)
                        .help("Put every app back to 100%, so they all follow the main volume.")
                }
                .padding(.horizontal, 4)

                if mixer.permission != .granted, mixer.needsAudioPermission {
                    PermissionNotice(denied: mixer.permission == .denied) { mixer.requestPermission() }
                }

                if mixer.apps.isEmpty {
                    EmptyState()
                } else if mixer.apps.count > Self.visibleRows {
                    ScrollView { appList }
                        .frame(height: CGFloat(Self.visibleRows) * AppRow.height)
                } else {
                    appList
                }
            }

            Divider().padding(.horizontal, 4)

            HStack(spacing: 0) {
                FooterButton(title: "Mixer Settings…", symbol: "slider.horizontal.3", action: openSettings)
                Spacer()
                FooterButton(title: "Sound Settings…", symbol: "gearshape") { mixer.openSoundSettings() }
            }
        }
        .padding(10)
        .frame(width: Self.width)
    }

    private var appList: some View {
        VStack(spacing: 0) {
            ForEach(mixer.apps) { app in
                AppRow(mixer: mixer, app: app)
            }
        }
    }

    // MARK: - Output

    private var outputModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { showOutputs.value.toggle() }
            } label: {
                HStack(spacing: 8) {
                    SectionTitle("Sound")
                    if mixer.softwareActive {
                        Image(systemName: "cpu")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .help("Software volume: this output has no volume control, so the toolkit lowers the sound itself. The volume keys work too.")
                    }
                    Spacer(minLength: 8)
                    if let device = mixer.currentOutput {
                        Image(systemName: device.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(device.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showOutputs.value ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose the output device")

            HStack(spacing: 10) {
                VolumeSlider(value: Binding(get: { Double(mixer.mainVolume) }, set: { mixer.setMainVolume(Float($0)) }),
                             muted: mixer.mainMuted, height: 22, prominent: true) { mixer.toggleMainMute() }
                PercentLabel(value: Double(mixer.mainVolume), muted: mixer.mainMuted)
            }
            .disabled(!mixer.hasMainVolume)
            .opacity(mixer.hasMainVolume ? 1 : 0.45)
            .help(mixer.hasMainVolume ? "" : "This output has no volume control.")

            if showOutputs.value {
                VStack(spacing: 2) {
                    ForEach(mixer.outputs) { device in
                        OutputRow(device: device, selected: device.id == mixer.output) {
                            mixer.setOutput(device)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(ModuleBackground())
    }
}

// MARK: - Rows

private struct AppRow: View {
    static let height: CGFloat = 30

    @ObservedObject var mixer: MixerController
    let app: MixerApp
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        let setting = mixer.volume(of: app)
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .saturation(setting.isSilent ? 0 : 1)
            .opacity(setting.isSilent ? 0.6 : 1)

            HStack(spacing: 5) {
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(setting.isSilent ? .secondary : .primary)
                if app.isPlaying, !setting.isSilent {
                    PlayingBars().help("Playing")
                }
            }
            .frame(width: 104, alignment: .leading)
            .help(app.name)

            VolumeSlider(value: Binding(get: { setting.volume }, set: { mixer.setVolume($0, of: app) }),
                         muted: setting.muted, height: 16, onBegin: { mixer.beginAdjusting(app) }) { mixer.toggleMute(app) }
            PercentLabel(value: setting.volume, muted: setting.isSilent)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering.value ? 0.06 : 0)))
        .onHover { hovering.value = $0 }
        // A click anywhere on the row but the slider mutes or unmutes; the
        // slider's own drag gesture wins over this one.
        .contentShape(Rectangle())
        .onTapGesture { mixer.toggleMute(app) }
        .help(setting.isSilent ? "Click to unmute \(app.name)" : "Click to mute \(app.name)")
        .contextMenu {
            Button(setting.isSilent ? "Unmute" : "Mute") { mixer.toggleMute(app) }
            Button("Reset to 100%") { mixer.forget(app.bundleID) }
                .disabled(setting.isDefault)
            Divider()
            Button("Hide Until It Plays Again") { mixer.hide(app) }
                .disabled(app.isPlaying)
            Button("Never Touch \(app.name)") { mixer.ignore(bundleID: app.bundleID, name: app.name) }
        }
    }
}

private struct OutputRow: View {
    let device: OutputDevice
    let selected: Bool
    let action: () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.1)))
                Text(device.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering.value ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
    }
}

// MARK: - Controls

/// A thick Control Center style slider. The speaker at its start mutes.
/// The main volume is filled with the accent colour; app volumes are filled
/// in a neutral tone so a list of them doesn't turn into a wall of colour.
private struct VolumeSlider: View {
    @Binding var value: Double
    let muted: Bool
    let height: CGFloat
    var prominent = false
    var onBegin: () -> Void = {}
    let toggleMute: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var fillStyle: AnyShapeStyle {
        if muted { return AnyShapeStyle(Color.secondary.opacity(0.35)) }
        if prominent { return AnyShapeStyle(Color.accentColor.gradient) }
        return AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.7 : 0.4))
    }

    private var symbolColor: Color {
        if muted { return .secondary }
        return prominent || colorScheme == .light ? .white : Color(nsColor: .windowBackgroundColor)
    }

    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var dragging = ViewState(false)

    private var symbol: String {
        if muted || value == 0 { return "speaker.slash.fill" }
        return value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        GeometryReader { geo in
            let span = max(1, geo.size.width - height)
            let fill = height + span * (muted ? 0 : value)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(fillStyle)
                    .frame(width: fill)
                    .shadow(color: .black.opacity(muted ? 0 : 0.12), radius: 1, y: 0.5)
                Image(systemName: symbol)
                    .font(.system(size: height * 0.42, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: height, height: height)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // A press on the speaker is a mute toggle, not a drag.
                        if !dragging.value, drag.startLocation.x < height, abs(drag.translation.width) < 3 { return }
                        if !dragging.value { onBegin() }
                        dragging.value = true
                        value = min(1, max(0, (drag.location.x - height / 2) / span))
                    }
                    .onEnded { drag in
                        if !dragging.value, drag.startLocation.x < height { toggleMute() }
                        dragging.value = false
                    }
            )
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.12), value: muted)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(muted ? "Muted" : "\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
        .help(muted ? "Click the speaker to unmute" : "Click the speaker to mute")
    }
}

/// Three bars bouncing, shown next to an app that is playing.
private struct PlayingBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 3 + 6 * abs(sin(t * (5 + Double(i) * 1.7) + Double(i))))
                }
            }
            .frame(height: 9, alignment: .bottom)
        }
    }
}

private struct PercentLabel: View {
    let value: Double
    var muted = false

    var body: some View {
        Group {
            if muted {
                Text("Muted")
            } else {
                Text("\(Int((value * 100).rounded()))%")
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 38, alignment: .trailing)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
    }
}

private struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(hovering.value && isEnabled ? 0.12 : 0.07)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .opacity(isEnabled ? 1 : 0.6)
        .onHover { hovering.value = $0 }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering.value ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering.value ? .primary : .secondary)
        .onHover { hovering.value = $0 }
    }
}

private struct ModuleBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.zzz")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No app has sound open.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private struct PermissionNotice: View {
    let denied: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(denied
                     ? "System Audio Recording is off for MacOS Toolkit, so volume changes have no effect."
                     : "Volume changes need the System Audio Recording permission.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Button(denied ? "Open System Settings…" : "Allow…", action: action)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}
