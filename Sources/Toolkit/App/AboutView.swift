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
                // Part of the row above, in a box of its own rather than
                // between the card's lines like a setting.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("What's in \(release.version)").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Release Page") { NSWorkspace.shared.open(release.page) }
                            .buttonStyle(.link)
                            .font(.subheadline)
                    }
                    ScrollView {
                        ReleaseNotesView(sections: Self.notes(release.notes))
                    }
                    .frame(maxHeight: 180)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
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
        case .available: return "You have \(Updater.currentVersion)."
        case .installing: return "The app restarts when it's done."
        case .failed(let message): return .verbatim(message)
        default:
            guard let last = updater.lastChecked else { return nil }
            return "Last checked \(last.formatted(.relative(presentation: .named)))."
        }
    }

    /// A release's notes in their sections (Added, Changed, Fixed), each
    /// item whole: one the changelog wraps onto the next line is one item.
    /// Install instructions and the attribution are for the release page.
    struct NotesSection: Identifiable {
        let id: Int
        var title: String?
        var items: [AttributedString] = []
    }

    static func notes(_ markdown: String) -> [NotesSection] {
        var sections: [NotesSection] = []
        var items: [String] = []
        func close() {
            guard !items.isEmpty else { return }
            if sections.isEmpty { sections.append(NotesSection(id: 0)) }
            sections[sections.count - 1].items += items.map {
                (try? AttributedString(markdown: $0, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString($0)
            }
            items = []
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(while: { !$0.hasPrefix("## ") && !$0.hasPrefix("---") }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("### ") {
                close()
                sections.append(NotesSection(id: sections.count, title: String(line.dropFirst(4))))
            } else if raw.first?.isWhitespace == true, let last = items.last {
                items[items.count - 1] = last + " " + line
            } else {
                items.append(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line)
            }
        }
        close()
        return sections.filter { !$0.items.isEmpty }
    }

    private func link(_ title: LocalizedStringKey, _ path: String) -> some View {
        Button(title) { NSWorkspace.shared.open(path.isEmpty ? Self.repository : Self.repository.appendingPathComponent(path)) }
    }
}

/// The notes as sections: a title with room around it, then the items as
/// bullets with their lines indented under the first.
private struct ReleaseNotesView: View {
    let sections: [AboutView.NotesSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    if let title = section.title {
                        Text(verbatim: title)
                            .font(.callout.weight(.semibold))
                            .padding(.bottom, 2)
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•").foregroundStyle(.secondary)
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
