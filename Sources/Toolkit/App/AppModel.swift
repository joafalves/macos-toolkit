import AppKit
import ServiceManagement

/// The tools shown in the sidebar of the main window.
enum AppSection: String, CaseIterable, Identifiable {
    case mouse, switcher, layout, mixer, finder, capture, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mouse: return "Mouse Settings"
        case .switcher: return "Window Switcher"
        case .layout: return "Window Layout"
        case .mixer: return "Audio Mixer"
        case .finder: return "Finder"
        case .capture: return "Screen Capture"
        case .general: return "General"
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
        case .general: return "gearshape"
        }
    }
}

final class AppModel: ObservableObject {
    @Published var section: AppSection? = .mouse
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
