import SwiftUI

/// Every permission macOS keeps for the toolkit: what uses it, whether it's
/// granted, and a way to grant it or take it back.
struct PermissionsView: View {
    @ObservedObject var permissions = Permissions.shared

    var body: some View {
        Page {
            PageHeader(section: .permissions, subtitle: "What macOS lets the toolkit do, and the tools that need each.")

            RestartBanner()

            Card(footnote: "Revoke resets a permission, so macOS asks again the next time a tool needs it. The app restarts to let go of it. Each one is also in System Settings, under Privacy & Security.") {
                SettingRow(title: "Accessibility", caption: "Used by Mouse, the Window Switcher, Window Layout, the Audio Mixer's volume keys, Finder, Screen Capture and Keep Awake.") {
                    PermissionControl(permission: .accessibility)
                }
                RowDivider()
                SettingRow(title: "System Audio Recording", caption: "Used by the Audio Mixer to change the volume of each app.") {
                    PermissionControl(permission: .systemAudio)
                }
                RowDivider()
                SettingRow(title: "Screen Recording", caption: "Used by Screen Capture, and for the pictures of windows in the Window Switcher and Window Layout.") {
                    PermissionControl(permission: .screenRecording)
                }
                RowDivider()
                SettingRow(title: "Microphone", caption: "Used by Screen Capture to record your voice. Only needed for that.") {
                    PermissionControl(permission: .microphone)
                }
            }

            Card {
                SettingRow(title: "All permissions", caption: "Revoke every one at once, so macOS asks again for each.") {
                    RevokeAllButton()
                }
            }
        }
    }
}

/// While a permission granted in System Settings only takes effect once the
/// app starts again: which, and a button to restart.
struct RestartBanner: View {
    @ObservedObject var permissions = Permissions.shared

    var body: some View {
        let waiting = Permission.allCases.filter { permissions.state($0) == .needsRestart }
        if !waiting.isEmpty {
            Banner(text: "MacOS Toolkit has to restart to use \(ListFormatter.localizedString(byJoining: waiting.map(\.title))).",
                   button: "Restart") { Relaunch.now() }
        }
    }
}
