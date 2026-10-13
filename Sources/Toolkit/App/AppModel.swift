import AppKit
import ServiceManagement

/// The tools shown in the sidebar of the main window.
enum AppSection: String, CaseIterable, Identifiable {
    case mouse, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mouse: return "Mouse Settings"
        case .general: return "General"
        }
    }

    var symbol: String {
        switch self {
        case .mouse: return "computermouse"
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
