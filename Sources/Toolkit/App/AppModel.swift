import AppKit
import SwiftUI
import ServiceManagement

/// The tools shown in the sidebar of the main window.
enum AppSection: String, CaseIterable, Identifiable {
    case mouse, switcher, layout, mixer, finder, capture, awake, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mouse: return "Mouse"
        case .switcher: return "Window Switcher"
        case .layout: return "Window Layout"
        case .mixer: return "Audio Mixer"
        case .finder: return "Finder"
        case .capture: return "Screen Capture"
        case .awake: return "Keep Awake"
        case .general: return "General"
        }
    }

    /// The colour of its tile in the sidebar and at the top of its page.
    var color: Color {
        switch self {
        case .mouse: return .blue
        case .switcher: return .indigo
        case .layout: return .teal
        case .mixer: return .pink
        case .finder: return .cyan
        case .capture: return .orange
        case .awake: return .brown
        case .general: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .mouse: return "computermouse"
        case .switcher: return "macwindow.on.rectangle"
        case .layout: return "rectangle.split.2x2"
        case .mixer: return "slider.vertical.3"
        case .finder: return "folder"
        case .capture: return "camera.viewfinder"
        case .awake: return "cup.and.saucer.fill"
        case .general: return "gearshape"
        }
    }
}

final class AppModel: ObservableObject {
    @Published var section: AppSection? = .mouse
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
}
