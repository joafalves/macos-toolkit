import SwiftUI

/// macOS's own settings that System Settings doesn't show, each as the Mac
/// has it now. Not a tool: there's nothing to turn on, and what's set here
/// stays set without the toolkit.
struct TweaksView: View {
    @StateObject private var tweaks = TweaksModel()

    var body: some View {
        Page {
            PageHeader(section: .tweaks, subtitle: "macOS settings that System Settings doesn't show. Each one is as it's set on this Mac now, and stays as you set it without the toolkit.")

            if tweaks.refused != nil {
                Banner(text: "macOS kept that setting as it was.", button: "OK") { tweaks.refused = nil }
            }

            Card(title: "Background Tasks",
                 footnote: "Turned off for you only, and on again with the switch. A macOS update can turn one back on; it then shows as on here.") {
                TweakRow(title: "Photos analysis",
                         caption: "Finds objects, scenes and text in your photos. Off, Photos can't search by what's in a photo, and Live Text and Visual Look Up stop working in it.",
                         tweak: .photosAnalysis, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "People and memories",
                         caption: "Recognizes people and pets, and makes Memories. Off, Photos has no People & Pets, Memories or featured photos.",
                         tweak: .peopleAndMemories, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Game Center", caption: "Off, games can't sign in to Game Center.", tweak: .gameCenter, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Tips", caption: "Off, no notifications from the Tips app.", tweak: .tips, tweaks: tweaks)
            }

            Card(title: "Dock", footnote: "A change restarts the Dock.") {
                TweakRow(title: "Show the Dock without delay", caption: "When it hides, it shows as soon as the pointer reaches the edge.",
                         tweak: .dockWithoutDelay, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Quicker Mission Control", caption: "Mission Control opens and closes faster.", tweak: .quickMissionControl, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Dim hidden apps", caption: "Apps hidden with ⌘H have a faded icon.", tweak: .dimHiddenApps, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Only open apps", caption: "The Dock shows only the apps that are open.", tweak: .onlyOpenApps, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Scroll on an icon for its windows", caption: "Scrolling up on an app's icon shows its windows.",
                         tweak: .scrollForWindows, tweaks: tweaks)
            }

            Card(title: "Finder", footnote: "A change restarts Finder, which opens its windows again. What the toolkit adds to Finder is on the [Finder page](toolkit-page:finder).") {
                TweakRow(title: "Full path in window titles", caption: "A window's title shows where the folder is, from the top of the disk.",
                         tweak: .pathInTitle, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Show hidden files", caption: "Files whose names start with a dot show, dimmed. ⇧⌘. shows them for a moment.",
                         tweak: .hiddenFiles, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Warn before changing an extension", caption: "Asks before a new extension changes the app that opens a file.",
                         tweak: .extensionWarning, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Quit Finder from its menu", caption: "Adds Quit Finder to the Finder menu.", tweak: .quitFinder, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "No .DS_Store on network drives", caption: "Finder doesn't leave its hidden view files in shared folders.",
                         tweak: .networkStores, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "No .DS_Store on USB drives", caption: "Nor on disks connected by USB.", tweak: .usbStores, tweaks: tweaks)
            }

            Card(title: "Typing", footnote: "Apps pick a change up the next time they open.") {
                TweakRow(title: "Hold a key for accents", caption: "Off, holding a key repeats it instead of showing its accented letters.",
                         tweak: .pressAndHold, tweaks: tweaks)
            }

            Card(title: "Windows and Dialogs", footnote: "Apps pick a change up the next time they open.") {
                TweakRow(title: "Expand Save and Print dialogs", caption: "They open with every option showing.", tweak: .expandedDialogs, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Save new documents to iCloud", caption: "Off, a new document is saved on this Mac unless you pick iCloud.",
                         tweak: .saveToCloud, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Window opening animations", caption: "New windows and sheets grow into place.", tweak: .windowAnimations, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Offer to report crashes", caption: "Asks to send a report to Apple when an app quits unexpectedly.",
                         tweak: .crashDialog, tweaks: tweaks)
            }

            Card(title: "Devices") {
                TweakRow(title: "Open Photos for a new iPhone or camera", caption: "Photos opens when one is connected.",
                         tweak: .photosOnConnect, tweaks: tweaks)
                RowDivider()
                TweakRow(title: "Offer new disks for Time Machine", caption: "Asks whether to back up to each disk you connect.",
                         tweak: .offerTimeMachine, tweaks: tweaks)
            }
        }
    }
}

/// A tweak's row: its switch as the Mac has it, and when that isn't macOS's
/// default, a badge saying so and a way back to it.
struct TweakRow: View {
    let title: LocalizedStringResource
    var caption: LocalizedStringKey?
    let tweak: Tweak
    @ObservedObject var tweaks: TweaksModel

    var body: some View {
        SettingRow(title: title, caption: caption, badge: tweaks.changed(tweak) ? "Changed" : nil) {
            HStack(spacing: 10) {
                if tweaks.changed(tweak) {
                    Button { tweaks.set(tweak, tweak.macOSDefault) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to macOS default")
                    .accessibilityLabel("Reset to macOS default")
                }
                Toggle(title, isOn: Binding(get: { tweaks.on(tweak) }, set: { tweaks.set(tweak, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}
