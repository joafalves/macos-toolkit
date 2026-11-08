import AppKit
import Carbon.HIToolbox

/// An app on the ring, by where it is: what the Dock keeps too.
struct DockApp: Codable, Equatable, Hashable {
    var path: String
    var bundleID: String?
    var name: String

    init(path: String, bundleID: String?, name: String) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
    }

    init?(url: URL) {
        guard url.pathExtension == "app" else { return nil }
        let bundle = Bundle(url: url)
        let name = FileManager.default.displayName(atPath: url.path)
        self.init(path: url.path, bundleID: bundle?.bundleIdentifier, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
}

/// A folder of apps, made by hand: it takes one place on the ring and opens as one of its own.
struct DockFolder: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var apps: [DockApp] = []
}

/// One place on a hand-made ring.
enum DockEntry: Codable, Equatable, Hashable, Identifiable {
    case app(DockApp)
    case folder(DockFolder)

    var id: String {
        switch self {
        case .app(let app): return "app:" + app.path
        case .folder(let folder): return "folder:" + folder.id.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey { case app, folder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let folder = try c.decodeIfPresent(DockFolder.self, forKey: .folder) { self = .folder(folder) }
        else { self = .app(try c.decode(DockApp.self, forKey: .app)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let app): try c.encode(app, forKey: .app)
        case .folder(let folder): try c.encode(folder, forKey: .folder)
        }
    }
}

enum DockAppsSource: String, Codable, CaseIterable {
    /// The apps kept in the macOS Dock, read each time the ring opens.
    case dock
    /// A list of its own, with folders, made on the page.
    case manual
}

enum DockOverflow: String, Codable, CaseIterable {
    /// The last place is «More», which opens as a ring of what didn't fit.
    case moreSlot
    /// What didn't fit is a layer of its own, after Open, reached with the wheel.
    case moreLayer
}

enum DockTrigger: String, Codable, CaseIterable {
    /// The right ⌘ key on its own.
    case rightCommand
    /// A shortcut of two keys or more.
    case shortcut
}

enum DockOpening: String, Codable, CaseIterable {
    /// Shown the moment the trigger goes down, for as long as it's held; letting go picks.
    case press
    /// Shown as the trigger goes up, and kept open until a pick or the trigger again.
    case toggle
}

struct FloatingDockConfig: Codable, Equatable {
    var enabled = false
    var source = DockAppsSource.dock
    /// For `.manual`.
    var items: [DockEntry] = []
    var slots = 10
    static let slotRange = 6...12
    var overflow = DockOverflow.moreSlot
    var trigger = DockTrigger.rightCommand
    var shortcut = Shortcut(keyCode: kVK_Space, flags: [.option])
    var opening = DockOpening.toggle
    /// Letters chosen by hand, by app path; the rest come from the names.
    var letters: [String: String] = [:]
    /// The right ⌘ with an app's letter brings it forward at once, without the ring.
    var quickLetters = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        source = (try? c.decodeIfPresent(DockAppsSource.self, forKey: .source)) ?? .dock
        items = (try? c.decodeIfPresent([DockEntry].self, forKey: .items)) ?? []
        let slots = (try? c.decodeIfPresent(Int.self, forKey: .slots)) ?? 10
        self.slots = min(max(slots, Self.slotRange.lowerBound), Self.slotRange.upperBound)
        overflow = (try? c.decodeIfPresent(DockOverflow.self, forKey: .overflow)) ?? .moreSlot
        trigger = (try? c.decodeIfPresent(DockTrigger.self, forKey: .trigger)) ?? .rightCommand
        shortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .shortcut)) ?? Shortcut(keyCode: kVK_Space, flags: [.option])
        opening = (try? c.decodeIfPresent(DockOpening.self, forKey: .opening)) ?? .toggle
        letters = (try? c.decodeIfPresent([String: String].self, forKey: .letters)) ?? [:]
        quickLetters = (try? c.decodeIfPresent(Bool.self, forKey: .quickLetters)) ?? true
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOS Toolkit", isDirectory: true)
            .appendingPathComponent("floating-dock.json")
    }

    static func load() -> FloatingDockConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return FloatingDockConfig() }
        return (try? JSONDecoder().decode(FloatingDockConfig.self, from: data)) ?? FloatingDockConfig()
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }
}
