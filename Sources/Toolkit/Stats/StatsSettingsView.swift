import SwiftUI

/// The "System Stats" section.
struct StatsSettingsView: View {
    @ObservedObject var stats: StatsController

    var body: some View {
        Page {
            ToolHeader(section: .stats, subtitle: "CPU, memory, network, disk, GPU and power, in the menu bar.",
                       enabled: $stats.config.enabled)

            WhenEnabled(enabled: stats.config.enabled) {
                Card(title: "Menu Bar", footnote: "Click a stat in the menu bar for its last five minutes and details.") {
                    OptionRow(title: "Layout",
                              caption: stats.config.layout == .separate
                                  ? "Each stat on its own, in the look you pick below."
                                  : "Every stat in one place, as small labels two to a column.",
                              selection: $stats.config.layout,
                              options: [(.separate, "Separate"), (.compact, "Compact")])
                    RowDivider()
                    SettingRow(title: "Update every", caption: "Reading is cheap; this is how lively the numbers are.") {
                        Picker("Update every", selection: $stats.config.interval) {
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

                Card(title: "Stats", footnote: "Only the stats in the menu bar are read, and nothing at all while none are.") {
                    ForEach(Array(StatKind.allCases.enumerated()), id: \.element) { index, kind in
                        if index > 0 { RowDivider() }
                        StatRow(kind: kind, stats: stats)
                    }
                }
            }
        }
    }
}

private struct StatRow: View {
    let kind: StatKind
    @ObservedObject var stats: StatsController

    private var setting: StatSetting { stats.config.setting(kind) }

    var body: some View {
        SettingRow(title: kind.title, caption: kind.caption) {
            HStack(spacing: 12) {
                if setting.shown, stats.config.layout == .separate, kind.looks.count > 1 {
                    Picker("Look", selection: Binding(get: { setting.look }, set: { look in stats.config.set(kind) { $0.look = look } })) {
                        ForEach(kind.looks, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle(kind.title, isOn: Binding(get: { setting.shown }, set: { shown in stats.config.set(kind) { $0.shown = shown } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}
