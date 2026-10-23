import AppKit
import SwiftUI

/// The "About" page: the version, who made it, and where the project lives.
struct AboutView: View {
    static let repository = URL(string: "https://github.com/joafalves/macos-toolkit")!
    @ObservedObject var model: AppModel
    @ObservedObject var updater = Updater.shared

    /// With the short commit it was built from, which `build.sh` writes in;
    /// a `--snapshot` run has none.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let commit = info?["ToolkitCommit"] as? String else { return String(localized: "Version \(short)") }
        let modified = info?["ToolkitModified"] as? Bool == true
        return modified ? String(localized: "Version \(short) (\(commit), modified)") : String(localized: "Version \(short) (\(commit))")
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

            updates

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

    // MARK: - Updates

    private var updates: some View {
        Card(title: "Updates") {
            SettingRow(title: status, caption: statusCaption) {
                switch updater.state {
                case .checking, .installing:
                    ProgressView().controlSize(.small)
                case .available:
                    // A click, not Return: it quits the app.
                    Button("Install and Relaunch") { updater.install() }
                default:
                    Button("Check Now") { updater.check() }
                }
            }
            if let release = updater.available ?? installing {
                RowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("What's in \(release.version)").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Release Page") { NSWorkspace.shared.open(release.page) }
                            .buttonStyle(.link)
                            .font(.subheadline)
                    }
                    ScrollView {
                        Text(Self.notes(release.notes))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            RowDivider()
            ToggleRow(title: "Check automatically",
                      caption: "When the app starts and once a day, from the project's releases on GitHub. It asks before installing anything.",
                      isOn: $model.general.checkForUpdates)
        }
    }

    private var installing: Updater.Release? {
        if case .installing(let release) = updater.state { return release }
        return nil
    }

    private var status: LocalizedStringKey {
        switch updater.state {
        case .idle: return "Version \(Updater.currentVersion)"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let release): return "Version \(release.version) is available"
        case .installing(let release): return "Installing \(release.version)…"
        case .failed: return "Couldn't check for updates"
        }
    }

    private var statusCaption: LocalizedStringKey? {
        switch updater.state {
        case .available: return "You have \(Updater.currentVersion). It's checked against this app's signature before it's installed, then the app restarts."
        case .installing: return "The app restarts when it's done."
        case .failed(let message): return .verbatim(message)
        default:
            guard let last = updater.lastChecked else { return nil }
            return "Last checked \(last.formatted(.relative(presentation: .named)))."
        }
    }

    /// The release's notes as GitHub shows them, near enough: their bold
    /// tool names and links, one item a line.
    static func notes(_ markdown: String) -> AttributedString {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            // Install instructions and the attribution are for the release page.
            .prefix { !$0.hasPrefix("## ") && !$0.hasPrefix("---") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? "• " + $0.dropFirst(2) : $0 }
        // A heading in bold, with a line before it but the first.
        let text = lines.enumerated().map { index, line in
            guard line.hasPrefix("### ") else { return line }
            return (index > 0 ? "\n" : "") + "**\(line.dropFirst(4))**"
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func link(_ title: LocalizedStringKey, _ path: String) -> some View {
        Button(title) { NSWorkspace.shared.open(path.isEmpty ? Self.repository : Self.repository.appendingPathComponent(path)) }
    }
}
