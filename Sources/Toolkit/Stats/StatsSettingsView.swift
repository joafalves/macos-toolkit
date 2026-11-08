import SwiftUI

/// The "System Stats" section.
struct StatsSettingsView: View {
    @ObservedObject var stats: StatsController

    var body: some View {
        Page {
            ToolHeader(section: .stats, subtitle: "CPU, memory, network, disk, GPU, power and AI usage, in the menu bar or a panel.",
                       enabled: $stats.config.enabled)

            WhenEnabled(enabled: stats.config.enabled) {
                Picker("Page", selection: $stats.tab.afterUpdate) {
                    ForEach(StatsTab.all, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Not fixed to its labels: seven, longer in Portuguese, are wider
                // than the page in the narrowest window, where they shrink.
                .frame(maxWidth: .infinity)

                switch stats.tab {
                case .settings: settings
                // A view of its own for each stat, so going from one to the next
                // ends the one and starts the other rather than reusing it.
                case .stat(let kind): StatTab(stats: stats, kind: kind).id(kind)
                }
            }
        }
        .onAppear {
            if let tab = StatsController.previewTab, !stats.persists { stats.tab = .stat(tab) }
        }
    }

    @ViewBuilder
    private var settings: some View {
        Card(title: "Menu Bar", footnote: "Click a stat in the menu bar, or the System Stats icon, for its last five minutes and details.") {
            OptionRow(title: "Layout",
                      caption: stats.config.layout == .separate
                          ? "Each stat on its own, in the look you pick below."
                          : "Every stat in one place, as small labels two to a column.",
                      selection: $stats.config.layout,
                      options: [(.separate, "Separate"), (.compact, "Compact")])
            RowDivider()
            SettingRow(title: "Update every", caption: "Reading is cheap; this is how lively the numbers are.") {
                Picker("Update every", selection: $stats.config.interval.afterUpdate) {
                    ForEach(StatsConfig.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            RowDivider()
            ToggleRow(title: "Color memory when it runs short",
                      caption: "Yellow, then red, as macOS reports memory running short. Off, it keeps the menu bar's color.",
                      isOn: $stats.config.memoryColors)
        }

        Card(title: "Panels") {
            ToggleRow(title: "Top apps' CPU of the whole CPU",
                      caption: "Off, as Activity Monitor counts it: 100% is one core, so an app can reach \(StatsController.cores * 100)% on this Mac. On, its share of every core, up to 100%, like the CPU figure itself.",
                      isOn: $stats.config.topAppsOfWholeCPU)
        }

        Card(title: "Stats", footnote: "The panel shows the stat you click, then those only in the panel. Those are read only while the panel or their tab is open, so their charts start when it opens; AI usage is read from its files whenever it isn't off.") {
            ForEach(Array(StatKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { RowDivider() }
                StatRow(kind: kind, stats: stats, ai: stats.ai)
            }
        }

        if stats.config.setting(.ai).place != .off {
            AIUsageCard(usage: stats.ai)
        }
    }
}

/// A stat's history and details, as its panel shows them, with more room.
/// Read while the tab is on screen, whatever the stat's place: one that's
/// only in the panel, or off, starts its chart as the tab opens.
private struct StatTab: View {
    let stats: StatsController
    let kind: StatKind
    @StateObject private var watch = PageWatch()

    var body: some View {
        Card(footnote: footnote) {
            StatSection(stats: stats, kind: kind, wide: true)
                .padding(14)
        }
        .onAppear { watch.start(stats, kind) }
        .onDisappear { watch.end() }
    }

    private var footnote: LocalizedStringKey? {
        stats.config.setting(kind).shown ? nil : "Read only while this tab is open, so its chart starts when you open it."
    }
}

private struct StatRow: View {
    let kind: StatKind
    @ObservedObject var stats: StatsController
    /// For AI usage's looks, which follow its tools.
    @ObservedObject var ai: AIUsageController

    private var setting: StatSetting { stats.config.setting(kind) }

    var body: some View {
        SettingRow(title: .verbatim(kind.title), caption: .verbatim(kind.caption)) {
            HStack(spacing: 12) {
                let looks = stats.looks(kind)
                if setting.shown, stats.config.layout == .separate, looks.count > 1 {
                    Picker("Look", selection: Binding(get: { setting.look }, set: { look in stats.config.set(kind) { $0.look = look } })) {
                        ForEach(looks, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                Picker(kind.title, selection: Binding(get: { setting.place }, set: { place in stats.config.set(kind) { $0.place = place } })) {
                    ForEach(StatPlace.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// The stat a tab has System Stats read while it's on screen. Ended as the
/// tab goes, and as its view is let go of with the window, which closing it
/// does without an `onDisappear`.
private final class PageWatch: ObservableObject {
    private weak var stats: StatsController?
    private var kind: StatKind?

    func start(_ stats: StatsController, _ kind: StatKind) {
        self.stats = stats
        self.kind = kind
        stats.page = kind
    }

    /// Another tab's view can appear before this one goes: only its own is cleared.
    func end() {
        if let kind, stats?.page == kind { stats?.page = nil }
        kind = nil
    }

    deinit { end() }
}
