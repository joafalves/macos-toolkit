import AppKit
import SwiftUI

/// The "Screen Capture" section.
struct CaptureSettingsView: View {
    @ObservedObject var capture: CaptureController

    private static let keys: [(String, String)] = [
        ("Screenshot of the display under the pointer", "⇧⌘3"),
        ("Screenshot of an area; Space switches to a window", "⇧⌘4"),
        ("Toolbar, for recordings and the timer; stops a recording", "⇧⌘5"),
        ("Copy to the clipboard instead of saving", "hold ⌃"),
        ("Cancel", "esc"),
    ]

    var body: some View {
        Page {
            HStack(spacing: 14) {
                IconTile(symbol: AppSection.capture.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Screen Capture").font(.title2.weight(.semibold))
                    Text("Screenshots and small screen recordings.").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if !capture.screenPermission {
                Banner(text: "Screen Capture needs the Screen Recording permission. macOS asks for it once; after that it's in System Settings, under Privacy & Security.",
                       button: "Allow…") { capture.requestScreenPermission() }
            }

            Card(title: "Shortcuts",
                 footnote: "⌃ counts if it's held when the capture happens: at the end of the drag, or at the click on a window.") {
                ToggleRow(title: "Replace macOS's screenshot keys",
                          caption: "When off, these keys open macOS's own screenshot tools, and the toolkit's are in the menu bar.",
                          isOn: $capture.config.replaceShortcuts)
                RowDivider()
                ToggleRow(title: "Own menu bar icon",
                          caption: "Opens the toolbar with one click. While recording, a stop button is in the menu bar either way.",
                          isOn: $capture.config.standaloneIcon)
                ForEach(Array(Self.keys.enumerated()), id: \.offset) { _, key in
                    RowDivider()
                    SettingRow(title: key.0) {
                        Text(key.1).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Card(title: "Screenshots") {
                FolderRow(title: "Save to", path: $capture.config.screenshotFolder, fallback: "Desktop")
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
                FolderRow(title: "Save to", path: $capture.config.recordingFolder, fallback: "Movies")
                RowDivider()
                OptionRow(title: "Resolution",
                          caption: "Point size keeps text readable at a quarter of the pixels of a Retina display, and makes files 3 to 4 times smaller.",
                          selection: $capture.config.nativeResolution,
                          options: [(false, "Point Size"), (true, "Native")])
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
        .onAppear { capture.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            capture.refreshPermissions()
        }
    }
}

/// A folder setting: the folder's name, and a button to pick another.
private struct FolderRow: View {
    let title: String
    @Binding var path: String
    let fallback: String

    var body: some View {
        SettingRow(title: title, caption: path.isEmpty ? nil : (path as NSString).abbreviatingWithTildeInPath) {
            HStack(spacing: 8) {
                Text(path.isEmpty ? fallback : URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundStyle(.secondary)
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
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}
