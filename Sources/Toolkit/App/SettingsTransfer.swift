import AppKit
import UniformTypeIdentifiers

/// Everything the toolkit stores, as one file. Each tool gets its own key.
struct SettingsFile: Codable {
    var version = 1
    var mouse: MouseConfig
    /// Missing in files exported before the switcher existed.
    var switcher: SwitcherConfig?
    /// Missing in files exported before Window Layout existed.
    var layout: LayoutConfig?
    /// Missing in files exported before the mixer existed.
    var mixer: MixerConfig?
    /// Missing in files exported before the Finder tool existed.
    var finder: FinderConfig?
    /// Missing in files exported before Screen Capture existed.
    var capture: CaptureConfig?
    /// Missing in files exported before Keep Awake existed.
    var awake: AwakeConfig?
    /// Missing in files exported before the app had settings of its own.
    var general: GeneralConfig?
    /// Missing in files exported before System Stats existed.
    var stats: StatsConfig?
}

enum SettingsTransfer {
    /// Settings that only hold on the Mac they were set on, so they're never
    /// exported and an import leaves them alone: the lid-closed option goes
    /// with an admin rule installed with a password on that Mac.
    static let localOnly: [String: Set<String>] = ["awake": ["lidClosed"]]

    static func exportSettings(model: AppModel, mouse: MouseController, switcher: SwitcherController, layout: LayoutController, mixer: MixerController, finder: FinderController, capture: CaptureController, awake: AwakeController, stats: StatsController) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacOS Toolkit Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let file = SettingsFile(mouse: mouse.config, switcher: switcher.config, layout: layout.config, mixer: mixer.config, finder: finder.config, capture: capture.config, awake: awake.config, general: model.general, stats: stats.config)
            try exported(file).write(to: url, options: .atomic)
        } catch {
            show(error: String(localized: "The settings could not be exported."), detail: error.localizedDescription)
        }
    }

    /// The file as JSON, without the local-only settings.
    static func exported(_ file: SettingsFile) throws -> Data {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any] ?? [:]
        for (tool, keys) in localOnly {
            guard var settings = json[tool] as? [String: Any] else { continue }
            keys.forEach { settings.removeValue(forKey: $0) }
            json[tool] = settings
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    static func importSettings(model: AppModel, mouse: MouseController, switcher: SwitcherController, layout: LayoutController, mixer: MixerController, finder: FinderController, capture: CaptureController, awake: AwakeController, stats: StatsController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let json: [String: Any]
        do {
            let data = try Data(contentsOf: url)
            // Decoded once to tell a settings file from any other JSON.
            _ = try JSONDecoder().decode(SettingsFile.self, from: data)
            json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            show(error: String(localized: "“\(url.lastPathComponent)” is not a MacOS Toolkit settings file."), detail: error.localizedDescription)
            return
        }

        let confirm = NSAlert()
        confirm.messageText = String(localized: "Import these settings?")
        confirm.informativeText = String(localized: "The settings in “\(url.lastPathComponent)” replace yours. Anything the file doesn't have, from tools or versions it predates, stays as it is.")
        confirm.addButton(withTitle: String(localized: "Import"))
        confirm.addButton(withTitle: String(localized: "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        merge(&mouse.config, json["mouse"], tool: "mouse")
        merge(&switcher.config, json["switcher"], tool: "switcher")
        merge(&layout.config, json["layout"], tool: "layout")
        merge(&mixer.config, json["mixer"], tool: "mixer")
        merge(&finder.config, json["finder"], tool: "finder")
        merge(&capture.config, json["capture"], tool: "capture")
        merge(&awake.config, json["awake"], tool: "awake")
        merge(&model.general, json["general"], tool: "general")
        merge(&stats.config, json["stats"], tool: "stats")
    }

    /// The file's settings over the ones here, setting by setting: a setting
    /// the file doesn't have keeps its value here rather than going back to
    /// its default, and local-only ones are never taken from it.
    static func merge<Config: Codable>(_ config: inout Config, _ incoming: Any?, tool: String) {
        guard let incoming = incoming as? [String: Any],
              let data = try? JSONEncoder().encode(config),
              var current = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let skip = localOnly[tool] ?? []
        for (key, value) in incoming where !skip.contains(key) { current[key] = value }
        guard let merged = try? JSONSerialization.data(withJSONObject: current),
              let result = try? JSONDecoder().decode(Config.self, from: merged) else { return }
        config = result
    }

    private static func show(error: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error
        alert.informativeText = detail
        alert.runModal()
    }
}

extension SettingsTransfer {
    /// `--test-settings`: an export leaves out the local-only settings, and
    /// an import keeps what the file doesn't have.
    static func selfTest() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        var awake = AwakeConfig()
        awake.lidClosed = true
        awake.batteryFloor = 30
        let file = SettingsFile(mouse: MouseConfig(), awake: awake)
        let json = (try? exported(file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let exportedAwake = json?["awake"] as? [String: Any]
        check(exportedAwake?["lidClosed"] == nil && exportedAwake?["batteryFloor"] as? Int == 30, "export: lid closed left out, the rest kept")

        var local = AwakeConfig()
        local.lidClosed = true
        local.batteryFloor = 10
        local.soundAtEnd = false
        merge(&local, ["batteryFloor": 50, "lidClosed": false], tool: "awake")
        check(local.batteryFloor == 50, "import: a setting in the file is taken")
        check(local.soundAtEnd == false, "import: a setting missing from the file stays as it is here")
        check(local.lidClosed == true, "import: a local-only setting in the file is ignored")

        // This Mac's own settings, merged with nothing, come back the same.
        func same<Config: Codable & Equatable>(_ config: Config, _ name: String) {
            var copy = config
            merge(&copy, [String: Any](), tool: name)
            check(copy == config, "\(name): a merge with nothing changes nothing")
        }
        same(MouseConfig.load(), "mouse")
        same(SwitcherConfig.load(), "switcher")
        same(LayoutConfig.load(), "layout")
        same(MixerConfig.load(), "mixer")
        same(FinderConfig.load(), "finder")
        same(CaptureConfig.load(), "capture")
        same(AwakeConfig.load(), "awake")
        same(GeneralConfig.load(), "general")
        same(StatsConfig.load(), "stats")
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }
}
