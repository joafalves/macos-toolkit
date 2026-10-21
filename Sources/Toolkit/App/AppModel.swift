import AppKit
import SwiftUI
import ServiceManagement

/// The pages of the main window: Welcome, Settings (the app's own), and the tools.
enum AppSection: String, CaseIterable, Identifiable {
    case welcome, mouse, switcher, layout, mixer, finder, capture, awake, stats, general

    var id: String { rawValue }

    /// The tools by name, as the sidebar and the toolkit menu list them.
    static var tools: [AppSection] {
        allCases.filter { $0 != .welcome && $0 != .general }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .mouse: return "Mouse"
        case .switcher: return "Window Switcher"
        case .layout: return "Window Layout"
        case .mixer: return "Audio Mixer"
        case .finder: return "Finder"
        case .capture: return "Screen Capture"
        case .awake: return "Keep Awake"
        case .stats: return "System Stats"
        // Stored as "general", as it was called before.
        case .general: return "Settings"
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
        }
    }

    /// What it does, in a line, for its tile on Welcome.
    var summary: String {
        switch self {
        case .welcome: return ""
        case .mouse: return "Cursor and wheel settings for each mouse."
        case .switcher: return "⌘Tab through windows instead of apps."
        case .layout: return "Snap windows to halves, thirds or a grid."
        case .mixer: return "A volume for each app, and an equalizer."
        case .finder: return "Cut and paste files, and more in the right-click menu."
        case .capture: return "Screenshots and small screen recordings."
        case .awake: return "Keeps the Mac awake for as long as you need."
        case .stats: return "CPU, memory and more in the menu bar."
        case .general: return ""
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

    /// Where the window opens: Welcome the first time and after an update,
    /// otherwise the page it was left on. Opening Welcome counts as seen.
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
