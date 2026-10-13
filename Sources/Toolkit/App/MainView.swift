import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch model.section ?? .mouse {
            case .mouse: MouseSettingsView(mouse: mouse)
            case .general: GeneralView(model: model, mouse: mouse)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

private struct GeneralView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if mouse.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { mouse.requestAccessibility() }
                    }
                }
                Text("Used by Mouse Settings for wheel direction, speed and smoothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
