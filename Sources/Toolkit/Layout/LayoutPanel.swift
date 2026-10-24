import AppKit
import SwiftUI

/// The panel the Window Layout part of the menu bar opens: the window in
/// front, then where to put it, drawn as small screens with the part it
/// takes, then what isn't a place (restore, the grid, the desktop). The
/// panel doesn't take the focus, so the window in front stays the one acted
/// on. Room for more below: what acts on every window goes there.
struct LayoutPanelView: View {
    @ObservedObject var layout: LayoutController
    /// The app in front when the panel opened, with its icon.
    let app: (name: String, icon: NSImage)?
    var run: (LayoutKeys.Command) -> Void = { _ in }
    var openSettings: () -> Void = {}

    /// The ones used most, four to a row; the rest have their shortcuts.
    static let places: [LayoutAction] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .firstThird, .centerThird, .lastThird, .maximize,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: AppSection.layout.symbol, color: AppSection.layout.color, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppSection.layout.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let app {
                        HStack(spacing: 4) {
                            Image(nsImage: app.icon).resizable().frame(width: 14, height: 14)
                            Text("\(app.name)'s front window").foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(ModuleBackground())

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.places, id: \.self) { action in
                    PlaceTile(action: action, shortcut: layout.config.shortcut(action).active?.display) {
                        run(.action(action))
                    }
                }
            }

            // Two to a row, so the words fit in other languages too.
            HStack(spacing: 6) {
                CommandChip(symbol: "arrow.uturn.backward", title: "Restore", help: help(.restore)) { run(.action(.restore)) }
                CommandChip(symbol: "square.grid.3x3", title: "Grid", help: "\(String(localized: "The grid")) (\(layout.config.gridShortcut.display))") { run(.grid) }
            }
            HStack(spacing: 6) {
                CommandChip(symbol: "menubar.dock.rectangle", title: "Show the desktop", help: help(.showDesktop)) { run(.action(.showDesktop)) }
                if layout.displays.count > 1 {
                    CommandChip(symbol: "rectangle.on.rectangle", title: "Next display", help: help(.nextDisplay)) { run(.action(.nextDisplay)) }
                }
            }

            Divider().padding(.horizontal, 4)
            PanelFooter(openSettings: openSettings)
                .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(width: 300)
    }

    private func help(_ action: LayoutAction) -> String {
        guard let shortcut = layout.config.shortcut(action).active else { return action.title }
        return "\(action.title) (\(shortcut.display))"
    }
}

/// One place for the window: a small screen with the part it takes filled.
private struct PlaceTile: View {
    let action: LayoutAction
    let shortcut: String?
    let run: () -> Void
    @StateObject private var hovered = ViewState(false)

    var body: some View {
        Button(action: run) {
            GeometryReader { geo in
                let screen = CGRect(origin: .zero, size: geo.size).insetBy(dx: 9, dy: 7)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                        .frame(width: screen.width, height: screen.height)
                        .offset(x: screen.minX, y: screen.minY)
                    let part = Self.part(of: action).insetBy(dx: 0.035, dy: 0.05)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(hovered.value ? Color.accentColor : Color.primary.opacity(0.55))
                        .frame(width: part.width * screen.width, height: part.height * screen.height)
                        .offset(x: screen.minX + part.minX * screen.width, y: screen.minY + part.minY * screen.height)
                }
            }
            .frame(height: 44)
            .background(Color.primary.opacity(hovered.value ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(shortcut.map { "\(action.title) (\($0))" } ?? action.title)
        .accessibilityLabel(action.title)
    }

    /// The part of the screen, top left at 0, 0.
    static func part(of action: LayoutAction) -> CGRect {
        LayoutGeometry.unit(for: action) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}

/// What isn't a place on the screen: a symbol and a word, as the lengths in
/// Keep Awake's panel are drawn.
private struct CommandChip: View {
    let symbol: String
    let title: LocalizedStringKey
    let help: String
    let run: () -> Void
    @StateObject private var hovered = ViewState(false)

    var body: some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(hovered.value ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(help)
    }
}
