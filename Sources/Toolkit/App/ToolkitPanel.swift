import AppKit
import SwiftUI

/// What the toolkit panel's buttons do, given by whoever shows it.
struct ToolkitPanelActions {
    var open: (AppSection) -> Void = { _ in }
    var openCapture: () -> Void = {}
    var stopRecording: () -> Void = {}
    var openMixer: () -> Void = {}
    /// Keep Awake's own panel, for its lengths.
    var openAwake: () -> Void = {}
    /// The Mouse and Window Layout panels, as their own parts open them.
    var openMouse: () -> Void = {}
    var openLayout: () -> Void = {}
}

/// The panel the toolkit's mark opens: up top, the tools that have no part
/// of their own in the menu bar, to use at once; then every tool, with a
/// switch to turn it on or off, which leaves the panel open, and its name to
/// open its settings; then Quit, About and Settings.
struct ToolkitPanelView: View {
    @ObservedObject var mouse: MouseController
    @ObservedObject var switcher: SwitcherController
    @ObservedObject var layout: LayoutController
    @ObservedObject var mixer: MixerController
    @ObservedObject var finder: FinderController
    @ObservedObject var capture: CaptureController
    @ObservedObject var awake: AwakeController
    @ObservedObject var stats: StatsController
    @ObservedObject var updater = Updater.shared
    var actions = ToolkitPanelActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // What's in it, and the install, are on About.
            if let release = updater.available {
                Button { actions.open(.about) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Version \(release.version) is available").font(.callout.weight(.medium))
                            Text("See what's new and install").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
            let modules = self.modules
            if !modules.isEmpty {
                // Icons only, in one row: the name and how it is are in the
                // tooltip, so many fit.
                HStack(spacing: 10) {
                    ForEach(modules) { ModuleTile(module: $0) }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Tools")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(AppSection.tools.filter { isOn($0).wrappedValue }.count) of \(AppSection.tools.count) on")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(AppSection.tools) { section in
                    ToolRow(section: section, on: isOn(section)) { actions.open(section) }
                }
            }
            Divider().padding(.top, 10).padding(.bottom, 8)
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    /// As the other panels' footers: what leaves on the left, the settings
    /// under the toolkit's mark on the right, with About beside them, drawn
    /// the same way. Overview is in the settings window's sidebar.
    private var footer: some View {
        HStack {
            Button("Quit") { NSApp.terminate(nil) }
            Spacer()
            Button { actions.open(.about) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 12.5))
                    Text("About")
                }
            }
            .padding(.trailing, 12)
            Button { actions.open(.general) } label: {
                HStack(spacing: 5) {
                    Image(nsImage: MenuBarArt.toolkit).resizable().frame(width: 12, height: 13.5)
                    Text("Settings…")
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 6)
    }

    // MARK: - Tools

    private func isOn(_ section: AppSection) -> Binding<Bool> {
        switch section {
        case .mouse: return $mouse.config.enabled
        case .switcher: return $switcher.config.enabled
        case .layout: return $layout.config.enabled
        case .mixer: return $mixer.config.enabled
        case .finder: return $finder.config.enabled
        case .capture: return $capture.config.enabled
        case .awake: return $awake.config.enabled
        case .stats: return $stats.config.enabled
        case .welcome, .general, .about: return .constant(true)
        }
    }

    // MARK: - Modules

    /// As in the toolkit's menu before: only for a tool that's on and has no
    /// part of its own in the menu bar, and the recording while there is one.
    private var modules: [Module] {
        var modules: [Module] = []
        if capture.recording != nil {
            modules.append(Module(id: "recording", symbol: "stop.fill", title: String(localized: "Stop Recording"), detail: capture.recording.map { MenuBarArt.duration($0.elapsed) },
                                  tint: .red, lit: true, action: actions.stopRecording))
        } else if capture.config.enabled, !capture.config.standaloneIcon {
            modules.append(Module(id: "capture", symbol: AppSection.capture.symbol, title: AppSection.capture.title, detail: capture.config.toolbarShortcut.active?.display,
                                  tint: AppSection.capture.color, lit: false, action: actions.openCapture))
        }
        if mixer.config.enabled, mixer.config.menuBarIcon == .none {
            let detail = mixer.mainMuted ? String(localized: "Muted") : "\(Int((mixer.mainVolume * 100).rounded()))%"
            modules.append(Module(id: "mixer", symbol: AppSection.mixer.symbol, title: AppSection.mixer.title, detail: detail,
                                  tint: AppSection.mixer.color, lit: false, action: actions.openMixer))
        }
        if awake.config.enabled, awake.config.menuBarIcon == .none {
            // The circle turns it on until turned off, or off; the rest opens
            // its menu, for the durations.
            modules.append(Module(id: "awake", symbol: awake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer", title: AppSection.awake.title, detail: awakeDetail,
                                  tint: AppSection.awake.color, lit: awake.isOn,
                                  action: { [awake] in awake.isOn ? awake.turnOff() : awake.turnOn(for: nil) },
                                  more: actions.openAwake))
        }
        if mouse.config.enabled, !mouse.config.menuBarIcon {
            // The lowest charge, the one to keep an eye on.
            let levels = mouse.devices.filter(\.connected).compactMap { mouse.battery(for: $0) }
            modules.append(Module(id: "mouse", symbol: AppSection.mouse.symbol, title: AppSection.mouse.title, detail: levels.min().map { "\($0)%" },
                                  tint: AppSection.mouse.color, lit: false, action: actions.openMouse))
        }
        if layout.config.enabled, !layout.config.menuBarIcon {
            modules.append(Module(id: "layout", symbol: AppSection.layout.symbol, title: AppSection.layout.title, detail: nil,
                                  tint: AppSection.layout.color, lit: false, action: actions.openLayout))
        }
        return modules
    }

    private var awakeDetail: String {
        guard awake.isOn, let session = awake.session else { return String(localized: "Off") }
        guard let until = session.until else { return String(localized: "On") }
        return String(localized: "\(AwakeController.left(until.timeIntervalSinceNow)) left")
    }
}

private struct Module: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String?
    let tint: Color
    /// Filled with its colour: on, or something under way.
    let lit: Bool
    let action: () -> Void
    /// Clicking beside the circle does this instead, with a chevron saying so.
    var more: (() -> Void)?
}

