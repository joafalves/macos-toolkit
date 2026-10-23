import SwiftUI

/// A scrolling settings page with a centred, width-limited column. Linked
/// settings' badges scroll it to the row they name.
struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content
    /// A setting to go to as the page opens, from another page; cleared once there.
    var goTo: Binding<String?>?
    @StateObject private var focus = SettingFocus()

    init(goTo: Binding<String?>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.goTo = goTo
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content()
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                focus.scroll = { anchor in proxy.scrollTo(anchor, anchor: .center) }
                guard let goTo, let anchor = goTo.wrappedValue else { return }
                // Once the page is laid out, or there's nothing to scroll to.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) { focus.go(to: anchor) }
                    goTo.wrappedValue = nil
                }
            }
        }
        .environment(\.settingFocus, focus)
    }
}

/// A titled group of rows on a rounded panel.
struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    /// A word next to the title, like "Preview".
    var badge: LocalizedStringKey?
    var footnote: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    if let badge { TagBadge(text: badge) }
                }
                .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

/// Title and caption on the left, a control on the right, and optional
/// extra controls underneath. A link to another setting shows as a badge
/// under the caption, and when this one is held, its control is locked.
struct SettingRow<Control: View, Extra: View>: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    var link: SettingLink?
    /// A word next to the title, like "Preview".
    var badge: LocalizedStringKey?
    @ViewBuilder var control: () -> Control
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The control beside the text while the text keeps a readable
            // width, and under it when not: a wide control, or long words in
            // another language, would squeeze the text to a word a line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    label
                        .frame(minWidth: 0, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
                    lockedControl
                }
                VStack(alignment: .leading, spacing: 10) {
                    label
                    lockedControl
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            extra()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                if let badge { TagBadge(text: badge) }
            }
            if let caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link {
                LinkBadge(link: link)
                    .padding(.top, 5)
            }
        }
    }

    private var lockedControl: some View {
        control()
            .disabled(link?.locks == true)
    }
}

extension SettingRow where Extra == EmptyView {
    init(title: LocalizedStringKey, caption: LocalizedStringKey? = nil, link: SettingLink? = nil, badge: LocalizedStringKey? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, caption: caption, link: link, badge: badge, control: control, extra: { EmptyView() })
    }
}

/// A small coloured word next to a title, for something not finished yet.
struct TagBadge: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}

/// A setting with a segmented choice and optional extra controls underneath.
/// With `menu`, a pop-up instead: for long option names, or so many that the
/// segments would squeeze the caption.
struct OptionRow<Value: Hashable, Extra: View>: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    @Binding var selection: Value
    let options: [(Value, LocalizedStringKey)]
    var menu = false
    var link: SettingLink?
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        SettingRow(title: title, caption: caption, link: link) {
            if menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            } else {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } extra: {
            extra()
        }
    }
}

extension OptionRow {
    /// Options named by a model, already in the reader's words.
    @_disfavoredOverload
    init(title: LocalizedStringKey, caption: LocalizedStringKey? = nil, selection: Binding<Value>, options: [(Value, String)], menu: Bool = false,
         link: SettingLink? = nil, @ViewBuilder extra: @escaping () -> Extra) {
        self.init(title: title, caption: caption, selection: selection, options: options.map { ($0.0, LocalizedStringKey.verbatim($0.1)) },
                  menu: menu, link: link, extra: extra)
    }
}

extension OptionRow where Extra == EmptyView {
    @_disfavoredOverload
    init(title: LocalizedStringKey, caption: LocalizedStringKey? = nil, selection: Binding<Value>, options: [(Value, String)], menu: Bool = false, link: SettingLink? = nil) {
        self.init(title: title, caption: caption, selection: selection, options: options, menu: menu, link: link, extra: { EmptyView() })
    }

    init(title: LocalizedStringKey, caption: LocalizedStringKey? = nil, selection: Binding<Value>, options: [(Value, LocalizedStringKey)], menu: Bool = false, link: SettingLink? = nil) {
        self.init(title: title, caption: caption, selection: selection, options: options, menu: menu, link: link, extra: { EmptyView() })
    }
}

