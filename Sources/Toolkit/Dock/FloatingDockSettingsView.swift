import SwiftUI
import UniformTypeIdentifiers

/// The "Floating Dock" section.
struct FloatingDockSettingsView: View {
    @ObservedObject var dock: FloatingDockController
    @ObservedObject var mouse: MouseController
    @ObservedObject private var permissions = Permissions.shared

    private var keys: [(LocalizedStringResource, LocalizedStringKey)] {
        [
            ("Bring an app forward", "point at it, let go"),
            ("One of its windows", "further out"),
            ("A new window of it", "⌥ as you let go, or right-click"),
            ("Into a folder, and back", "further out, then the centre"),
            ("Open apps, and what doesn't fit", "scroll"),
            ("An app by its letter", "the letter"),
            ("Search every app", "tab"),
            ("Close", "esc, or the centre"),
        ]
    }

    var body: some View {
        Page {
            ToolHeader(section: .dock, subtitle: "Your apps in a ring around the pointer. Point and let go to switch; further out for a window.",
                       enabled: $dock.config.enabled)

            if dock.config.enabled {
                if !permissions.isGranted(.accessibility) {
                    Banner(text: "The Floating Dock is not active yet. It needs the Accessibility permission to see its key and follow the pointer.",
                           button: "Grant Access…") { mouse.requestAccessibility() }
                } else if dock.tapFailed {
                    Banner(text: "Accessibility is granted, but the app has to restart before the Floating Dock takes effect.",
                           button: "Restart") { Relaunch.now() }
                }
            }

            WhenEnabled(enabled: dock.config.enabled && permissions.ready(dock.permissionNeeds)) {
                Card(title: "Opening", footnote: dock.config.opening == .press
                     ? "Point and let go to pick; let go in the centre to cancel. Wherever the ring opens, its pointer starts at the centre, and yours is back where it was when it closes."
                     : "The ring stays open for a click, an app's letter or Tab. Wherever the ring opens, its pointer starts at the centre, and yours is back where it was when it closes.") {
                    OptionRow(title: "Key", caption: "The right ⌘ on its own, or a shortcut.",
                              selection: $dock.config.trigger, options: [(.rightCommand, "Right ⌘"), (.shortcut, "A shortcut")])
                    RowDivider()
                    OptionRow(title: "Opens", caption: dock.config.opening == .press
                              ? "As the key or button goes down, for as long as it's held."
                              : "As the key or button goes up, until a pick or a second press.",
                              selection: $dock.config.opening, options: [(.press, "Press"), (.toggle, "Toggle")])
                    if dock.config.trigger == .shortcut {
                        RowDivider()
                        ShortcutRow(title: "Shortcut", shortcut: $dock.config.shortcut,
                                    defaultValue: FloatingDockConfig().shortcut, optional: false)
                    } else if dock.config.opening == .toggle {
                        RowDivider()
                        ToggleRow(title: "Right ⌘ and an app's letter",
                                  caption: "Brings that app forward at once, without the ring; with ⌥ too, a new window of it. Other keys with the right ⌘ are ⌘ shortcuts as ever.",
                                  isOn: $dock.config.quickLetters)
                    }
                    RowDivider()
                    SettingRow(title: "Mouse button", caption: "Give one of the mouse's buttons the Floating Dock action on the Mouse page.") {
                        Link("Mouse", destination: URL(string: "toolkit-page:mouse")!)
                    }
                }

                Card(title: "Apps") {
                    OptionRow(title: "Apps from", selection: $dock.config.source,
                              options: [(.dock, "The Dock"), (.manual, "My own list")])
                    RowDivider()
                    SettingRow(title: "Places on the ring", caption: "Fewer are easier to hit without looking.") {
                        Stepper(value: $dock.config.slots, in: FloatingDockConfig.slotRange) {
                            Text(verbatim: "\(dock.config.slots)").monospacedDigit()
                        }
                        .fixedSize()
                    }
                    RowDivider()
                    OptionRow(title: "Apps that don't fit", selection: $dock.config.overflow,
                              options: [(.moreSlot, "In the last place, as a folder"), (.moreLayer, "On a layer of their own")], menu: true)
                    RowDivider()
                    DockAppsEditor(config: $dock.config)
                }

                Card(title: "While it's open", footnote: "Apps that are open but not on the ring are on the next layer, most recent first.") {
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                        if index > 0 { RowDivider() }
                        SettingRow(title: key.0) {
                            Text(key.1).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// The apps on the ring and their letters: the Dock's, to read, or a list of
/// one's own with folders, made here.
private struct DockAppsEditor: View {
    @Binding var config: FloatingDockConfig
    @StateObject private var dockApps = ViewState<[DockApp]>([])

    private var letters: [String: String] {
        DockRings.letters(for: DockRings.apps(in: config.source == .dock ? dockApps.value.map { .app($0) } : config.items), chosen: config.letters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if config.source == .dock {
                Text("In the Dock's order: change it in the Dock. Folders need your own list.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                ForEach(dockApps.value, id: \.path) { app in
                    AppLine(app: app, letter: letterBinding(app), placeholder: letters[app.path])
                }
            } else {
                ForEach(Array(config.items.enumerated()), id: \.element.id) { index, entry in
                    switch entry {
                    case .app(let app):
                        AppLine(app: app, letter: letterBinding(app), placeholder: letters[app.path]) {
                            controls(index)
                            Menu {
                                ForEach(folders) { folder in
                                    Button(folder.name) { move(app, from: index, to: folder.id) }
                                }
                            } label: { Image(systemName: "folder") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .disabled(folders.isEmpty)
                            .help("Move into a folder")
                        }
                    case .folder(let folder):
                        FolderLines(folder: folderBinding(index, folder), letters: letters, letter: letterBinding) {
                            controls(index)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Add App…") { addApps() }
                    Button("New Folder") { config.items.append(.folder(DockFolder(name: String(localized: "Folder")))) }
                    Spacer()
                    Button("Copy from the Dock") { config.items = DockRings.dockApps().map { .app($0) } }
                        .help("Replaces this list with the Dock's apps, once: it doesn't follow the Dock afterwards.")
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
        }
        .onAppear { dockApps.value = DockRings.dockApps() }
    }

    private var folders: [DockFolder] {
        config.items.compactMap { if case .folder(let folder) = $0 { return folder } else { return nil } }
    }

    @ViewBuilder
    private func controls(_ index: Int) -> some View {
        Button { swap(index, index - 1) } label: { Image(systemName: "chevron.up") }
            .buttonStyle(.borderless).disabled(index == 0).help("Move up")
        Button { swap(index, index + 1) } label: { Image(systemName: "chevron.down") }
            .buttonStyle(.borderless).disabled(index == config.items.count - 1).help("Move down")
        Button { config.items.remove(at: index) } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless).help("Remove")
    }

    private func swap(_ a: Int, _ b: Int) {
        guard config.items.indices.contains(a), config.items.indices.contains(b) else { return }
        config.items.swapAt(a, b)
    }

    private func move(_ app: DockApp, from index: Int, to folder: UUID) {
        guard let target = config.items.firstIndex(where: { if case .folder(let f) = $0 { return f.id == folder } else { return false } }),
              case .folder(var f) = config.items[target] else { return }
        f.apps.append(app)
        config.items[target] = .folder(f)
        config.items.remove(at: index)
    }

    private func folderBinding(_ index: Int, _ folder: DockFolder) -> Binding<DockFolder> {
        Binding(get: { folder }, set: { new in
            guard config.items.indices.contains(index) else { return }
            config.items[index] = .folder(new)
        })
    }

    private func letterBinding(_ app: DockApp) -> Binding<String> {
        Binding(get: { config.letters[app.path] ?? "" }, set: { text in
            let letter = text.folding(options: .diacriticInsensitive, locale: nil).lowercased().filter { $0.isLetter && $0.isASCII }.suffix(1)
            config.letters[app.path] = letter.isEmpty ? nil : String(letter)
        })
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let have = Set(DockRings.apps(in: config.items).map(\.path))
        config.items += panel.urls.compactMap(DockApp.init(url:)).filter { !have.contains($0.path) }.map { .app($0) }
    }
}

/// An app's line: its icon and name, the letter (empty for the one from its name), and controls.
private struct AppLine<Controls: View>: View {
    let app: DockApp
    @Binding var letter: String
    let placeholder: String?
    var indent: CGFloat = 0
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: DockRings.icon(app)).resizable().frame(width: 22, height: 22)
            Text(verbatim: app.name).lineLimit(1)
            Spacer(minLength: 8)
            TextField(text: $letter, prompt: Text(verbatim: (placeholder ?? "").uppercased())) { Text("Letter") }
                .labelsHidden()
                .multilineTextAlignment(.center)
                .frame(width: 30)
                .help("The letter that opens it while the ring is open")
            controls()
        }
        .padding(.leading, 14 + indent).padding(.trailing, 14).padding(.vertical, 5)
    }
}

extension AppLine where Controls == EmptyView {
    init(app: DockApp, letter: Binding<String>, placeholder: String?) {
        self.init(app: app, letter: letter, placeholder: placeholder, controls: { EmptyView() })
    }
}

private struct FolderLines<Controls: View>: View {
    @Binding var folder: DockFolder
    let letters: [String: String]
    let letter: (DockApp) -> Binding<String>
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary).frame(width: 22)
                TextField("Name", text: $folder.name).textFieldStyle(.plain).fontWeight(.medium)
                Spacer(minLength: 8)
                controls()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            if folder.apps.isEmpty {
                Text("Empty: move apps into it with the folder button on their line.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.leading, 46).padding(.bottom, 6)
            }
            ForEach(Array(folder.apps.enumerated()), id: \.element.path) { index, app in
                AppLine(app: app, letter: letter(app), placeholder: letters[app.path], indent: 32) {
                    Button { folder.apps.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove")
                }
            }
        }
    }
}
