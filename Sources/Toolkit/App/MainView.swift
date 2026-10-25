import SwiftUI

/// A sidebar row as System Settings has them: a small coloured tile, then the
/// name. A tool that's off is greyed, as on Overview; one that's on without a
/// permission it can't work without has a warning at the end.
private struct SidebarRow: View {
    let section: AppSection
    var on = true
    var needs: [PermissionNeed] = []
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        // Not a Label: its icon slot is sized for a sidebar's small symbols,
        // and a 22 pt tile filled it to the text.
        HStack(spacing: 8) {
            if section == .welcome {
                KitIcon(size: 22)
            } else {
                // Grey rather than `.saturation(0)`, a filter that `--snapshot`
                // images leave out.
                IconTile(symbol: section.symbol, color: on ? section.color : .gray, size: 22)
                    .opacity(on ? 1 : 0.6)
            }
            Text(section.title)
                .foregroundStyle(on ? .primary : .secondary)
            if on, !permissions.ready(needs) {
                Spacer(minLength: 4)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Missing a permission it needs to work")
                    .accessibilityLabel(Text("Missing a permission it needs to work"))
            }
        }
        .padding(.vertical, 2)
    }
}

/// The sidebar while searching, as System Settings has it: a row for each
/// page or setting found, with the page's icon, the setting's name, and
/// under it where it is.
private struct SearchResults: View {
    let hits: [SettingsIndex.Hit]
    let enabled: (AppSection) -> Bool
    let open: (AppSection, SettingsEntry?) -> Void

