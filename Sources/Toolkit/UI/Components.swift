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
    var title: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
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
    let title: String
    var caption: String?
    var link: SettingLink?
    @ViewBuilder var control: () -> Control
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
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
                Spacer(minLength: 0)
                control()
                    .disabled(link?.locks == true)
            }
            extra()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

extension SettingRow where Extra == EmptyView {
    init(title: String, caption: String? = nil, link: SettingLink? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, caption: caption, link: link, control: control, extra: { EmptyView() })
    }
}

/// A setting with a segmented choice and optional extra controls underneath.
struct OptionRow<Value: Hashable, Extra: View>: View {
    let title: String
    var caption: String?
    @Binding var selection: Value
    let options: [(Value, String)]
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        SettingRow(title: title, caption: caption) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } extra: {
            extra()
        }
    }
}

extension OptionRow where Extra == EmptyView {
    init(title: String, caption: String? = nil, selection: Binding<Value>, options: [(Value, String)]) {
        self.init(title: title, caption: caption, selection: selection, options: options, extra: { EmptyView() })
    }
}

struct ToggleRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool
    var link: SettingLink?

    var body: some View {
        SettingRow(title: title, caption: caption, link: link) {
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
    var low: String
    var high: String
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
                .frame(width: 52)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

/// A tinted notice with an action, for things that need the user's attention.
struct Banner: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(text)
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
    var title: String?
    let subtitle: String
    @Binding var enabled: Bool

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: section.symbol, color: section.color, size: 46)
                .saturation(enabled ? 1 : 0)
                .opacity(enabled ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? section.title).font(.title2.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(enabled ? "Enabled" : "Off")
                .font(.callout.weight(.medium))
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
            Toggle("Enabled", isOn: $enabled)
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
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}

/// The top of a page that isn't a tool (Settings): the same look as a
/// tool's header, without the switch.
struct PageHeader: View {
    let section: AppSection
    let subtitle: String

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
    let title: String
    var caption: String?
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
