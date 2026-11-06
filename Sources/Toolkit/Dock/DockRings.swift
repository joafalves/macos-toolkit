import AppKit

/// A place on a ring as it's shown: an app, or a folder that opens as a ring of its own.
struct RingSlot: Identifiable {
    enum Kind {
        case app(DockApp)
        case folder([DockEntry])
    }

    let id: String
    let kind: Kind
    let name: String
    let icon: NSImage?
    /// A folder's first four apps, drawn small in its place.
    var minis: [NSImage] = []
    var letter: String?
    var badge: String?
    var running = false
    /// Its windows, most recent first: what fans out beyond it.
    var windows: [SwitcherItem] = []

    var app: DockApp? { if case .app(let app) = kind { return app } else { return nil } }
}

struct DockRing {
    let title: String
    let slots: [RingSlot]
}

/// Builds the rings from the Dock or the hand-made list, with what's open now.
enum DockRings {
    /// For `--snapshot`: made-up apps in place of this Mac's Dock.
    static var preview: [DockApp]?

    /// The apps kept in the macOS Dock, in its order, read fresh: the Dock
    /// writes its list as it changes, so a move there shows the next time.
    static func dockApps() -> [DockApp] {
        if let preview { return preview }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
        let apps: [DockApp] = tiles.compactMap { tile in
            // Spacers have a tile of their own type and no file.
            if let type = tile["tile-type"] as? String, type != "file-tile" { return nil }
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let text = file["_CFURLString"] as? String else { return nil }
            let url = (file["_CFURLStringType"] as? Int) == 0 ? URL(fileURLWithPath: text) : (URL(string: text) ?? URL(fileURLWithPath: text))
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            var app = DockApp(url: url) ?? DockApp(path: url.path, bundleID: nil, name: url.deletingPathExtension().lastPathComponent)
            if let id = data["bundle-identifier"] as? String { app.bundleID = id }
            return app
        }
        // The Dock always shows Finder first, and so never lists it.
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        return (DockApp(url: finder).map { [$0] } ?? []) + apps.filter { $0.bundleID != "com.apple.finder" }
    }

    /// The entries the ring is made from, as the config says.
    static func entries(_ config: FloatingDockConfig) -> [DockEntry] {
        switch config.source {
        case .dock: return dockApps().map { .app($0) }
        case .manual: return config.items
        }
    }

    /// Every app in `entries`, folders opened, in order.
    static func apps(in entries: [DockEntry]) -> [DockApp] {
        entries.flatMap { entry -> [DockApp] in
            switch entry {
            case .app(let app): return [app]
            case .folder(let folder): return folder.apps
            }
        }
    }

    /// `entries` on a ring of `slots` places: what doesn't fit goes in a last
    /// «More» place, or is handed back for a layer of its own.
    static func split(_ entries: [DockEntry], slots: Int, overflow: DockOverflow) -> (shown: [DockEntry], rest: [DockEntry]) {
        guard entries.count > slots else { return (entries, []) }
        switch overflow {
        case .moreSlot:
            let more = DockFolder(id: Self.moreID, name: String(localized: "More"), apps: apps(in: Array(entries[(slots - 1)...])))
            return (Array(entries.prefix(slots - 1)) + [.folder(more)], [])
        case .moreLayer:
            return (Array(entries.prefix(slots)), Array(entries[slots...]))
        }
    }

    static let moreID = UUID(uuidString: "00000000-0000-0000-0000-00000000F00D")!

    /// A letter for every app, from its name where possible: those chosen by
    /// hand first, then the rest in order, so the first apps get the obvious ones.
    static func letters(for apps: [DockApp], chosen: [String: String]) -> [String: String] {
        var used = Set<String>(), map: [String: String] = [:]
        for app in apps {
            if let letter = chosen[app.path]?.lowercased(), letter.count == 1, !used.contains(letter) {
                used.insert(letter); map[app.path] = letter
            }
        }
        for app in apps where map[app.path] == nil {
            let letters = app.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().filter { $0.isLetter && $0.isASCII }
            if let letter = (letters.map(String.init) + "abcdefghijklmnopqrstuvwxyz".map(String.init)).first(where: { !used.contains($0) }) {
                used.insert(letter); map[app.path] = letter
            }
        }
        return map
    }

    static func icon(_ app: DockApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.path)
    }

    /// The windows of `app`, most recent first, from the window list.
    static func windows(of app: DockApp, in items: [SwitcherItem]) -> [SwitcherItem] {
        items.filter { item in
            guard item.state == .window || item.state == .minimized, item.window != nil else { return false }
            if let id = app.bundleID, let other = item.bundleID { return id == other }
            return item.appURL?.path == app.path
        }
    }

    static func isRunning(_ app: DockApp, _ running: [NSRunningApplication]) -> Bool {
        running.contains { ($0.bundleIdentifier != nil && $0.bundleIdentifier == app.bundleID) || $0.bundleURL?.path == app.path }
    }

    /// The slots for `entries`, with their icons, letters, badges and windows.
    static func slots(_ entries: [DockEntry], letters: [String: String], badges: [String: String], items: [SwitcherItem],
                      running: [NSRunningApplication]) -> [RingSlot] {
        entries.map { entry in
            switch entry {
            case .app(let app):
                var slot = RingSlot(id: entry.id, kind: .app(app), name: app.name, icon: icon(app))
                slot.letter = letters[app.path]
                slot.badge = badges[URL(fileURLWithPath: app.path).lastPathComponent]
                slot.running = isRunning(app, running)
                slot.windows = windows(of: app, in: items)
                return slot
            case .folder(let folder):
                var slot = RingSlot(id: entry.id, kind: .folder(folder.apps.map { .app($0) }), name: folder.name, icon: nil)
                slot.minis = folder.apps.prefix(4).map { icon($0) }
                return slot
            }
        }
    }

    /// The apps open now that the ring doesn't have, most recently used first.
    static func openApps(excluding pinned: [DockApp], items: [SwitcherItem], running: [NSRunningApplication]) -> [DockApp] {
        let own = Bundle.main.bundleURL.path
        var order: [String] = []
        for item in items { if let path = item.appURL?.path, !order.contains(path) { order.append(path) } }
        let apps = running.filter { $0.activationPolicy == .regular && !$0.isTerminated }.compactMap { app -> DockApp? in
            guard let url = app.bundleURL, url.path != own else { return nil }
            return DockApp(url: url)
        }
        let pinnedPaths = Set(pinned.map(\.path)), pinnedIDs = Set(pinned.compactMap(\.bundleID))
        return apps.filter { !pinnedPaths.contains($0.path) && !($0.bundleID.map(pinnedIDs.contains) ?? false) }
            .sorted { (order.firstIndex(of: $0.path) ?? .max) < (order.firstIndex(of: $1.path) ?? .max) }
    }
}
