import AppKit
import SwiftUI
import ServiceManagement

/// The pages of the main window: Overview, Settings (the app's own), About, and the tools.
enum AppSection: String, CaseIterable, Identifiable {
    case welcome, mouse, switcher, layout, mixer, finder, capture, awake, stats, general, about

    var id: String { rawValue }

    /// The tools by name, as the sidebar and the toolkit menu list them.
    static var tools: [AppSection] {
        allCases.filter { ![.welcome, .general, .about].contains($0) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var title: String {
        switch self {
        case .welcome: return String(localized: "Overview")
        case .mouse: return String(localized: "Mouse")
        case .switcher: return String(localized: "Window Switcher")
        case .layout: return String(localized: "Window Layout")
        case .mixer: return String(localized: "Audio Mixer")
        case .finder: return String(localized: "Finder")
        case .capture: return String(localized: "Screen Capture")
        case .awake: return String(localized: "Keep Awake")
        case .stats: return String(localized: "System Stats")
        // Stored as "general", as it was called before.
        case .general: return String(localized: "Settings")
        case .about: return String(localized: "About")
        }
    }

    /// The colour of its tile in the sidebar and at the top of its page.
    var color: Color {
        switch self {
        case .welcome: return .accentColor
        case .mouse: return .blue
        case .switcher: return .indigo
        case .layout: return .teal
        case .mixer: return .pink
        case .finder: return .cyan
        case .capture: return .orange
        case .awake: return .brown
        case .stats: return .green
        case .general: return .gray
        case .about: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "hand.wave"
        case .mouse: return "computermouse"
        case .switcher: return "macwindow.on.rectangle"
        case .layout: return "rectangle.split.2x2"
        case .mixer: return "slider.vertical.3"
        case .finder: return "folder"
        case .capture: return "camera.viewfinder"
        case .awake: return "cup.and.saucer.fill"
        case .stats: return "gauge.with.dots.needle.50percent"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }

    /// What it does, in a line, for its tile on Overview.
    var summary: String {
        switch self {
        case .welcome: return ""
        case .mouse: return String(localized: "Cursor and wheel settings for each mouse.")
        case .switcher: return String(localized: "⌘Tab through windows instead of apps.")
        case .layout: return String(localized: "Snap windows to halves, quarters, thirds or a grid.")
        case .mixer: return String(localized: "A volume for each app, and an equalizer.")
        case .finder: return String(localized: "Cut and paste files, and more in the right-click menu.")
        case .capture: return String(localized: "Screenshots and small screen recordings.")
        case .awake: return String(localized: "Keeps the Mac awake for as long as you need.")
        case .stats: return String(localized: "CPU, memory and more in the menu bar.")
        case .general, .about: return ""
        }
    }
}

final class AppModel: ObservableObject {
    /// Remembered, so the window opens where it was left.
    @Published var section: AppSection? = .welcome {
        didSet {
            guard persists, let section, section != oldValue else { return }
            UserDefaults.standard.set(section.rawValue, forKey: Self.lastSectionKey)
        }
    }
    /// A setting to scroll to and light up once its page shows.
    @Published var goTo: String?
    @Published var general = GeneralConfig.load() {
        didSet {
            guard general != oldValue, persists else { return }
            general.save()
        }
    }
    /// False for `--snapshot`, which shows the defaults.
    var persists = true
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Toolkit: launch at login failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static let lastSectionKey = "lastSection"
    private static let welcomedKey = "welcomedVersion"

    /// Where the window opens: Overview the first time and after an update,
    /// otherwise the page it was left on. Opening Overview counts as seen.
    func launchSection() -> AppSection {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.welcomedKey) != version {
            defaults.set(version, forKey: Self.welcomedKey)
            return .welcome
        }
        return defaults.string(forKey: Self.lastSectionKey).flatMap(AppSection.init) ?? .welcome
    }
}
