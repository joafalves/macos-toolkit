import SwiftUI

/// The AI usage stat's card on System Stats' page: what's read, in full, and
/// which providers are read.
struct AIUsageCard: View {
    @ObservedObject var usage: AIUsageController
    @StateObject private var tab = ViewState(AIUsageTab.overview)

    var body: some View {
        Card(title: "AI Usage", footnote: "Only what Claude Code and Codex write in their own files is read, and nothing leaves this Mac. Other AI tools only give their limits to a program signed in as you.") {
            AIUsageContent(usage: usage, tab: tab, detailed: true)
                .padding(14)
            RowDivider()
            ToggleRow(title: "Read Claude Code", caption: "Tokens by hour and model, from its transcripts in ~/.claude/projects: only the figures are kept, never what was said. Claude Code doesn't give other apps its limits. The first read of a long history takes a while.",
                      isOn: $usage.config.claude)
            RowDivider()
            ToggleRow(title: "Read Codex", caption: "Its 5-hour and weekly limits, from its sessions in ~/.codex/sessions. New figures only come while Codex runs.",
                      isOn: $usage.config.codex)
            RowDivider()
            ToggleRow(title: "Warn when a limit runs short", caption: "A notification at 80% used, once for each window.",
                      isOn: $usage.config.warnings)
        }
    }
}
