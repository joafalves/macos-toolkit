import SwiftUI

/// The panel the Mouse part of the menu bar opens, laid out like Keep
/// Awake's: the tool on top, then each connected mouse with its charge. A
/// mouse opens its own page in the settings.
struct MousePanelView: View {
    @ObservedObject var mouse: MouseController
    var open: (MouseDevice) -> Void = { _ in }
    var openSettings: () -> Void = {}

    private var connected: [MouseDevice] { mouse.devices.filter(\.connected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: AppSection.mouse.symbol, color: AppSection.mouse.color, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppSection.mouse.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(ModuleBackground())

            if !connected.isEmpty {
                VStack(spacing: 2) {
                    ForEach(connected) { device in
                        MousePanelRow(mouse: mouse, device: device) { open(device) }
                    }
                }
            }
            Divider().padding(.horizontal, 4)
            PanelFooter(openSettings: openSettings)
                .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(width: 300)
    }

    private var status: String {
        switch connected.count {
        case 0: return String(localized: "No mouse connected")
        case 1: return String(localized: "1 mouse connected")
        default: return String(localized: "\(connected.count) mice connected")
        }
    }
}

/// A connected mouse: its name, how it's connected and its charge, lit
/// while the pointer is on it, as a button to its settings.
private struct MousePanelRow: View {
    @ObservedObject var mouse: MouseController
    let device: MouseDevice
    let action: () -> Void
    @StateObject private var hovered = ViewState(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: mouse.label(for: device))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MouseConnection(device: device)
                }
                Spacer(minLength: 4)
                if let level = mouse.battery(for: device) {
                    MouseBattery(level: level)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovered.value ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(hovered.value ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Show this mouse's settings")
    }
}
