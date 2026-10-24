import SwiftUI

/// Settings that depend on each other. One setting holds another: while the
/// holder is on, the held one is fixed and its control locked. Both rows say
/// so with a badge naming the other, and clicking the badge goes to it.
///
/// A link is only passed while it's in force. The held row gets
/// `.heldBy(...)`, which locks its control; the holder gets `.holds(...)`.
/// Each row is marked with `.settingAnchor(_:)` so the other can find it.
struct SettingLink {
    enum Role { case holds, heldBy }

    let role: Role
    /// What the badge says.
    let text: LocalizedStringKey
    /// The other row's anchor on the page.
    let anchor: String

    /// The held row: "On while Stay available is on".
    static func heldBy(_ text: LocalizedStringKey, anchor: String) -> SettingLink {
        SettingLink(role: .heldBy, text: text, anchor: anchor)
    }

    /// The holding row: "Keeps the display on".
    static func holds(_ text: LocalizedStringKey, anchor: String) -> SettingLink {
        SettingLink(role: .holds, text: text, anchor: anchor)
    }

    /// Whether the row's own control is locked.
    var locks: Bool { role == .heldBy }
}

/// Where a page's rows are, for a link to scroll to one and light it up.
final class SettingFocus: ObservableObject {
    @Published private(set) var lit: String?
    var scroll: ((String) -> Void)?
    private var clear: DispatchWorkItem?

    func go(to anchor: String) {
        scroll?(anchor)
        lit = anchor
        clear?.cancel()
        let clear = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.6)) { self?.lit = nil }
        }
        self.clear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: clear)
    }
}

private struct SettingFocusKey: EnvironmentKey {
    static let defaultValue: SettingFocus? = nil
}

extension EnvironmentValues {
    var settingFocus: SettingFocus? {
        get { self[SettingFocusKey.self] }
        set { self[SettingFocusKey.self] = newValue }
    }
}

extension View {
    /// Marks a row so a linked setting's badge can go to it.
    func settingAnchor(_ id: String) -> some View {
        modifier(SettingAnchor(id: id))
    }
}

private struct SettingAnchor: ViewModifier {
    let id: String
    @Environment(\.settingFocus) private var focus

    func body(content: Content) -> some View {
        content
            .background { if let focus { AnchorGlow(focus: focus, id: id) } }
            .id(id)
    }
}

/// The row lit up for a moment when a link lands on it.
private struct AnchorGlow: View {
    @ObservedObject var focus: SettingFocus
    let id: String

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(focus.lit == id ? 0.16 : 0))
    }
}

/// The badge under a linked row's caption: a lock on the held one, a link on
/// the holder, both in the accent colour so they read as a pair.
struct LinkBadge: View {
    let link: SettingLink
    @Environment(\.settingFocus) private var focus

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { focus?.go(to: link.anchor) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: link.role == .heldBy ? "lock.fill" : "link")
                    .font(.system(size: 9, weight: .bold))
                Text(link.text)
                    .font(.caption.weight(.medium))
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Go to the linked setting")
        .pointerStyle(.link)
    }
}
