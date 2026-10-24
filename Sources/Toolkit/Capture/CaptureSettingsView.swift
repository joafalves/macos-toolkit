import AppKit
import SwiftUI

/// The "Screen Capture" section.
struct CaptureSettingsView: View {
    @ObservedObject var capture: CaptureController

    /// Every capture shortcut but `own`, so one can't be set to another's keys.
    private func others(than own: Shortcut) -> [Shortcut] {
        let c = capture.config
        var all = [c.screenShortcut, c.areaShortcut, c.textShortcut, c.toolbarShortcut]
        if let index = all.firstIndex(of: own) { all.remove(at: index) }
        return all
    }

    /// What the chosen quality means, and what it costs on the main display.
    private var qualityCaption: String {
        let quality = capture.config.quality
        let what: String
        switch quality {
        case .standard: what = String(localized: "Half the pixels on Retina. Fine for clicking through a UI.")
        case .high: what = String(localized: "Every pixel. Small text stays sharp while it scrolls.")
        case .maximum: what = String(localized: "Every pixel, with detail to spare for code and tutorials.")
        }
        guard let screen = NSScreen.main else { return what }
        let minute = Recorder.busyMinute(points: screen.frame.size, scale: screen.backingScaleFactor,
                                         fps: capture.config.frameRate, quality: quality)
        let size = ByteCountFormatter.string(fromByteCount: minute, countStyle: .file)
        return what + " " + String(localized: "Up to about \(size) a minute while the whole screen moves.")
    }

