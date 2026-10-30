import SwiftUI

/// The mixer that opens from the menu bar, laid out like a Control Center
/// module: the output and main volume on top, one row per app underneath.
struct MixerPopoverView: View {
    @ObservedObject var mixer: MixerController
    var close: () -> Void = {}
    var openSettings: () -> Void = {}

    static let width: CGFloat = 340
    /// Past this many rows the list scrolls instead of growing.
    private static let visibleRows = 9

    @StateObject private var showOutputs: ViewState<Bool>
    @StateObject private var showEqualizer: ViewState<Bool>
    /// The panel's equalizer is always the output in use's.
    @StateObject private var noTarget = ViewState<String?>(nil)

    init(mixer: MixerController, showOutputs: Bool = false, showEqualizer: Bool = false,
         close: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}) {
        self.mixer = mixer
        self.close = close
        self.openSettings = openSettings
        _showOutputs = StateObject(wrappedValue: ViewState(showOutputs))
        _showEqualizer = StateObject(wrappedValue: ViewState(showEqualizer))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MixerSoundControls(mixer: mixer, place: .panel, showOutputs: showOutputs)
                .padding(10)
                .background(ModuleBackground())
            MixerEqualizerControls(mixer: mixer, place: .panel, expanded: showEqualizer, target: noTarget)
                .padding(10)
                .background(ModuleBackground())

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle("Apps")
                    Spacer()
                    ResetAppsButton(mixer: mixer)
                }
                .padding(.horizontal, 4)

                if mixer.driverBlocked {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("The audio driver needs updating. The mixer is off until it is, and sound plays as usual.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Update…") { mixer.setUsesDriver(true) }
                            .disabled(mixer.driverBusy)
                    }
                    .font(.callout)
                    .padding(.horizontal, 4)
                } else if mixer.permission != .granted, !mixer.driverActive {
                    PermissionNotice(denied: mixer.permission == .denied) { mixer.requestPermission() }
                }

                MixerAppList(mixer: mixer, place: .panel)
            }

            Divider().padding(.horizontal, 4)

            // By its full name: in some languages its own is the same word as
            // the toolkit's Settings beside it ("Definições").
            PanelFooter(app: String(localized: "System Settings"), openApp: {
                close()
                mixer.openSoundSettings()
            }, openSettings: openSettings)
            .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(width: Self.width)
    }
}

/// Where the mixer's controls are: its menu bar panel, narrow and quick,
/// or its page in the settings, where everything is laid out at once. The
/// same views, on the same controller, so a change in one shows in the other.
enum MixerPlace { case panel, page }

// MARK: - Sound

/// The main volume and the output. In the panel the outputs fold away
/// under a header with the one in use; the page lists them all.
struct MixerSoundControls: View {
    @ObservedObject var mixer: MixerController
    let place: MixerPlace
    @ObservedObject var showOutputs: ViewState<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if place == .panel { header }

            HStack(spacing: 10) {
                VolumeSlider(value: Binding(get: { Double(mixer.mainVolume) }, set: { mixer.setMainVolume(Float($0)) }),
                             muted: mixer.mainMuted, height: 22, prominent: true) { mixer.toggleMainMute() }
                PercentLabel(value: Double(mixer.mainVolume), muted: mixer.mainMuted)
            }
            .disabled(!mixer.hasMainVolume)
            .opacity(mixer.hasMainVolume ? 1 : 0.45)
            .help(mixer.hasMainVolume ? "" : "This output has no volume control.")