struct ToggleRow: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    @Binding var isOn: Bool
    var link: SettingLink?
    var badge: LocalizedStringKey?

    var body: some View {
        SettingRow(title: title, caption: caption, link: link, badge: badge) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// A slider with end labels and a readout of the current value.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var low: LocalizedStringKey
    var high: LocalizedStringKey
    let format: (Double) -> String

    /// Snaps to `step` without drawing a tick mark for every step.
    private var snapped: Binding<Double> {
        Binding(get: { value }, set: { value = ($0 / step).rounded() * step })
    }

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: snapped, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Text(low).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
            Text(format(value))
                .font(.callout.monospacedDigit())
                // One line at the badge's width: a longer word shrinks to fit.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 52)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

/// A tinted notice with an action, for things that need the user's attention.
struct Banner: View {
    let text: LocalizedStringKey
    let button: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.3)))
    }
}

/// The top of a tool's page: what the tool is, and the switch that turns it
/// on and off. The same on every tool, so "on" always looks the same.
struct ToolHeader: View {
    let section: AppSection
    var title: LocalizedStringKey?
    let subtitle: LocalizedStringKey
    @Binding var enabled: Bool

    private var name: Text { title.map { Text($0) } ?? Text(section.title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                // Grey rather than `.saturation(0)`, a filter `--snapshot` leaves out.
                IconTile(symbol: section.symbol, color: enabled ? section.color : .gray, size: 46)
                    .opacity(enabled ? 1 : 0.6)
                VStack(alignment: .leading, spacing: 3) {
                    name.font(.title2.weight(.semibold))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                // On and Off, as on Overview and in the menus.
                Text(enabled ? "On" : "Off")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(enabled ? Color.accentColor : .secondary)
                Toggle(enabled ? "On" : "Off", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.large)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(enabled ? section.color.opacity(0.09) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(enabled ? section.color.opacity(0.28) : Color.primary.opacity(0.08)))
            // What the faded settings below are waiting for.
            if !enabled {
                Text("Turn \(name) on to use these settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}

/// The top of a page that isn't a tool (Settings): the same look as a
/// tool's header, without the switch.
struct PageHeader: View {
    let section: AppSection
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: section.symbol, color: section.color, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.title2.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The rest of a tool's page, greyed out while the tool is off.
struct WhenEnabled<Content: View>: View {
    let enabled: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            content()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// A setting that's a shortcut, with a recorder on the right.
struct ShortcutRow: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    @Binding var shortcut: Shortcut
    let defaultValue: Shortcut
    var optional = true
    var taken: [Shortcut] = []

    var body: some View {
        SettingRow(title: title, caption: caption) {
            ShortcutRecorder(shortcut: $shortcut, defaultValue: defaultValue, optional: optional, taken: taken)
        }
    }
}

/// A rounded tile with a glyph, used at the top of a page.
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(.white))
            .shadow(color: .black.opacity(size < 30 ? 0.12 : 0.18), radius: size < 30 ? 1 : 3, y: size < 30 ? 0.5 : 1)
    }
}

/// The app icon, drawn: the bundle's icon isn't there for `--snapshot` runs.
/// Keep it in step with `scripts/make-icon.swift`.
struct KitIcon: View {
    var size: CGFloat = 52

    var body: some View {
        let side = size * 0.29, gap = size * 0.055
        let colors: [Color] = [Color(red: 0.30, green: 0.55, blue: 1.0), Color(red: 0.13, green: 0.76, blue: 0.65),
                               Color(red: 1.0, green: 0.62, blue: 0.18), Color(red: 0.69, green: 0.42, blue: 1.0)]
        RoundedRectangle(cornerRadius: size * 0.2245, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.21, blue: 0.31), Color(red: 0.08, green: 0.10, blue: 0.17)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                VStack(spacing: gap) {
                    ForEach(0..<2) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<2) { column in
                                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                                    .fill(colors[row * 2 + column].gradient)
                                    .frame(width: side, height: side)
                            }
                        }
                    }
                }
            )
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

/// Local view state for `@StateObject`. `@State` is a macro in the macOS 27
/// SDK, and the Command Line Tools ship without the plugin that expands it.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

extension LocalizedStringKey {
    /// Text already in the reader's words, or not words at all (a name, a
    /// figure): shown as it is, never looked up.
    static func verbatim(_ text: String) -> LocalizedStringKey { "\(text)" }
}
