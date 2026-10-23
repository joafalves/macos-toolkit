import AppKit
import FinderSync

/// Finder loads this into its own extension process. It is sandboxed, so it
/// only builds the menu and hands each action to the main app through the
/// `macos-toolkit:` URL scheme.
@objc(FinderSync)
final class FinderSync: FIFinderSync {
    /// Tags actions from the menu shown on items, as opposed to a window's background.
    private static let onItems = 1

    /// The same list, in the same order, as `Terminals.known` in the app.
    private static let terminals = [
        (id: "com.mitchellh.ghostty", name: "Ghostty"),
        (id: "com.googlecode.iterm2", name: "iTerm"),
        (id: "com.apple.Terminal", name: "Terminal"),
    ]

    override init() {
        super.init()
        // Every folder, so the menu items show everywhere.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let onItems = menuKind == .contextualMenuForItems
        guard onItems || menuKind == .contextualMenuForContainer else { return nil }
        let settings = Settings.load()
        // The Finder tool turned off as a whole in the app.
        guard settings.bool("enabled") else { return nil }
        let menu = NSMenu(title: "")
        // Drawn now, in the colour of the current theme: Finder shows these
        // images as they are, without tinting them the way it does its own.
        let color = Self.menuColor
        let words = Settings.translations()
        func add(_ title: String.LocalizationValue, _ symbol: String, _ action: Selector) {
            let item = NSMenuItem(title: String(localized: title, bundle: words), action: action, keyEquivalent: "")
            item.image = Self.glyph(symbol, pointSize: 13, color: color)
            item.tag = onItems ? Self.onItems : 0
            menu.addItem(item)
        }
        if onItems, settings.bool("cut") { add("Cut", "scissors", #selector(cut(_:))) }
        if settings.bool("newTextFile") { add("New Text File", "doc.badge.plus", #selector(newTextFile(_:))) }
        if settings.bool("openInTerminal"), let terminal = Self.terminal(settings.string("terminal")) {
            add("Open in \(terminal.name)", "terminal", #selector(openInTerminal(_:)))
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func cut(_ sender: NSMenuItem) { send("cut", sender) }
    @objc private func newTextFile(_ sender: NSMenuItem) { send("new-file", sender) }
    @objc private func openInTerminal(_ sender: NSMenuItem) { send("terminal", sender) }

    private func send(_ action: String, _ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        // The app only acts on URLs carrying the secret it wrote for this launch.
        guard let token = Settings.token() else { return }
        var query = [URLQueryItem(name: "token", value: token)]
        if let target = controller.targetedURL() {
            query.append(URLQueryItem(name: "target", value: target.path))
        }
        // On a window's background Finder may still report an old selection.
        if sender.tag == Self.onItems, let item = controller.selectedItemURLs()?.first {
            query.append(URLQueryItem(name: "item", value: item.path))
        }
        var parts = URLComponents()
        parts.scheme = "macos-toolkit"
        parts.host = action
        parts.queryItems = query
        guard let url = parts.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config)
    }

    /// The chosen terminal if it is installed, otherwise the first one that is.
    private static func terminal(_ id: String?) -> (id: String, name: String)? {
        let installed = terminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
        return installed.first { $0.id == id } ?? installed.first
    }

    // MARK: - Images

    private static var menuColor: NSColor {
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 1 : 0, alpha: 0.85)
    }

    /// An SF Symbol drawn into a bitmap in one colour. A symbol image is a
    /// template, and those lose their tint on the way into Finder's process.
    private static func glyph(_ symbol: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(base.size.width * 2), pixelsHigh: Int(base.size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = base.size
        let rect = NSRect(origin: .zero, size: base.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: base.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The app's `finder.json`, read on every menu so a change in the app shows at
/// the next right-click. The sandbox lets us read just that folder (see the
/// entitlements). Missing keys mean the app's defaults.
private struct Settings {
    private var json: [String: Any] = [:]

    /// Inside the sandbox the home directory is the container, so this asks for the real one.
    static var folder: URL {
        let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MacOS Toolkit")
    }

    static func load() -> Settings {
        var settings = Settings()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("finder.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            settings.json = json
        }
        return settings
    }

    /// The translations for the language picked in the app, if one was:
    /// Finder runs us in its own, macOS's.
    static func translations() -> Bundle {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("general.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let language = json["language"] as? String, language != "system",
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    static func token() -> String? {
        (try? String(contentsOf: folder.appendingPathComponent("finder-token"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bool(_ key: String) -> Bool { json[key] as? Bool ?? true }
    func string(_ key: String) -> String? { json[key] as? String }
}
