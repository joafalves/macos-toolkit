import SwiftUI

/// The menu bar item's parts in their order, left to right, to drag into
/// another. Every tool is listed, shown or not, so each keeps its place.
struct MenuBarOrderList: View {
    /// A row's switch: none for the toolkit menu, which is always there, and
    /// none while the tool itself is off, which is turned on from its page.
    enum Place: Equatable {
        case always, shown(Bool), toolOff
    }

    @Binding var order: [MenuBarTool]
    let place: (MenuBarTool) -> Place
    let setShown: (MenuBarTool, Bool) -> Void
    let open: (MenuBarTool) -> Void

    private static let rowHeight: CGFloat = 32

    var body: some View {
        // A list for its own drag to reorder; the card already draws the background.
        List {
            ForEach(order, id: \.self) { tool in
                row(tool)
                    .listRowBackground(Color.clear)
                    // In line with the card's text, and as tall as the frame counts on.
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            .onMove { order.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .frame(height: CGFloat(order.count) * Self.rowHeight + 4)
    }

    private func row(_ tool: MenuBarTool) -> some View {
        let place = place(tool)
        let on = place == .always || place == .shown(true)
        let section = AppSection(rawValue: tool.rawValue)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            if let section {
                IconTile(symbol: section.symbol, color: on ? section.color : .gray, size: 20)
                    .opacity(on ? 1 : 0.6)
            } else {
                KitIcon(size: 20)
            }
            Text(section?.title ?? "Toolkit menu")
                .foregroundStyle(on ? .primary : .secondary)
            Spacer()
            switch place {
            case .always:
                EmptyView()
            case .shown(let shown):
                Toggle("In the menu bar", isOn: Binding(get: { shown }, set: { setShown(tool, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            case .toolOff:
                Text("Off")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open…") { open(tool) }
                    .controlSize(.small)
            }
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }
}