    var body: some View {
        if hits.isEmpty {
            ContentUnavailableView.search
        } else {
            List(hits) { hit in
                Button { open(hit.section, hit.entry) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        // Grey rather than `.saturation(0)`, as in the sidebar.
                        IconTile(symbol: hit.section.symbol, color: enabled(hit.section) ? hit.section.color : .gray, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            // Wrapped rather than cut, as System Settings does.
                            Text(hit.entry?.shown ?? LocalizedStringResource(stringLiteral: hit.section.title))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            if let place = place(of: hit) {
                                Text(verbatim: place)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    /// Where a setting is: its page, and a mouse's own page under Mouse; for
    /// a page, what it does.
    private func place(of hit: SettingsIndex.Hit) -> String? {
        guard let entry = hit.entry else {
            return hit.section.summary.isEmpty ? nil : hit.section.summary
        }
        return entry.perMouse ? "\(hit.section.title) → \(String(localized: "Mouse Settings"))" : hit.section.title
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController
    @ObservedObject var switcher: SwitcherController
    @ObservedObject var layout: LayoutController
    @ObservedObject var mixer: MixerController
    @ObservedObject var finder: FinderController
    @ObservedObject var capture: CaptureController
    @ObservedObject var awake: AwakeController
    @ObservedObject var stats: StatsController

    /// Whether a tool is on, for its tile on Overview and its sidebar row.
    private func enabled(_ section: AppSection) -> Bool {
        switch section {
        case .mouse: return mouse.config.enabled
        case .switcher: return switcher.config.enabled
        case .layout: return layout.config.enabled
        case .mixer: return mixer.config.enabled
        case .finder: return finder.config.enabled
        case .capture: return capture.config.enabled
        case .awake: return awake.config.enabled
        case .stats: return stats.config.enabled
        case .welcome, .general, .permissions, .about, .tweaks: return true
        }
    }

    @StateObject private var navigator = Navigator()
    @StateObject private var swipes = SwipeNavigation()
    @StateObject private var query = ViewState(MainView.previewSearch)
    /// For `--snapshot … search=<words>`: the window as that search shows it.
    static var previewSearch = ""

    /// What's shown: the section, and on Mouse the mouse whose page is open.
    private var place: Place {
        let section = model.section ?? .welcome
        return Place(section: section, mouse: section == .mouse ? mouse.openID : nil)
    }

    /// The section's name, beside back and forward; on a mouse's page, what
    /// the page is, as its card names the mouse. Only when that page is what
    /// shows: with the mouse gone, or the tool off, Mouse shows its list.
    private var title: String {
        guard let id = place.mouse, mouse.config.enabled, mouse.devices.contains(where: { $0.id == id }) else {
            return place.section.title
        }
        return String(localized: "Mouse Settings")
    }

    /// For `--snapshot`: the sidebar, search field and toolbar drawn by the
    /// page rather than as glass, which only the window server draws, so the
    /// image is made without the window ever being shown.
    static var drawnChrome = false

    var body: some View {
        Group {
            if Self.drawnChrome {
                drawnWindow
            } else {
                window
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            Permissions.shared.refresh()
            navigator.moved(to: place)
            swipes.start(back: goBack, forward: goForward)
        }
        .onDisappear { swipes.stop() }
        .onChange(of: place) { _, place in
            navigator.moved(to: place)
            // Each page shows them as they are now: macOS says nothing when
            // one changes.
            Permissions.shared.refresh()
        }
        .sheet(item: $model.askingPermissions) { section in
            PermissionsSheet(section: section, needs: model.permissionNeeds(section), restartNeeded: { model.restartNeeded(section) }) {
                model.askingPermissions = nil
            }
        }
    }

    /// As System Settings: the sidebar runs the window's full height, and
    /// the toolbar over the page has back, forward and the page's title.
    private var window: some View {
        NavigationSplitView {
            sidebar
                // Wide enough for the longest name, in Portuguese too. The column
                // width alone isn't kept in a window that isn't a SwiftUI scene.
                .frame(minWidth: 230)
                .navigationSplitViewColumnWidth(230)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button(action: goBack) { Image(systemName: "chevron.left") }
                            .help("Back")
                            .keyboardShortcut("[", modifiers: .command)
                            .disabled(navigator.back.isEmpty)
                        Button(action: goForward) { Image(systemName: "chevron.right") }
                            .help("Forward")
                            .keyboardShortcut("]", modifiers: .command)
                            .disabled(navigator.forward.isEmpty)
                    }
                }
        }
        // As in System Settings, at the top of the sidebar.
        .searchable(text: $query.value, placement: .sidebar, prompt: Text("Search"))
        .navigationTitle(title)
        // A window that isn't a SwiftUI scene doesn't take the title from it,
        // so it's set here; the toolbar shows it beside back and forward.
        .background(WindowTitle(title: title))
    }

    /// The same window for `--snapshot`, with the glass parts drawn plainly.
    private var drawnWindow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                // Room for the window's buttons.
                Color.clear.frame(height: 38)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    if query.value.isEmpty {
                        Text("Search").foregroundStyle(.tertiary)
                    } else {
                        Text(verbatim: query.value)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .padding(.horizontal, 10)
                if query.value.trimmingCharacters(in: .whitespaces).isEmpty {
                    drawnSections
                } else {
                    sidebar.scrollContentBackground(.hidden)
                }
            }
            .frame(width: 230)
            .background(Color.primary.opacity(0.035))
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    HStack(spacing: 0) {
                        Image(systemName: "chevron.left").frame(width: 34, height: 30)
                        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 16)
                        Image(systemName: "chevron.right").frame(width: 34, height: 30)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    Text(verbatim: title).font(.title3.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                detail
            }
        }
        // Up to the window's top edge, under its buttons, as the real one.
        .ignoresSafeArea()
    }

    /// The sidebar's rows for `--snapshot`, the one shown lit in grey: a list's
    /// selection in a window that isn't active is drawn black.
    private var drawnSections: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([AppSection.welcome, .general, .permissions, .about], id: \.self) { drawnRow($0) }
            Text("Tools")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 2)
                .padding(.leading, 18)
            ForEach(AppSection.tools) { drawnRow($0) }
            Text("System")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 2)
                .padding(.leading, 18)
            ForEach(AppSection.system) { drawnRow($0) }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func drawnRow(_ section: AppSection) -> some View {
        SidebarRow(section: section, on: enabled(section), needs: model.permissionNeeds(section))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(place.section == section ? Color.primary.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
    }

    private var sidebar: some View {
        Group {
            if query.value.trimmingCharacters(in: .whitespaces).isEmpty {
                sections
            } else {
                SearchResults(hits: SettingsIndex.search(query.value), enabled: enabled, open: open)
            }
        }
    }

    private var detail: some View {
        Group {
            switch place.section {
            case .welcome: WelcomeView(model: model, enabled: enabled,
                                        switcherShortcut: switcher.config.shortcut.active?.display ?? "⌘Tab")
            case .mouse: MouseSettingsView(mouse: mouse)
            case .switcher: SwitcherSettingsView(switcher: switcher, mouse: mouse)
            case .layout: LayoutSettingsView(layout: layout, mouse: mouse)
            case .mixer: MixerSettingsView(mixer: mixer)
            case .finder: FinderSettingsView(finder: finder, mouse: mouse)
            case .capture: CaptureSettingsView(capture: capture)
            case .awake: AwakeSettingsView(awake: awake, mouse: mouse)
            case .stats: StatsSettingsView(stats: stats)
            case .permissions: PermissionsView()
            case .about: AboutView(model: model)
            case .general: GeneralView(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture, awake: awake, stats: stats)
            case .tweaks: TweaksView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.pageGoTo, $model.goTo)
        // A link in a page's text to another page, `toolkit-page:<section>`,
        // or to a setting on it, `toolkit-page:<section>#<title>`; through
        // the same history as the sidebar.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "toolkit-page", let section = AppSection(rawValue: url.path(percentEncoded: false)) else { return .systemAction }
            open(section, nil)
            model.goTo = url.fragment(percentEncoded: false)
            return .handled
        })
        .environment(\.toolTurnedOn) { model.turnedOn($0) }
    }

    /// Overview and the app's own settings, then the tools, then System.
    private var sections: some View {
        List(selection: $model.section) {
            SidebarRow(section: .welcome).tag(AppSection.welcome)
            SidebarRow(section: .general).tag(AppSection.general)
            SidebarRow(section: .permissions).tag(AppSection.permissions)
            SidebarRow(section: .about).tag(AppSection.about)
            // A header of its own rather than a section's: a sidebar section
            // hides its rows on a click of its header and shows an arrow for
            // it, and these are the tools themselves, nothing to tidy away.
            Text("Tools")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.leading, -2)
                .selectionDisabled()
            ForEach(AppSection.tools) { SidebarRow(section: $0, on: enabled($0), needs: model.permissionNeeds($0)).tag($0) }
            // macOS's own settings: apart from the tools, which the toolkit does.
            Text("System")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.leading, -2)
                .selectionDisabled()
            ForEach(AppSection.system) { SidebarRow(section: $0).tag($0) }
        }
        .listStyle(.sidebar)
    }

