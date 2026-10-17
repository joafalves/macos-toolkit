import SwiftUI

/// A scrolling settings page with a centred, width-limited column.
struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
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
/// extra controls underneath.
struct SettingRow<Control: View, Extra: View>: View {
    let title: String
    var caption: String?
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
                }
                Spacer(minLength: 0)
                control()
            }
            extra()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

extension SettingRow where Extra == EmptyView {
    init(title: String, caption: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, caption: caption, control: control, extra: { EmptyView() })
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

    var body: some View {
        SettingRow(title: title, caption: caption) {
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

/// A rounded tile with a glyph, used at the top of a page.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

/// Local view state for `@StateObject`. `@State` is a macro in the macOS 27
/// SDK, and the Command Line Tools ship without the plugin that expands it.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
