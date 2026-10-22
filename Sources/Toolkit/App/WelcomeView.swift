import SwiftUI

/// The front page: what the toolkit is, its version, a tile for each tool
/// with whether it's on, and a warning only while a permission a tool needs
/// is missing, which leads to the list of them in Settings.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController
    @ObservedObject var mixer: MixerController
    @ObservedObject var capture: CaptureController
    let enabled: (AppSection) -> Bool
    /// The switcher's real shortcut, which may not be ⌘Tab.
    let switcherShortcut: String

    static let permissionsAnchor = "general.permissions"

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The permissions that an enabled tool needs and doesn't have.
    private var missing: [String] {
        var missing: [String] = []
        let needsAccess: [AppSection] = [.mouse, .switcher, .layout, .finder]
        if !mouse.accessibilityGranted, needsAccess.contains(where: enabled) { missing.append("Accessibility") }
        if enabled(.capture), !capture.screenPermission { missing.append("Screen Recording") }
        if enabled(.mixer), mixer.permission != .granted { missing.append("System Audio Recording") }
        return missing
    }

    var body: some View {
        Page {
            HStack(spacing: 16) {
                KitIcon(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacOS Toolkit").font(.largeTitle.weight(.semibold))
                    Text("The little things macOS never shipped, in one menu bar app.")
                        .foregroundStyle(.secondary)
                    Text("Version \(version)").font(.subheadline).foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 4)

            if !missing.isEmpty {
                Banner(text: "Missing: \(ListFormatter.localizedString(byJoining: missing)). The tools that need it won't work fully until it's granted.",
                       button: "Permissions…") {
                    model.goTo = Self.permissionsAnchor
                    model.section = .general
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tools").font(.headline).padding(.leading, 2)
                // A new install has every tool off: say what to do about it.
                if !AppSection.tools.contains(where: enabled) {
                    Text("Every tool starts off. Open one to see what it does, and turn it on there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                        .padding(.bottom, 2)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(AppSection.tools) { section in
                        ToolTile(section: section, on: enabled(section), summary: summary(section)) { model.section = section }
                    }
                }
            }

            Text("Each tool is turned on and off on its page. Tools that are on are also in the toolkit's menu in the menu bar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }
}

private extension WelcomeView {
    func summary(_ section: AppSection) -> String {
        section == .switcher ? "\(switcherShortcut) through windows instead of apps." : section.summary
    }
}

/// A tool at a glance: its tile, name and what it does, and whether it's on.
private struct ToolTile: View {
    let section: AppSection
    let on: Bool
    let summary: String
    let open: () -> Void
    @StateObject private var hovered = ViewState(false)

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                // Grey rather than `.saturation(0)`, a filter `--snapshot` leaves out.
                IconTile(symbol: section.symbol, color: on ? section.color : .gray, size: 38)
                    .opacity(on ? 1 : 0.6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(section.title).font(.body.weight(.semibold))
                        Spacer(minLength: 4)
                        // The same for every tool, so on and off read at a glance.
                        Text(on ? "On" : "Off")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(on ? Color.green : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((on ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
                    }
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(Color.primary.opacity(hovered.value ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }
}
