import SwiftUI

/// What a tool just turned on needs from macOS, one permission at a time: the
/// button asks for the next one missing, with macOS's own prompt or, once
/// that's been answered, its list in System Settings. Each turns green as
/// it's granted. One that only works after a restart (Screen Recording, or a
/// tap macOS refused until then) ends with the app restarting itself, rather
/// than counting on macOS's own Quit & Reopen.
struct PermissionsSheet: View {
    let section: AppSection
    let needs: [PermissionNeed]
    /// Asked again on each refresh: the tool's taps aren't published here.
    let restartNeeded: () -> Bool
    let close: () -> Void
    @ObservedObject var permissions = Permissions.shared

    private var next: PermissionNeed? {
        needs.first { ![.granted, .needsRestart].contains(permissions.state($0.permission)) }
    }

    private var restart: Bool {
        needs.contains { permissions.state($0.permission) == .needsRestart } || restartNeeded()
    }

    private var subtitle: LocalizedStringKey {
        if next != nil { return "To work fully, it needs these permissions from macOS." }
        if restart { return "Granted. MacOS Toolkit has to restart to start using them." }
        return "It has every permission it needs."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: section.symbol, color: section.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: section.title).font(.title3.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !needs.isEmpty {
            VStack(spacing: 0) {
                ForEach(needs) { need in
                    if need.id != needs.first?.id { Divider() }
                    row(need)
                }
            }
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }

            Text("macOS asks for each one, or opens System Settings, where you turn on MacOS Toolkit. They're also on the Permissions page, where they can be revoked.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if let next {
                    Button("Not Now", action: close)
                        .keyboardShortcut(.cancelAction)
                    Button(permissions.state(next.permission) == .denied ? "Open System Settings…" : "Grant Access…") {
                        permissions.request(next.permission)
                    }
                    .keyboardShortcut(.defaultAction)
                } else if restart {
                    Button("Later", action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("Restart") { Relaunch.now() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { permissions.watch(true) }
        .onDisappear { permissions.watch(false) }
    }

    private func row(_ need: PermissionNeed) -> some View {
        let granted = permissions.isGranted(need.permission)
        let waiting = permissions.state(need.permission) == .needsRestart
        let current = need.id == next?.id
        return HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : waiting ? "arrow.clockwise.circle.fill" : current ? "arrow.right.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(granted ? Color.green : waiting ? Color.orange : current ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: need.permission.title)
                    // Skipping it leaves the tool working, without that feature.
                    if !need.required { TagBadge(text: "Optional") }
                }
                Text(verbatim: need.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text("Granted").font(.callout).foregroundStyle(.green)
            } else if waiting {
                Text("After a restart").font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 9)
    }
}

/// A permission's state on the Permissions list: granted, with a way to
/// take it back, or a button to ask for it.
struct PermissionControl: View {
    let permission: Permission
    @ObservedObject var permissions = Permissions.shared

    var body: some View {
        if permissions.isGranted(permission) {
            HStack(spacing: 10) {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Revoke…") { permissions.revoke(permission) }
            }
        } else if permissions.state(permission) == .needsRestart {
            HStack(spacing: 10) {
                Label("After a restart", systemImage: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                Button("Restart") { Relaunch.now() }
            }
        } else {
            Button(permissions.state(permission) == .denied ? "Open System Settings…" : "Grant Access…") {
                permissions.request(permission)
            }
        }
    }
}

/// Off while there's nothing granted to revoke.
struct RevokeAllButton: View {
    @ObservedObject var permissions = Permissions.shared

    var body: some View {
        Button("Revoke All…") { permissions.revokeAll() }
            .disabled(!Permission.allCases.contains { [.granted, .needsRestart].contains(permissions.state($0)) })
    }
}

private struct ToolTurnedOnKey: EnvironmentKey {
    static let defaultValue: (AppSection) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Called when a tool's own switch turns it on, to ask for what it needs.
    var toolTurnedOn: (AppSection) -> Void {
        get { self[ToolTurnedOnKey.self] }
        set { self[ToolTurnedOnKey.self] = newValue }
    }
}
