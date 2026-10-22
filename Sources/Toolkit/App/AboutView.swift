import AppKit
import SwiftUI

/// The "About" page: the version, who made it, and where the project lives.
struct AboutView: View {
    static let repository = URL(string: "https://github.com/joafalves/macos-toolkit")!

    /// With the short commit it was built from, which `build.sh` writes in;
    /// a `--snapshot` run has none.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let commit = info?["ToolkitCommit"] as? String else { return "Version \(short)" }
        let modified = info?["ToolkitModified"] as? Bool == true
        return "Version \(short) (\(commit)\(modified ? ", modified" : ""))"
    }

    var body: some View {
        Page {
            VStack(spacing: 10) {
                KitIcon(size: 96)
                Text("MacOS Toolkit").font(.largeTitle.weight(.semibold))
                Text("The little things macOS never shipped, in one menu bar app.")
                    .foregroundStyle(.secondary)
                Text(version).font(.subheadline).foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            Card(title: "People") {
                SettingRow(title: "Founder") {
                    Text("João Alves").foregroundStyle(.secondary)
                }
                RowDivider()
                SettingRow(title: "Contributors", caption: "Everyone who has helped build it.") {
                    link("View on GitHub", "graphs/contributors")
                }
            }

            Card(title: "Project") {
                SettingRow(title: "Source code", caption: "github.com/joafalves/macos-toolkit") {
                    link("Open", "")
                }
                RowDivider()
                SettingRow(title: "What's new", caption: "What each version added, changed and fixed.") {
                    link("Open", "blob/main/CHANGELOG.md")
                }
                RowDivider()
                SettingRow(title: "Report a problem", caption: "Or suggest something.") {
                    link("Open", "issues/new")
                }
                RowDivider()
                SettingRow(title: "License", caption: "Apache License 2.0. Copyright 2026 João Alves.") {
                    link("Open", "blob/main/LICENSE")
                }
            }
        }
    }

    private func link(_ title: String, _ path: String) -> some View {
        Button(title) { NSWorkspace.shared.open(path.isEmpty ? Self.repository : Self.repository.appendingPathComponent(path)) }
    }
}