    /// A page from the search, at the setting if one was picked. One that's
    /// on a mouse's own page opens the mouse already open, or the first
    /// connected one.
    private func open(_ section: AppSection, _ entry: SettingsEntry?) {
        if section == .mouse {
            if entry?.perMouse == true {
                let shown = mouse.openID.flatMap { id in mouse.devices.first { $0.id == id } }
                mouse.openID = (shown ?? mouse.devices.first(where: \.connected) ?? mouse.devices.first)?.id
            } else {
                mouse.openID = nil
            }
        }
        // The tab first, so the setting is on the page to go to.
        if let tab = entry?.tab.flatMap(LayoutPage.init(rawValue:)) { layout.page = tab }
        model.section = section
        model.goTo = entry?.anchor
    }

    private func goBack() {
        if let place = navigator.goBack() { go(to: place) }
    }

    private func goForward() {
        if let place = navigator.goForward() { go(to: place) }
    }

    /// The mouse first: the Mouse page shows whichever is open as it appears.
    private func go(to place: Place) {
        mouse.openID = place.mouse
        model.section = place.section
    }
}

private struct GeneralView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mouse: MouseController
    let switcher: SwitcherController
    let layout: LayoutController
    @ObservedObject var mixer: MixerController
    let finder: FinderController
    @ObservedObject var capture: CaptureController
    @ObservedObject var awake: AwakeController
    @ObservedObject var stats: StatsController

    /// Masculine in Portuguese, for a separator, unlike a gap's None.
    private static var noSeparator: LocalizedStringKey {
        .verbatim(String(localized: "Separator.none", defaultValue: "None", comment: "No separator; masculine in Portuguese, unlike a gap's None"))
    }

    /// Whether the tool has a part in the menu bar, as `updateMenuBar` decides.
    /// System Stats lives only there, so its switch is the tool's own.
    private func place(_ tool: MenuBarTool) -> MenuBarOrderList.Place {
        switch tool {
        case .toolkit: return .always
        case .stats: return .shown(stats.config.enabled && !stats.config.shown.isEmpty)
        case .capture: return capture.config.enabled ? .shown(capture.config.standaloneIcon) : .toolOff
        case .awake: return awake.config.enabled ? .shown(awake.config.inMenuBar) : .toolOff
        case .mixer: return mixer.config.enabled ? .shown(mixer.config.inMenuBar) : .toolOff
        case .mouse: return mouse.config.enabled ? .shown(mouse.config.menuBarIcon) : .toolOff
        case .layout: return layout.config.enabled ? .shown(layout.config.menuBarIcon) : .toolOff
        }
    }

    /// Back from none, a tool gets the look it had; the look is picked on its page.
    private func setShown(_ tool: MenuBarTool, _ shown: Bool) {
        switch tool {
        case .toolkit: break
        case .stats:
            stats.config.enabled = shown
            if shown, stats.config.shown.isEmpty {
                stats.config.set(.cpu) { $0.shown = true }
                stats.config.set(.memory) { $0.shown = true }
            }
        case .capture: capture.config.standaloneIcon = shown
        case .awake: awake.config.inMenuBar = shown
        case .mixer: mixer.config.inMenuBar = shown
        case .mouse: mouse.config.menuBarIcon = shown
        case .layout: layout.config.menuBarIcon = shown
        }
    }

    var body: some View {
        Page {
            PageHeader(section: .general, subtitle: "The app's own settings: startup, language, the menu bar and backups.")

            Card(title: "Startup") {
                ToggleRow(title: "Launch at login",
                          caption: "Start in the menu bar when you log in.",
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }

            Card(title: "Language") {
                OptionRow(title: "App language", caption: "Unless you pick one, the app is in the first of your languages in macOS that it has.",
                          selection: $model.general.language, options: AppLanguage.allCases.map { ($0, $0.title) }, menu: true) {
                    if model.general.language != AppLanguage.launched {
                        HStack {
                            Text("The app shows it after a restart.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Restart") { Relaunch.now() }
                        }
                    }
                }
            }

            Card(title: "Menu Bar") {
                SettingRow(title: "Space between items", caption: "Between the toolkit's parts in the menu bar. It changes as you drag.") {
                    EmptyView()
                } extra: {
                    ValueSlider(value: $model.general.menuBarSpacing, range: GeneralConfig.menuBarSpacings, step: 2,
                                low: "Tight", high: "Roomy", format: { "\(Int($0)) pt" })
                }
                RowDivider()
                OptionRow(title: "Separator", caption: "Between two tools in the menu bar.",
                          selection: $model.general.menuBarSeparator,
                          options: [(.none, Self.noSeparator), (.dot, "Dot"), (.pipe, "Line")])
                RowDivider()
                OptionRow(title: "Separator within a tool", caption: "Between one tool's own parts.",
                          selection: $model.general.menuBarToolSeparator,
                          options: [(.same, "Same"), (.none, Self.noSeparator), (.dot, "Dot"), (.pipe, "Line")])
                RowDivider()
                SettingRow(title: "Order", caption: "Left to right. Drag a tool to move it, and switch its place in the menu bar on or off; one that's off keeps its place.") {
                    Button("Default Order") { model.general.menuBarOrder = MenuBarTool.defaultOrder }
                        .disabled(model.general.menuBarOrder == MenuBarTool.defaultOrder)
                } extra: {
                    MenuBarOrderList(order: $model.general.menuBarOrder, place: place, setShown: setShown) { tool in
                        model.section = AppSection(rawValue: tool.rawValue) ?? .general
                    }
                }
            }

            Card(title: "Backup") {
                SettingRow(title: "Settings file", caption: "Save every setting to a file, or load them from one.") {
                    HStack(spacing: 8) {
                        Button("Export…") { SettingsTransfer.exportSettings(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture, awake: awake, stats: stats) }
                        Button("Import…") { SettingsTransfer.importSettings(model: model, mouse: mouse, switcher: switcher, layout: layout, mixer: mixer, finder: finder, capture: capture, awake: awake, stats: stats) }
                    }
                }
            }
        }
    }
}