/// A round icon to click, filled with its colour while on or under way; its
/// name and how it is show on hover. One with more to it (Keep Awake's
/// lengths) opens that, where its switch also is.
private struct ModuleTile: View {
    let module: Module
    @StateObject private var hovered = ViewState(false)

    var body: some View {
        Button(action: module.more ?? module.action) {
            Circle()
                .fill(module.lit ? AnyShapeStyle(module.tint.gradient) : AnyShapeStyle(Color.primary.opacity(hovered.value ? 0.14 : 0.09)))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: module.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(module.lit ? AnyShapeStyle(.white) : AnyShapeStyle(module.tint)))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(module.detail.map { "\(module.title): \($0)" } ?? module.title)
        .accessibilityLabel(module.title)
    }
}

/// A tool: its name opens its settings, the switch turns it on or off.
private struct ToolRow: View {
    let section: AppSection
    @Binding var on: Bool
    let open: () -> Void
    @StateObject private var hover = ViewState(false)

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 9) {
                    // Grey rather than `.saturation(0)`, a filter `--snapshot` leaves out.
                    IconTile(symbol: section.symbol, color: on ? section.color : .gray, size: 22)
                        .opacity(on ? 1 : 0.55)
                    Text(section.title)
                        .foregroundStyle(on ? .primary : .secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hover.value ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(section.title) settings")
            Toggle(section.title, isOn: $on)
                .toggleStyle(PanelSwitch())
                .labelsHidden()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(hover.value ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hover.value = $0 }
    }
}

/// A switch drawn here, in the accent colour while on: the panel's window
/// isn't key, as the app isn't made active for it, and macOS draws its own
/// switches grey there.
struct PanelSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.15)))
                .frame(width: 28, height: 16)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.5)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        // Read out as the switch it is.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
