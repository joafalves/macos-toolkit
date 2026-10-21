import AppKit
import SwiftUI

/// The "Window Layout" section.
struct LayoutSettingsView: View {
    @ObservedObject var layout: LayoutController
    @ObservedObject var mouse: MouseController

    private var config: LayoutConfig { layout.config }
    /// Screen Recording, checked again when the app comes back to the front.
    @StateObject private var recording = ViewState(SwitcherPreviews.permitted)

    private static let groups: [(String, [LayoutAction])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Thirds", [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds]),
        ("Size and Position", [.maximize, .almostMaximize, .maximizeHeight, .center, .larger, .smaller, .restore]),
        ("Displays", [.previousDisplay, .nextDisplay]),
    ]

    private static let halvesNote = "They go by where the window is, however it got there. Left or right again moves the window on to the next display that way. Up again maximizes it, and once more moves it, maximized, to the display above. Down again moves it to the top half of the display below."

    private static let gridKeys: [(String, String)] = [
        ("Pick two corners", "two letter keys"),
        ("Move the selection", "←  ↑  →  ↓"),
        ("Grow or shrink it", "⇧ ←  ↑  →  ↓"),
        ("Place the window", "↩  or  space"),
        ("Start the corners again", "⌫"),
        ("Go to the next display", "⇥"),
        ("Cancel", "esc"),
        ("With the mouse", "drag across the cells"),
    ]

    private func caption(_ action: LayoutAction) -> String? {
        switch action {
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds:
            return action == .firstThird ? "Down the display instead of across on one that stands upright." : nil
        case .almostMaximize: return "Nine tenths of the display, centred."
        case .maximizeHeight: return "Full height, keeping the width."
        case .larger, .smaller: return "\(Int(LayoutGeometry.step)) points on every side."
        case .restore: return "Back to the size and place it had before it was snapped."
        case .previousDisplay, .nextDisplay: return action == .nextDisplay ? "A snapped window stays snapped the same way." : nil
        default: return nil
        }
    }

    private func binding(_ action: LayoutAction) -> Binding<Shortcut> {
        Binding(get: { layout.config.shortcut(action) }, set: { layout.config.setShortcut($0, for: action) })
    }

    /// Every other shortcut of this tool, so one can't be given twice.
    private func taken(except action: LayoutAction?) -> [Shortcut] {
        var all = LayoutAction.allCases.filter { $0 != action }.compactMap { config.shortcut($0).active }
        if action != nil, let grid = config.gridShortcut.active { all.append(grid) }
        return all
    }

