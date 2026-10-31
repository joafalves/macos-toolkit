import SwiftUI

/// The "Window Switcher" section.
struct SwitcherSettingsView: View {
    @ObservedObject var switcher: SwitcherController
    @ObservedObject var mouse: MouseController
    @ObservedObject private var permissions = Permissions.shared
    /// Screen Recording, checked again when the app comes back to the front.
    @StateObject private var recording = ViewState(SwitcherPreviews.permitted)
    @StateObject private var displays = ViewState<[LayoutDisplay]>([])

    private var shortcut: Shortcut { switcher.config.shortcut }
    /// The keys held to keep the list open, like "⌘".
    private var held: String { Shortcut.glyphs(shortcut.flags.subtracting(.shift)) }
    private var key: String { shortcut.key }

    private var keys: [(LocalizedStringResource, LocalizedStringKey)] {
        let grid = switcher.config.style == .previews
        let back = shortcut.flags.contains(.shift) ? (grid ? "←" : "↑") : "⇧\(key)  \(grid ? "←" : "↑")"
        return [
            ("Next window", .verbatim("\(key)  \(grid ? "→" : "↓")")),
            ("Previous window", .verbatim(back)),
        ] + (grid ? [("The window above or below", "↑  ↓")] : []) + [
            ("Go straight to one of the first nine", "1 – 9"),
            ("Go to the selected window", "release \(held)"),
            ("Cancel", "esc"),
            ("Search by name, or open an app", "type"),
            ("Close the window", "⇧W"),
            ("Minimize the window", "⇧M"),
            ("Hide the app", "⇧H"),
            ("Quit the app", "⇧Q"),
            ("Quit every dimmed app", "⇧X"),
        ]
    }

    private var freshnessCaption: LocalizedStringKey {
        switch switcher.config.previewFreshness {
        case .cached: return "Shows the last picture of each window at once, and a new one a moment later."
        case .fresh: return "Only new pictures: each window shows its app's icon until its picture arrives."
        case .live: return "Pictures keep updating while the switcher is open, so video plays. Uses more power."
        }
    }

    /// Rows that linked settings go to.
    private enum Anchor {
        static let showOn = "switcher.showOn"
        static let windows = "switcher.windows"
    }

    private var mainHolds: Bool { switcher.config.placement == .mainScreen }