            if place == .page, mixer.softwareActive {
                Text("Software volume: this output has no volume control, so the toolkit lowers the sound itself. The volume keys work too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if place == .page || showOutputs.value {
                if place == .page { Divider().padding(.vertical, 2) }
                VStack(spacing: 2) {
                    ForEach(mixer.outputs) { device in
                        OutputRow(device: device, selected: device.id == mixer.output) {
                            mixer.setOutput(device)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
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
    }
}

// MARK: - Apps

/// A row per app. The panel stops growing past a few rows and scrolls; the
/// page shows them all, with more room for their names.
struct MixerAppList: View {
    @ObservedObject var mixer: MixerController
    let place: MixerPlace
    /// Past this many rows the panel's list scrolls instead of growing.
    private static let visibleRows = 9

    var body: some View {
        if mixer.apps.isEmpty {
            EmptyState()
        } else if place == .panel, mixer.apps.count > Self.visibleRows {
            ScrollView { rows }
                .frame(height: CGFloat(Self.visibleRows) * AppRow.height)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(mixer.apps) { app in
                AppRow(mixer: mixer, app: app, nameWidth: place == .panel ? 104 : 200)
            }
        }
    }
}

/// Every app back to 100%.
struct ResetAppsButton: View {
    @ObservedObject var mixer: MixerController

    var body: some View {
        PillButton(title: "Reset", symbol: "arrow.counterclockwise") { mixer.resetAll() }
            .disabled(!mixer.hasCustomVolumes)
            .help("Put every app back to 100%, so they all follow the main volume.")
    }
}

// MARK: - Equalizer

/// The equalizer. In the panel its bands fold away under a header with the
/// preset in use; the page always shows them.
struct MixerEqualizerControls: View {
    @ObservedObject var mixer: MixerController
    let place: MixerPlace
    @ObservedObject var expanded: ViewState<Bool>
    /// With an equalizer for each output, the one set here, by UID: on the
    /// page any output's, nil for the one in use. The panel's is always nil.
    @ObservedObject var target: ViewState<String?>

    private var eq: EqualizerConfig { mixer.equalizer(for: output) }
    private var output: String? { place == .page ? target.value : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if place == .page {
                HStack(spacing: 8) {
                    if mixer.config.equalizerPerOutput { outputPicker }
                    Text(eq.enabled ? eq.presetName : String(localized: "Off"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Toggle("Equalizer", isOn: Binding(get: { eq.enabled }, set: { mixer.setEqualizerEnabled($0, for: output) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(mixer.config.equalizerPerOutput ? "On or off for this output. Each output keeps its own equalizer." : "On or off for every output.")
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        expanded.value.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            SectionTitle("Equalizer")
                            Spacer(minLength: 8)
                            Text(eq.enabled ? eq.presetName : String(localized: "Off"))
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
                        .toggleStyle(PanelSwitch())
                        .labelsHidden()
                        .help(mixer.config.equalizerPerOutput ? "On or off for this output. Each output keeps its own equalizer." : "On or off for every output.")
                }
            }

            if place == .page || expanded.value {
                VStack(spacing: 8) {
                    if place == .panel, mixer.config.equalizerPerOutput, let output = mixer.currentOutput {
                        Text("For \(output.name)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if mixer.config.equalizerMode == .simple {
                        simpleRows
                    } else {
                        // Lined up at the top: a name that takes two lines ("Pré-amplificador") only grows down.
                        HStack(alignment: .top, spacing: 0) {
                            // The panel has no room for a value over every band: a scale
                            // beside them instead, as the Music app's equalizer has, and
                            // each band's value in its tooltip.
                            if place == .panel {
                                DecibelScale(height: BandColumn.sliderHeight(place))
                                    .padding(.top, BandColumn.valueHeight(place))
                            }
                            // The volume of everything, apart from the bands, as in the Music app.
                            BandColumn(place: place, gain: eq.preamp, label: String(localized: "Preamp"), dimmed: !eq.enabled,
                                       help: String(localized: "The volume of everything. Lower it if boosts make loud music sound squashed; double-click for 0 dB."),
                                       accessibilityName: String(localized: "Preamp")) { value, _ in
                                mixer.setPreamp(value, for: output)
                            }
                            .frame(width: place == .panel ? 48 : 66)
                            Divider()
                                .frame(height: BandColumn.valueHeight(place) + BandColumn.sliderHeight(place) + 20)
                                .padding(.horizontal, 2)
                            ForEach(0..<EqualizerConfig.frequencies.count, id: \.self) { band in
                                let label = EqualizerConfig.labels[band]
                                BandColumn(place: place, gain: eq.gains[band], label: label, dimmed: !eq.enabled,
                                           help: String(localized: "\(label) Hz. Drag to boost or cut; with ⌥, the bands beside it follow. Double-click for 0 dB."),
                                           accessibilityName: String(localized: "\(label) hertz"),
                                           begin: { mixer.beginBandDrag(for: output) }) { value, linked in
                                    mixer.setBand(band, gain: value, linked: linked, for: output)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    if place == .page {
                        Group {
                            if mixer.config.equalizerMode == .bands {
                                Text("Hold ⌥ while dragging a band to move the bands beside it too.")
                            } else if !EqualizerRegion.fit(eq.gains) {
                                Text("This curve has more detail than three sliders show; 10 Bands shows it.")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(EqualizerPreset.all) { preset in
                                Button {
                                    mixer.applyPreset(preset, for: output)
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
                        // How it's edited, for every output; the panel follows.
                        if place == .page {
                            Picker("Equalizer mode", selection: $mixer.config.equalizerMode) {
                                Text("Simple").tag(EqualizerMode.simple)
                                Text("10 Bands").tag(EqualizerMode.bands)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help("Simple: bass, mid and treble, handles on the same ten bands. A preset sounds the same in both.")
                        }
                        PillButton(title: "Flat", symbol: "arrow.counterclockwise") {
                            if let flat = EqualizerPreset.all.first { mixer.applyPreset(flat, for: output) }
                        }
                        .disabled(eq.isFlat)
                        .help("Put every band back to 0 dB")
                    }
                }
            }
        }
    }
}

extension MixerEqualizerControls {
    /// Simple's tone controls, a row each as tone controls are laid out: the
    /// preamp, then Bass, Mid and Treble, each moving a region of the bands.
    var simpleRows: some View {
        VStack(spacing: place == .page ? 10 : 6) {
            ToneRow(place: place, label: String(localized: "Preamp"), gain: eq.preamp, dimmed: !eq.enabled,
                    help: String(localized: "The volume of everything. Lower it if boosts make loud music sound squashed; double-click for 0 dB.")) {
                mixer.setPreamp($0, for: output)
            }
            Divider()
            ForEach(EqualizerRegion.allCases) { region in
                ToneRow(place: place, label: region.title, gain: region.level(eq.gains), dimmed: !eq.enabled, help: region.help) {
                    mixer.setRegion(region, to: $0, for: output)
                }
            }
        }
    }

    /// Which output's equalizer the page sets: the one in use to start with.
    var outputPicker: some View {
        Picker("Output", selection: Binding(get: { target.value ?? mixer.currentOutput?.uid ?? "" }, set: { target.value = $0 })) {
            ForEach(mixer.outputs) { device in
                Text(device.id == mixer.output ? String(localized: "\(device.name) (in use)") : device.name).tag(device.uid)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("The output whose equalizer this is. Each keeps its own; the one in use is what you hear.")
    }
}

/// One band, or the preamp: macOS's own vertical slider from -12 to +12 dB,
/// as the Music app's equalizer has, with its name below. The page shows
/// its value on top; the panel, short of room, in its tooltip.
struct BandColumn: View {
    let place: MixerPlace
    let gain: Double
    let label: String
    let dimmed: Bool
    let help: String
    let accessibilityName: String
    var begin: () -> Void = {}
    /// The value, and whether ⌥ was held.
    let change: (Double, Bool) -> Void

    static func sliderHeight(_ place: MixerPlace) -> CGFloat { place == .panel ? 84 : 120 }
    static func valueHeight(_ place: MixerPlace) -> CGFloat { place == .panel ? 0 : 17 }

    private var value: String { Self.text(gain) }

    static func text(_ gain: Double) -> String {
        gain == 0 ? "0" : gain == gain.rounded() ? String(format: "%+d", Int(gain)) : String(format: "%+.1f", locale: .current, gain)
    }

    var body: some View {
        VStack(spacing: 4) {
            if place == .page {
                Text(verbatim: value)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(gain == 0 ? .tertiary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: Self.valueHeight(place) - 4)
            }
            EqualizerSlider(value: gain, small: place == .panel, accessibilityName: accessibilityName, begin: begin, change: change)
                .frame(height: Self.sliderHeight(place))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                // A long name ("Pré-amplificador") a little smaller in the panel, not cut.
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(dimmed ? 0.55 : 1)
        .help(place == .panel ? "\(help) \(value) dB." : help)
    }
}

/// One of Simple's rows: its name, macOS's horizontal slider from -12 to
/// +12 dB with a tick at 0, and its value.
private struct ToneRow: View {
    let place: MixerPlace
    let label: String
    let gain: Double
    let dimmed: Bool
    let help: String
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(place == .page ? .body : .system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: place == .page ? 120 : 76, alignment: .leading)
            EqualizerSlider(value: gain, vertical: false, small: place == .panel, accessibilityName: label) { value, _ in change(value) }
            Text(verbatim: "\(BandColumn.text(gain)) dB")
                .font((place == .page ? Font.callout : .system(size: 11, weight: .medium)).monospacedDigit())
                .foregroundStyle(gain == 0 ? .tertiary : .secondary)
                .lineLimit(1)
                .frame(width: place == .page ? 60 : 50, alignment: .trailing)
        }
        .opacity(dimmed ? 0.55 : 1)
        .help(help)
    }
}

/// +12, 0 and -12 dB beside the panel's bands, level with the sliders'
/// top, middle and bottom.
private struct DecibelScale: View {
    let height: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: "+12")
            Spacer(minLength: 0)
            Text(verbatim: "0")
            Spacer(minLength: 0)
            Text(verbatim: "\u{2212}12")
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .foregroundStyle(.tertiary)
        // The knob's centre doesn't reach the track's ends.
        .padding(.vertical, 2)
        .frame(width: 22, height: height, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// macOS's vertical slider, with a tick at 0 dB. A double-click puts it
/// back to 0. While it's dragged it isn't moved from outside, except by a
/// change bigger than the half dB the mixer rounds it to.
private struct EqualizerSlider: NSViewRepresentable {
    let value: Double
    var vertical = true
    var small = false
    let accessibilityName: String
    var begin: () -> Void = {}
    let change: (Double, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ResettingSlider {
        let range = EqualizerConfig.range
        let slider = ResettingSlider(value: value, minValue: -range, maxValue: range,
                                     target: context.coordinator, action: #selector(Coordinator.moved(_:)))
        slider.isVertical = vertical
        slider.isContinuous = true
        // -12, 0 and +12: the middle one marks 0 dB.
        slider.numberOfTickMarks = 3
        slider.allowsTickMarkValuesOnly = false
        slider.controlSize = small ? .small : .regular
        slider.setAccessibilityLabel(accessibilityName)
        return slider
    }

    func updateNSView(_ slider: ResettingSlider, context: Context) {
        context.coordinator.change = change
        slider.onBegin = begin
        if abs(slider.doubleValue - value) > 0.26 || (!slider.isTracking && slider.doubleValue != value) {
            slider.doubleValue = value
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResettingSlider, context: Context) -> CGSize? {
        vertical ? CGSize(width: nsView.intrinsicContentSize.width, height: proposal.height ?? 84)
            : CGSize(width: proposal.width ?? 160, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var change: (Double, Bool) -> Void = { _, _ in }
        @objc func moved(_ slider: ResettingSlider) {
            // A double-click resets the one band, ⌥ or not.
            // Only a drag links them: ⌥ with an arrow key has no drag to follow from.
            change(slider.doubleValue, slider.isTracking && !slider.isResetting && NSEvent.modifierFlags.contains(.option))
        }
    }
}

private final class ResettingSlider: NSSlider {
    private(set) var isTracking = false
    private(set) var isResetting = false
    var onBegin: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            isResetting = true
            doubleValue = 0
            sendAction(action, to: target)
            isResetting = false
            return
        }
        onBegin()
        isTracking = true
        // Returns once the drag is over.
        super.mouseDown(with: event)
        isTracking = false
    }
}

// MARK: - Rows

struct AppRow: View {
    static let height: CGFloat = 30

    @ObservedObject var mixer: MixerController
    let app: MixerApp
    var nameWidth: CGFloat = 104
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
            .frame(width: nameWidth, alignment: .leading)
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
        // Every row's slider the same length: a longer word for Muted in
        // another language shrinks to the column rather than wrapping.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: 38, alignment: .trailing)
    }
}

private struct SectionTitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
    }
}

private struct PillButton: View {
    let title: LocalizedStringKey
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

/// The rounded card behind a panel's module, as in Control Center.
struct ModuleBackground: View {
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
                     ? "System Audio Recording is turned off for MacOS Toolkit, so the mixer can't change the sound."
                     : "The mixer needs the System Audio Recording permission.")
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