    var body: some View {
        Page {
            ToolHeader(section: .capture, subtitle: "Screenshots and small screen recordings.", enabled: $capture.config.enabled,
                       menuBar: MenuBarSwitch(isOn: $capture.config.standaloneIcon,
                                              caption: "A click opens the capture toolbar."))

            if capture.config.enabled, !capture.screenPermission {
                Banner(text: "Screen Capture needs the Screen Recording permission. macOS asks for it once; after that it's in System Settings, under Privacy & Security.",
                       button: "Allow…") { capture.requestScreenPermission() }
            }

            WhenEnabled(enabled: capture.config.enabled) {
                Card(title: "Shortcuts",
                     footnote: "macOS's own screenshot shortcuts are off only where they clash with these. ⌃ counts if it's held when the capture happens: at the end of the drag, or at the click on a window.") {
                    ShortcutRow(title: "Screenshot of the display", caption: "The display under the pointer.",
                                shortcut: $capture.config.screenShortcut, defaultValue: CaptureConfig.defaultScreenShortcut,
                                taken: others(than: capture.config.screenShortcut))
                    RowDivider()
                    ShortcutRow(title: "Screenshot of an area",
                                caption: capture.config.textEnabled
                                    ? "Space switches to clicking a window, and T to copying the text."
                                    : "Space switches to clicking a window.",
                                shortcut: $capture.config.areaShortcut, defaultValue: CaptureConfig.defaultAreaShortcut,
                                taken: others(than: capture.config.areaShortcut))
                    RowDivider()
                    ShortcutRow(title: "Toolbar", caption: "Recordings, the timer and options. Stops a recording.",
                                shortcut: $capture.config.toolbarShortcut, defaultValue: CaptureConfig.defaultToolbarShortcut,
                                taken: others(than: capture.config.toolbarShortcut))
                    RowDivider()
                    SettingRow(title: "Copy to the clipboard instead of saving") {
                        Text("hold ⌃").font(.callout).foregroundStyle(.secondary)
                    }
                    RowDivider()
                    SettingRow(title: "Cancel") {
                        Text("esc").font(.callout).foregroundStyle(.secondary)
                    }
                }

                Card(title: "Text") {
                    ToggleRow(title: "Copy text from the screen",
                              caption: "Copies the text in an area or a window, or what a QR code holds. It takes a little more memory, only while it reads.",
                              isOn: $capture.config.textEnabled)
                    if capture.config.textEnabled {
                        RowDivider()
                        ShortcutRow(title: "Text from an area", caption: "Space switches to clicking a window, and T to a screenshot.",
                                    shortcut: $capture.config.textShortcut, defaultValue: CaptureConfig.defaultTextShortcut,
                                    taken: others(than: capture.config.textShortcut))
                    }
                }

                Card(title: "Screenshots") {
                    FolderRow(title: "Save to", path: $capture.config.screenshotFolder, fallback: CaptureConfig.defaultScreenshotDirectory)
                    RowDivider()
                    OptionRow(title: "Format", caption: "PNG is lossless. JPEG and HEIC are much smaller. The clipboard always gets PNG.",
                              selection: $capture.config.format,
                              options: [(.png, "PNG"), (.jpeg, "JPEG"), (.heic, "HEIC")])
                    RowDivider()
                    ToggleRow(title: "When copying, also save a file",
                              caption: "With ⌃ held, the screenshot goes to the clipboard and to the folder.",
                              isOn: $capture.config.saveWhenCopying)
                    RowDivider()
                    ToggleRow(title: "Shutter sound", isOn: $capture.config.shutterSound)
                }

                Card(title: "Window Screenshots",
                     footnote: "Content Only cuts at the bottom of the title bar and toolbar. Apps that draw their own title bar may keep part of it.") {
                    OptionRow(title: "Style", selection: $capture.config.windowStyle,
                              options: [(.content, "Content Only"), (.plain, "Plain"), (.nice, "With Backdrop")])
                    if capture.config.windowStyle == .nice {
                        RowDivider()
                        OptionRow(title: "Backdrop", caption: "A blurred piece of your desktop picture, or a solid color.",
                                  selection: $capture.config.backdrop,
                                  options: [(.wallpaper, "Wallpaper"), (.color, "Color")]) {
                            if capture.config.backdrop == .color {
                                ColorPicker("Color", selection: Binding(
                                    get: { Color(nsColor: capture.config.backdropNSColor) },
                                    set: { capture.config.backdropColor = NSColor($0).hexString }
                                ), supportsOpacity: false)
                            }
                        }
                        RowDivider()
                        SettingRow(title: "Padding") { EmptyView() } extra: {
                            ValueSlider(value: $capture.config.padding, range: 0...120, step: 4, low: "None", high: "Wide") { "\(Int($0)) pt" }
                        }
                        RowDivider()
                        SettingRow(title: "Shadow") { EmptyView() } extra: {
                            ValueSlider(value: $capture.config.shadow, range: 0...1, step: 0.05, low: "None", high: "Deep") { "\(Int(($0 * 100).rounded()))%" }
                        }
                    }
                }

                Card(title: "Recordings",
                     footnote: "H.264 MP4, which plays everywhere. Frames are only written when something on screen changes, so a still screen adds almost nothing to the file. When it stops, the file is put on the clipboard, ready to paste.") {
                    FolderRow(title: "Save to", path: $capture.config.recordingFolder, fallback: CaptureConfig.defaultRecordingDirectory)
                    RowDivider()
                    OptionRow(title: "Quality", caption: .verbatim(qualityCaption),
                              selection: $capture.config.quality,
                              options: RecordingQuality.allCases.map { ($0, $0.title) })
                    RowDivider()
                    OptionRow(title: "Frame rate", selection: $capture.config.frameRate,
                              options: [(15, "15 fps"), (30, "30 fps"), (60, "60 fps")])
                    RowDivider()
                    ToggleRow(title: "Show cursor", isOn: $capture.config.showCursor)
                    RowDivider()
                    ToggleRow(title: "Show clicks", caption: "A ring where you click.", isOn: $capture.config.showClicks)
                    RowDivider()
                    ToggleRow(title: "System audio", caption: "The sound of other apps.", isOn: $capture.config.systemAudio)
                    RowDivider()
                    ToggleRow(title: "Microphone",
                              caption: capture.micPermission == .denied
                                  ? "Microphone access is off for MacOS Toolkit in System Settings."
                                  : "With system audio on too, both are mixed into one track.",
                              isOn: Binding(get: { capture.config.microphone }, set: { capture.setMicrophone($0) }))
                    if capture.config.microphone {
                        RowDivider()
                        SettingRow(title: "Input") {
                            Picker("Input", selection: $capture.config.microphoneID) {
                                Text("Default").tag("")
                                if !capture.isPreview {
                                    ForEach(Microphones.all(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .onAppear { capture.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            capture.refreshPermissions()
        }
    }
}

/// A folder setting: where files go, and a button to pick another. Empty
/// means `fallback`, which is made on first use.
private struct FolderRow: View {
    let title: LocalizedStringKey
    @Binding var path: String
    let fallback: URL

    var body: some View {
        SettingRow(title: title, caption: .verbatim(((path.isEmpty ? fallback.path : path) as NSString).abbreviatingWithTildeInPath)) {
            HStack(spacing: 8) {
                Button("Choose…") { choose() }
                if !path.isEmpty {
                    Button("Reset") { path = "" }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}