    var body: some View {
        Page {
            ToolHeader(section: .switcher, subtitle: "\(shortcut.display) through windows instead of apps.", enabled: $switcher.config.enabled)

            if switcher.config.enabled {
                if !permissions.isGranted(.accessibility) {
                    Banner(text: "The switcher is not active yet. It needs the Accessibility permission to see \(shortcut.display) and your windows.",
                           button: "Grant Access…") { mouse.requestAccessibility() }
                } else if switcher.tapFailed {
                    Banner(text: "Accessibility is granted, but the app has to restart before the switcher takes effect.",
                           button: "Restart") { Relaunch.now() }
                }
            }

            // Granted since launch: only a restart lets this process use it.
            if switcher.config.enabled, switcher.config.style == .previews, !recording.value, !switcher.isPreview,
               permissions.state(.screenRecording) == .needsRestart {
                RestartBanner()
            } else if switcher.config.enabled, switcher.config.style == .previews, !recording.value, !switcher.isPreview {
                Banner(text: "Previews need the Screen Recording permission. Until then the switcher shows the list.",
                       button: "Allow…") {
                    Permissions.shared.request(.screenRecording)
                    recording.value = SwitcherPreviews.permitted
                }
            }

            // Locked, as when off, until it has what it needs.
            WhenEnabled(enabled: switcher.config.enabled && permissions.ready(switcher.permissionNeeds)) {
                Card(title: "Appearance") {
                    OptionRow(title: "Style", caption: "A list of rows, or a grid with a picture of each window.",
                              selection: $switcher.config.style,
                              options: [(.list, "List"), (.previews, "Previews")])
                    RowDivider()
                    ToggleRow(title: "App colours",
                              caption: "A flat colour for each app, here and in Window Layout's suggestions. Apps open together get colours that look different, and an app keeps its colour wherever it can.",
                              isOn: $switcher.config.appColors)
                    if switcher.config.style == .previews {
                        RowDivider()
                        OptionRow(title: "Size", caption: "The largest a preview gets. With many windows they shrink so all of them fit. Fit makes them as large as the display allows.",
                                  selection: $switcher.config.previewSize,
                                  options: PreviewSize.allCases.map { ($0, $0.title) })
                        RowDivider()
                        OptionRow(title: "App icons", caption: "Small icons sit in the bar beside the title. Large ones are in the top right corner of the picture, with the app's badge.",
                                  selection: $switcher.config.previewIcons,
                                  options: [(.small, "Small"), (.large, "Large")])
                        RowDivider()
                        OptionRow(title: "Pictures", caption: freshnessCaption,
                                  selection: $switcher.config.previewFreshness,
                                  options: PreviewFreshness.allCases.map { ($0, $0.title) })
                    }
                }

                if switcher.config.style == .previews {
                    Card(title: "Grid Width",
                         footnote: "How much of a display's width the grid can use. Windows that don't fit go on another row. Each display keeps its own, and a new one starts with what suits its size.") {
                        ForEach(Array(displays.value.enumerated()), id: \.element.uuid) { index, display in
                            if index > 0 { RowDivider() }
                            GridWidthRow(switcher: switcher, display: display)
                        }
                    }
                }

                Card(title: "Shortcut",
                     footnote: shortcut == .commandTab
                        ? "macOS's app switcher is off while the switcher has ⌘Tab."
                        : "macOS's ⌘Tab app switcher works as usual alongside this.") {
                    ShortcutRow(title: "Open the switcher",
                                caption: shortcut.flags.contains(.shift)
                                    ? "Hold \(held) to keep the list open and let go to switch."
                                    : "Hold \(held) to keep the list open and let go to switch. Add ⇧ to go backwards.",
                                shortcut: $switcher.config.shortcut, defaultValue: .commandTab, optional: false,
                                taken: [switcher.config.appShortcut])
                    RowDivider()
                    ShortcutRow(title: "Windows of the current app",
                                caption: "The same list, with only the windows of the app you're in.",
                                shortcut: $switcher.config.appShortcut, defaultValue: .commandAboveTab,
                                taken: [switcher.config.shortcut])
                    RowDivider()
                    OptionRow(title: "Show on", caption: "Which display the list opens on.",
                              selection: $switcher.config.placement,
                              options: [(.mainScreen, "The main display"), (.mouse, "The one with the pointer"), (.activeWindow, "The one with the active window")],
                              menu: true,
                              link: mainHolds ? .holds("Lists the windows of every display", anchor: Anchor.windows) : nil)
                        .settingAnchor(Anchor.showOn)
                    RowDivider()
                    // Held at every display while it opens on the main one, which
                    // is the same display wherever you are: its own windows only
                    // would hide the rest for good.
                    OptionRow(title: "Windows", caption: "Every window, or only those on the display the list opens on.",
                              selection: Binding(get: { switcher.config.shownWindows }, set: { switcher.config.windows = $0 }),
                              options: [(.all, "Every display"), (.display, "That display")],
                              link: mainHolds ? .heldBy("Every display while it shows on the main display", anchor: Anchor.showOn) : nil)
                        .settingAnchor(Anchor.windows)
                    RowDivider()
                    ToggleRow(title: "Open on the previous window",
                              caption: switcher.config.style == .previews
                                  ? "When the grid appears, the window you were in before is selected, like macOS's own ⌘Tab. When off, the window you're in is. A quick \(shortcut.display) goes back to the previous window either way."
                                  : "When the list appears, the window you were in before is selected, like macOS's own ⌘Tab. When off, the window you're in is. A quick \(shortcut.display) goes back to the previous window either way.",
                              isOn: $switcher.config.startOnPrevious)
                }

                Card(title: "While \(held) Is Held",
                     footnote: switcher.config.shownWindows == .display
                        ? "Windows are listed most recently used first, across all Spaces. Minimized windows come last. Hidden apps and apps without a window are on no display, so they aren't listed."
                        : "Windows are listed most recently used first, across all Spaces. Minimized windows, hidden apps and apps without a window come last.") {
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                        if index > 0 { RowDivider() }
                        SettingRow(title: key.0) {
                            Text(key.1)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recording.value = SwitcherPreviews.permitted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays.value = switcher.gridDisplays
        }
        .onAppear { displays.value = switcher.gridDisplays }
    }
}

/// How wide the grid gets on one display.
private struct GridWidthRow: View {
    @ObservedObject var switcher: SwitcherController
    let display: LayoutDisplay

    private var width: Double { switcher.config.gridWidth(for: display) }
    private var custom: Bool { switcher.config.gridWidths[display.uuid] != nil }
    /// Set for all, nothing here is different from what "all" would give.
    private var sameEverywhere: Bool { switcher.config.gridWidths.isEmpty && switcher.config.gridWidthForAll == width }
    private var across: Int {
        GridLayout.across(display.usable.width * width / 100, tile: switcher.config.previewSize.maxTileWidth)
    }

    var body: some View {
        SettingRow(title: .verbatim(display.name), caption: "\(across) across") {
            HStack(spacing: 10) {
                Button { switcher.config.gridWidths[display.uuid] = nil } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Back to the default")
                    .opacity(custom ? 1 : 0)
                    .disabled(!custom)
                Button("Use on All Displays") {
                    let width = width
                    var config = switcher.config
                    config.gridWidths = [:]
                    config.gridWidthForAll = width
                    switcher.config = config
                }
                .disabled(sameEverywhere)
            }
        } extra: {
            ValueSlider(value: Binding(get: { width }, set: { switcher.config.gridWidths[display.uuid] = $0 }),
                        range: GridWidth.range, step: 1, low: .verbatim("\(Int(GridWidth.range.lowerBound))%"),
                        high: .verbatim("\(Int(GridWidth.range.upperBound))%")) { "\(Int($0))%" }
        }
    }
}
