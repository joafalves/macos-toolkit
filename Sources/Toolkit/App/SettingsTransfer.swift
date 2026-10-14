import AppKit
import UniformTypeIdentifiers

/// Everything the toolkit stores, as one file. Each tool gets its own key.
struct SettingsFile: Codable {
    var version = 1
    var mouse: MouseConfig
    /// Missing in files exported before the switcher existed.
    var switcher: SwitcherConfig?
}

enum SettingsTransfer {
    static func exportSettings(mouse: MouseController, switcher: SwitcherController) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacOS Toolkit Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(SettingsFile(mouse: mouse.config, switcher: switcher.config)).write(to: url, options: .atomic)
        } catch {
            show(error: "The settings could not be exported.", detail: error.localizedDescription)
        }
    }

    static func importSettings(mouse: MouseController, switcher: SwitcherController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let file: SettingsFile
        do {
            file = try JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: url))
        } catch {
            show(error: "“\(url.lastPathComponent)” is not a MacOS Toolkit settings file.", detail: error.localizedDescription)
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Replace your current settings?"
        confirm.informativeText = "All current settings will be replaced with the ones in “\(url.lastPathComponent)”."
        confirm.addButton(withTitle: "Replace")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        mouse.config = file.mouse
        if let config = file.switcher { switcher.config = config }
    }

    private static func show(error: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error
        alert.informativeText = detail
        alert.runModal()
    }
}