    var body: some View {
        Page {
            ToolHeader(section: .layout, subtitle: "Snap windows to halves, quarters and thirds, or place them on a grid.",
                       enabled: $layout.config.enabled)

            if config.enabled {
                if !mouse.accessibilityGranted {
                    Banner(text: "Window Layout needs the Accessibility permission to move windows and to notice them being dragged.",
                           button: "Grant Access…") { mouse.requestAccessibility() }
                } else if layout.tapFailed {
                    Banner(text: "Accessibility is granted, but the app has to restart before snapping by dragging takes effect.",
                           button: "Restart") { mouse.relaunch() }
                }
                if layout.rectangleRunning {
                    Banner(text: "Rectangle is running. It has the same shortcuts and snaps windows too, so the two get in each other's way.",
                           button: "Quit Rectangle") { layout.quitRectangle() }
                }
                if config.suggest == .previews, !recording.value, !layout.isPreview {
                    Banner(text: "Suggestions show pictures of your windows with the Screen Recording permission. Until then they show the list.",
                           button: "Allow…") {
                        if !CGRequestScreenCaptureAccess() {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        recording.value = SwitcherPreviews.permitted
                    }
                }
                if !layout.failedShortcuts.isEmpty {
                    Banner(text: "Another app already has \(layout.failedShortcuts.joined(separator: ", ")). Change them below, or quit that app and turn Window Layout off and on.",
                           button: "Retry") { layout.retryShortcuts() }
                }
            }

            WhenEnabled(enabled: config.enabled) {
                Card(title: "Grid",
                     footnote: "The letters are the keys in the grid's place on the keyboard, whatever the layout: the top left cell is always the key where Q is on a US keyboard. Each display keeps its own grid.") {
                    ShortcutRow(title: "Open the grid", caption: "Over the display with the focused window.",
                                shortcut: $layout.config.gridShortcut, defaultValue: LayoutConfig.defaultGridShortcut,
                                taken: taken(except: nil))
                    ForEach(layout.displays, id: \.uuid) { display in
                        RowDivider()
                        GridRow(layout: layout, display: display)
                    }
                }

                Card(title: "In the Grid") {
                    ForEach(Array(Self.gridKeys.enumerated()), id: \.offset) { index, key in
                        if index > 0 { RowDivider() }
                        SettingRow(title: key.0) {
                            Text(key.1).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                Card(title: "Dragging",
                     footnote: "Esc while dragging drops the window without snapping. macOS's own tiling by dragging is off while any of these is on, and turned on when you turn them off. If the app quits, it's put back as it was.") {
                    ToggleRow(title: "Snap at the edges",
                              caption: "Drag a window to a side or the bottom for half the display, to a corner for a quarter, or to the top to fill it. Where a side meets another display, stop just short of the edge.",
                              isOn: $layout.config.edgeSnapping)
                    RowDivider()
                    OptionRow(title: "Layouts while dragging",
                              caption: "Hold this key while dragging a window: a bar of layouts shows by the pointer. Move onto a part of one and let go.",
                              selection: Binding(get: { layout.config.dragSlots }, set: { key in
                                  layout.config.dragSlots = key
                                  if key != .none, layout.config.dragGrid == key { layout.config.dragGrid = .none }
                              }),
                              options: DragModifier.allCases.map { ($0, $0.title) })
                    RowDivider()
                    OptionRow(title: "Grid while dragging",
                              caption: "Hold this key while dragging a window to drop it on the grid. The cell under the pointer is one corner: move to the other and let go. Let go of the key to start again.",
                              selection: Binding(get: { layout.config.dragGrid }, set: { key in
                                  layout.config.dragGrid = key
                                  if key != .none, layout.config.dragSlots == key { layout.config.dragSlots = .none }
                              }),
                              options: DragModifier.allCases.map { ($0, $0.title) })
                    RowDivider()
                    OptionRow(title: "Suggest windows for the rest",
                              caption: "After you drop a window into part of a display, other windows are offered for the part that's left; click one, or press its number. Previews need Screen Recording, and show the list until then.",
                              selection: $layout.config.suggest,
                              options: SuggestStyle.allCases.map { ($0, $0.title) })
                    if layout.config.suggest != .off {
                        RowDivider()
                        OptionRow(title: "Windows from other displays",
                                  caption: "This Display offers only that display's windows. If None Here offers the others' when it has none. Always lists them after its own.",
                                  selection: $layout.config.suggestFrom,
                                  options: SuggestFrom.allCases.map { ($0, $0.title) })
                    }
                    RowDivider()
                    ToggleRow(title: "Stop at the edge between displays",
                              caption: "While dragging a window, the pointer stops where one display meets another, so the snap there is easy to hit. Moving away or along the edge lets go; keep pushing to cross. Once per drag.",
                              isOn: $layout.config.holdAtEdges)
                    RowDivider()
                    ToggleRow(title: "Restore the size when dragged away",
                              caption: "A snapped window you drag away gets back the size it had.",
                              isOn: $layout.config.restoreOnDragOut)
                }

                Card(title: "Placement") {
                    SettingRow(title: "Gap", caption: "Space between windows and around the edges of the display. macOS's own margins follow it: off with no gap, otherwise its fixed 8 points. Up to 8, Maximize is macOS's own Fill, so the window counts as filled; above that it's placed with the gap.") {
                        EmptyView()
                    } extra: {
                        ValueSlider(value: $layout.config.gap, range: 0...40, step: 2, low: "0", high: "40") {
                            $0 == 0 ? "None" : "\(Int($0)) pt"
                        }
                    }
                    RowDivider()
                    ToggleRow(title: "Sizes at the outer edge",
                              caption: "At the outer edge of the last display, left or right pressed again goes through ⅔ and ⅓ instead of stopping.",
                              isOn: $layout.config.cycleAtEdge)
                }

                ForEach(Self.groups, id: \.0) { group in
                    Card(title: group.0, footnote: group.0 == "Halves" ? Self.halvesNote : nil) {
                        ForEach(Array(group.1.enumerated()), id: \.offset) { index, action in
                            if index > 0 { RowDivider() }
                            ShortcutRow(title: action.title, caption: caption(action), shortcut: binding(action),
                                        defaultValue: action.defaultShortcut, taken: taken(except: action))
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recording.value = SwitcherPreviews.permitted
        }
    }
}

/// One display's grid: a picture of it, and its columns and rows.
private struct GridRow: View {
    @ObservedObject var layout: LayoutController
    let display: LayoutDisplay

    private var size: GridSize { layout.gridSize(for: display) }
    private var custom: Bool { layout.config.grids[display.uuid] != nil }

    private func set(columns: Int? = nil, rows: Int? = nil) {
        layout.config.grids[display.uuid] = GridSize(columns: columns ?? size.columns, rows: rows ?? size.rows)
    }

    var body: some View {
        SettingRow(title: display.name, caption: custom ? "\(size.columns) × \(size.rows)" : "\(size.columns) × \(size.rows), to suit its shape") {
            HStack(spacing: 14) {
                GridThumbnail(size: size, aspect: display.frame.width / max(display.frame.height, 1))
                Stepper(value: Binding(get: { size.columns }, set: { set(columns: $0) }), in: GridSize.columnRange) {
                    Text("\(size.columns) across").monospacedDigit()
                }
                Stepper(value: Binding(get: { size.rows }, set: { set(rows: $0) }), in: GridSize.rowRange) {
                    Text("\(size.rows) down").monospacedDigit()
                }
                Button { layout.config.grids[display.uuid] = nil } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Back to the grid that suits its shape")
                    .opacity(custom ? 1 : 0)
                    .disabled(!custom)
            }
            .fixedSize()
        }
    }
}

/// A display drawn small, at its shape, with its cells.
private struct GridThumbnail: View {
    let size: GridSize
    let aspect: CGFloat

    var body: some View {
        let height: CGFloat = 34
        Canvas { context, area in
            let gap: CGFloat = 2
            let width = (area.width - gap * CGFloat(size.columns + 1)) / CGFloat(size.columns)
            let cellHeight = (area.height - gap * CGFloat(size.rows + 1)) / CGFloat(size.rows)
            for row in 0..<size.rows {
                for column in 0..<size.columns {
                    let rect = CGRect(x: gap + CGFloat(column) * (width + gap), y: gap + CGFloat(row) * (cellHeight + gap),
                                      width: width, height: cellHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.accentColor.opacity(0.45)))
                }
            }
        }
        .frame(width: min(max(height * aspect, 24), 92), height: height)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.2)))
    }
}
