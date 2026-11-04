import SwiftUI

/// The "AI Usage" section.
struct AIUsageSettingsView: View {
    @ObservedObject var usage: AIUsageController

    var body: some View {
        Page {
            ToolHeader(section: .aiUsage, subtitle: "How much of your AI plans' limits is left, from what the tools on this Mac write down.",
                       enabled: $usage.config.enabled,
                       menuBar: MenuBarSwitch(isOn: $usage.config.inMenuBar, caption: "Shows the limit closest to running out. A click opens its panel."))

            WhenEnabled(enabled: usage.config.enabled) {
                Card(title: "Usage") {
                    AIUsageContent(usage: usage)
                        .padding(14)
                }

                Card(title: "Sources", footnote: "Only token counts and limits are read from these folders, never what's in a conversation, and nothing leaves this Mac.") {
                    ToggleRow(title: "Claude", caption: "Tokens used, from ~/.claude/projects. Claude's files don't say how much of its limits is left.",
                              isOn: $usage.config.claude)
                    RowDivider()
                    ToggleRow(title: "Codex", caption: "How much of its limits is left, from ~/.codex/sessions. New figures only come while Codex runs.",
                              isOn: $usage.config.codex)
                }

                Card(title: "Warnings") {
                    ToggleRow(title: "Warn when a limit runs short", caption: "A notification at 80% used, once for each window. Only for Codex, as Claude's files don't have its limits.",
                              isOn: $usage.config.warnings)
                }
            }
        }
    }
}
