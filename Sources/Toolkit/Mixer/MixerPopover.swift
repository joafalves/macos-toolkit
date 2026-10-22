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
    @StateObject private var showEqualizer: ViewState<Bool>

    init(mixer: MixerController, showOutputs: Bool = false, showEqualizer: Bool = false, openSettings: @escaping () -> Void = {}) {
        self.mixer = mixer
        self.openSettings = openSettings
        _showOutputs = StateObject(wrappedValue: ViewState(showOutputs))
        _showEqualizer = StateObject(wrappedValue: ViewState(showEqualizer))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            outputModule
            EqualizerModule(mixer: mixer, expanded: showEqualizer)

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
                // No SwiftUI animation: the popover resizes to fit on every frame of one,
                // which redraws the whole panel. NSPopover animates the size change itself.
                showOutputs.value.toggle()
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
            }
        }
        .padding(10)
        .background(ModuleBackground())
    }
}

// MARK: - Equalizer

private struct EqualizerModule: View {
    @ObservedObject var mixer: MixerController
    @ObservedObject var expanded: ViewState<Bool>

    private var eq: EqualizerConfig { mixer.config.equalizer }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    expanded.value.toggle()
                } label: {
                    HStack(spacing: 8) {
                        SectionTitle("Equalizer")
                        Spacer(minLength: 8)
                        Text(eq.enabled ? eq.presetName : "Off")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded.value ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the bands and presets")

                Toggle("Equalizer", isOn: Binding(get: { eq.enabled }, set: { mixer.setEqualizerEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("While it's on and not flat, all sound goes through the toolkit to be equalized.")
            }

            if expanded.value {
                VStack(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0..<EqualizerConfig.frequencies.count, id: \.self) { band in
                            BandColumn(gain: eq.gains[band], label: EqualizerConfig.labels[band], dimmed: !eq.enabled) {
                                mixer.setBand(band, gain: $0)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(EqualizerPreset.all) { preset in
                                Button {
                                    mixer.applyPreset(preset)
                                } label: {
                                    if eq.enabled, preset.gains == eq.gains {
                                        Label(preset.name, systemImage: "checkmark")
                                    } else {
                                        Text(preset.name)
                                    }
                                }
                            }
                        } label: {
                            Label("Presets", systemImage: "slider.vertical.3")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                        PillButton(title: "Flat", symbol: "arrow.counterclockwise") {
                            if let flat = EqualizerPreset.all.first { mixer.applyPreset(flat) }
                        }
                        .disabled(eq.isFlat)
                        .help("Put every band back to 0 dB")
                    }
                }
            }
        }
        .padding(10)
        .background(ModuleBackground())
    }
}

/// One band: its gain on top, a vertical slider from -12 to +12 dB, the frequency below.
private struct BandColumn: View {
    let gain: Double
    let label: String
    let dimmed: Bool
    let change: (Double) -> Void

    private static let height: CGFloat = 76
    private static let width: CGFloat = 16

    var body: some View {
        VStack(spacing: 4) {
            Text(gain == 0 ? "0" : String(format: "%+.1f", gain).replacingOccurrences(of: ".0", with: ""))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(gain == 0 ? .tertiary : .secondary)
            GeometryReader { geo in
                let range = EqualizerConfig.range
                let mid = geo.size.height / 2
                let y = mid - CGFloat(gain / range) * mid
                ZStack(alignment: .top) {
                    // The fill runs from 0 dB in the middle to the gain, inside the track.
                    ZStack(alignment: .top) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(height: 1)
                            .offset(y: mid)
                        Rectangle()
                            .fill(dimmed ? AnyShapeStyle(Color.secondary.opacity(0.5)) : AnyShapeStyle(Color.accentColor.gradient))
                            .frame(height: abs(y - mid))
                            .offset(y: min(y, mid))
                    }
                    .clipShape(Capsule())
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .frame(width: Self.width - 2, height: Self.width - 2)
                        .offset(y: min(max(0, y - (Self.width - 2) / 2), geo.size.height - (Self.width - 2)))
                }
                .frame(width: Self.width)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let value = (mid - drag.location.y) / mid * range
                    change(min(range, max(-range, value)))
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { change(0) })
            }
            .frame(height: Self.height)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .opacity(dimmed ? 0.6 : 1)
        .help("\(label) Hz. Drag to boost or cut; double-click for 0 dB.")
        .accessibilityElement()
        .accessibilityLabel("\(label) hertz")
        .accessibilityValue("\(gain) decibels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(gain + 1)
            case .decrement: change(gain - 1)
            @unknown default: break
            }
        }
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
            Button("Exclude \(app.name)") { mixer.ignore(bundleID: app.bundleID, name: app.name) }
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

/// Three bars bouncing, shown next to an app that is playing. Core Animation
/// moves them, outside the app: drawn by SwiftUI each frame, a few rows of
/// them kept the toolkit at about 10% of a core while the mixer was open.
private struct PlayingBars: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayingBarsView { PlayingBarsView() }
    func updateNSView(_ view: PlayingBarsView, context: Context) {}
    // Its own size, not the row's height: the bars stand on the view's bottom.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayingBarsView, context: Context) -> CGSize? { PlayingBarsView.size }
}

private final class PlayingBarsView: NSView {
    private static let width: CGFloat = 2, gap: CGFloat = 1.5, low: CGFloat = 3, high: CGFloat = 9
    static let size = CGSize(width: width * 3 + gap * 2, height: high)
    /// Seconds from low to high for each bar, so they don't move together.
    private static let periods: [CFTimeInterval] = [0.63, 0.47, 0.37]
    /// Where each bar stands when nothing moves it (snapshots, Reduce Motion).
    private static let resting: [CGFloat] = [6, 9, 4]
    private var bars: [CALayer] = []

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        for index in 0..<3 {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = Self.width / 2
            bar.frame = CGRect(x: CGFloat(index) * (Self.width + Self.gap), y: 0, width: Self.width, height: Self.resting[index])
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { Self.size }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color = NSColor.controlAccentColor.cgColor
        bars.forEach { $0.backgroundColor = color }
    }

    // Animations go with the layer tree a view leaves, so they're added each
    // time it's put in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bars.forEach { $0.removeAllAnimations() }
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (index, bar) in bars.enumerated() {
            let bounce = CABasicAnimation(keyPath: "bounds.size.height")
            bounce.fromValue = Self.low
            bounce.toValue = Self.high
            bounce.duration = Self.periods[index]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.timeOffset = Self.periods[index] * Double(index) / 3
            bounce.isRemovedOnCompletion = false
            bar.add(bounce, forKey: "bounce")
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
