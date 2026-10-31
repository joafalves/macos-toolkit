import AppKit
import ApplicationServices

/// An app on this Mac, whether it's running or not.
struct InstalledApp {
    let url: URL
    let bundleID: String
    /// As macOS shows it, in the reader's language: "Notas".
    let name: String
    /// The name of the file, which is the English one for Apple's: "Notes".
    let fileName: String
}

/// The apps that can be opened from the switcher. Found off the main thread,
/// and only asked for again when a search starts, so ⌘Tab never waits for it.
final class AppIndex {
    static let shared = AppIndex()

    private(set) var apps: [InstalledApp] = []
    private var byBundle: [String: InstalledApp] = [:]
    private var icons: [String: NSImage] = [:]
    private var scanning = false
    private var scannedAt = -TimeInterval.infinity
    /// A scan brought in new apps.
    var onChange: () -> Void = {}

    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !scanning, now - scannedAt > 60 else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan()
            DispatchQueue.main.async { [self] in
                scanning = false
                scannedAt = ProcessInfo.processInfo.systemUptime
                let changed = found.map(\.url) != apps.map(\.url)
                apps = found
                byBundle = Dictionary(found.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
                if changed { onChange() }
            }
        }
    }

    func otherName(of bundleID: String?) -> String? {
        bundleID.flatMap { byBundle[$0]?.fileName }
    }

    func icon(of app: InstalledApp) -> NSImage {
        if let icon = icons[app.bundleID] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icons[app.bundleID] = icon
        return icon
    }

    private static func scan() -> [InstalledApp] {
        let manager = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var found: [String: InstalledApp] = [:]
        func add(_ url: URL) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, found[id] == nil else { return }
            // Nothing to switch to: these have no windows of their own.
            let info = bundle.infoDictionary ?? [:]
            if (info["LSUIElement"] as? Bool) == true || (info["LSBackgroundOnly"] as? Bool) == true { return }
            let name = manager.displayName(atPath: url.path)
            found[id] = InstalledApp(url: url, bundleID: id, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                                     fileName: url.deletingPathExtension().lastPathComponent)
        }
        for root in roots {
            let children = (try? manager.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for child in children {
                if child.pathExtension == "app" {
                    add(child)
                } else if let inner = try? manager.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    // A vendor's folder of apps.
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return found.values.sorted { $0.url.path < $1.url.path }
    }
}

/// What the switcher finds for what's been typed.
enum SwitcherSearch {
    /// How many apps without a row a search offers, at most, and how much has
    /// to be typed first: a letter or two matches half of what's installed.
    private static let installedLimit = 3, installedMinimum = 2

    /// How well `query` matches `text`: 0 at its start, 1 at the start of a
    /// word in it, 2 anywhere, nil not at all. Accents and case don't count.
    static func rank(_ query: String, in text: String) -> Int? {
        let text = text.folding(options: .diacriticInsensitive, locale: .current)
        let query = query.folding(options: .diacriticInsensitive, locale: .current)
        guard !query.isEmpty else { return nil }
        var best: Int?
        var from = text.startIndex
        while let range = text.range(of: query, options: .caseInsensitive, range: from..<text.endIndex) {
            guard range.lowerBound != text.startIndex else { return 0 }
            let before = text[text.index(before: range.lowerBound)]
            let first = text[range.lowerBound]
            let wordStart = !(before.isLetter || before.isNumber) || (before.isLowercase && first.isUppercase)
            best = min(best ?? 2, wordStart ? 1 : 2)
            from = text.index(after: range.lowerBound)
        }
        return best
    }

    /// An app's name beats a window's title, whatever the match: typing "not"
    /// is looking for Notes before a document that mentions notes.
    static func score(_ query: String, app: String, otherName: String?, title: String) -> Int? {
        let names = [rank(query, in: app), otherName.flatMap { rank(query, in: $0) }].compactMap { $0 }
        if let name = names.min() { return name }
        return rank(query, in: title).map { $0 + 3 }
    }

    /// The rows that match, best first, keeping the order rows came in among
    /// equals; then, below them all, a few apps without a row. Those only by
    /// the start of a name or word: "not" shouldn't offer Keynote.
    static func results(_ query: String, rows: [SwitcherItem], installed: [InstalledApp],
                        otherName: (String?) -> String? = { _ in nil },
                        icon: (InstalledApp) -> NSImage? = { _ in nil }) -> [SwitcherItem] {
        var scored: [(score: Int, order: Int, item: SwitcherItem)] = []
        for (order, row) in rows.enumerated() {
            guard let score = score(query, app: row.appName, otherName: otherName(row.bundleID), title: row.title) else { continue }
            scored.append((score, order, row))
        }
        let found = scored.sorted { ($0.score, $0.order) < ($1.score, $1.order) }.map(\.item)
        guard query.count >= installedMinimum else { return found }
        let listed = Set(rows.compactMap(\.bundleID))
        let matches = installed.compactMap { app -> (Int, InstalledApp)? in
            guard !listed.contains(app.bundleID), let score = score(query, app: app.name, otherName: app.fileName, title: ""), score <= 1 else { return nil }
            return (score, app)
        }
        return found + matches.sorted { ($0.0, $0.1.name) < ($1.0, $1.1.name) }.prefix(installedLimit).map { _, app in
            SwitcherItem(id: "i\(app.bundleID)", window: nil, pid: -1, title: app.name, appName: app.name, icon: icon(app),
                         state: .notListed, bundleID: app.bundleID, appURL: app.url)
        }
    }

    #if TOOLKIT_DEV
    /// `--test-switcher-search`: what's found for what's typed, and app colours,
    /// from made-up apps. Touches nothing.
    static func test() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func row(_ id: Int, _ title: String, _ app: String, bundle: String? = nil) -> SwitcherItem {
            SwitcherItem(id: "\(id)", window: CGWindowID(id), pid: 1, title: title, appName: app, icon: nil, state: .window, bundleID: bundle ?? app)
        }
        func installed(_ name: String, file: String? = nil) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: "/Applications/\(file ?? name).app"), bundleID: "id.\(name)", name: name, fileName: file ?? name)
        }
        func titles(_ query: String, _ rows: [SwitcherItem], _ apps: [InstalledApp] = [], other: @escaping (String?) -> String? = { _ in nil }) -> [String] {
            results(query, rows: rows, installed: apps, otherName: other).map(\.title)
        }

        check("the start of a name", rank("not", in: "Notes") == 0)
        check("the start of a word", rank("code", in: "Visual Studio Code") == 1)
        check("inside a joined name", rank("edit", in: "TextEdit") == 1)
        check("anywhere", rank("ote", in: "Notes") == 2)
        check("no match", rank("xyz", in: "Notes") == nil)
        check("accents don't count", rank("acucar", in: "Açúcar") == 0)
        check("case and accents in what's typed", rank("MÚS", in: "Music") == 0)

        let rows = [row(1, "notes.md", "Terminal"), row(2, "Shopping", "Notes"), row(3, "Inbox", "Mail")]
        check("an app's name beats a title", titles("not", rows) == ["Shopping", "notes.md"], titles("not", rows).joined(separator: ", "))
        check("nothing found is nothing", titles("zzz", rows).isEmpty)
        let translated = [row(1, "Lista", "Notas", bundle: "com.apple.Notes")]
        check("the English name finds a translated app",
              titles("notes", translated, other: { $0 == "com.apple.Notes" ? "Notes" : nil }) == ["Lista"])
        check("an app without a row comes after every row that matches, even a worse match",
              titles("not", [row(1, "notes.md", "Terminal")], [installed("Notebook")]) == ["notes.md", "Notebook"])
        check("an app with a row isn't offered again",
              titles("mail", [row(1, "Inbox", "Mail", bundle: "id.Mail")], [installed("Mail")]) == ["Inbox"])
        check("an app without a row, by its English name",
              titles("notes", [], [installed("Notas", file: "Notes")]) == ["Notas"])
        check("not offered from the middle of a word", titles("not", [], [installed("Keynote")]).isEmpty)
        check("but a row is found there", titles("not", [row(1, "Slides", "Keynote")]) == ["Slides"])
        check("not offered for one letter", titles("n", [], [installed("Notes")]).isEmpty)
        check("few apps without a row", titles("app", [], (0..<20).map { installed("App \($0)") }).count == 3)

        // How wide the grid gets.
        func grid(_ windows: Int, _ size: PreviewSize, _ percent: Double, on display: CGSize) -> GridLayout {
            GridLayout(count: windows, maxTileWidth: size.maxTileWidth, area: SwitcherPanel.gridArea(on: display, percent: percent))
        }
        let large = CGSize(width: 2560, height: 1409), laptop = CGSize(width: 1512, height: 950)
        let largeWidth = GridWidth.suggested(points: 2560, millimetres: 602), laptopWidth = GridWidth.suggested(points: 1512, millimetres: 301)
        check("a 27-inch display starts around half", largeWidth == 55, "\(largeWidth)%")
        check("a laptop's can use nearly all of it", laptopWidth == 92, "\(laptopWidth)%")
        check("a display that doesn't say how large it is", GridWidth.suggested(points: 2800, millimetres: 0) == 50)
        check("a very wide one stays within range", GridWidth.suggested(points: 5120, millimetres: 1190) == 30)
        check("five medium across on the large display", grid(10, .medium, largeWidth, on: large).columns == 5)
        check("and on the laptop", grid(10, .medium, laptopWidth, on: laptop).columns == 5)
        check("at full size", grid(10, .medium, largeWidth, on: large).tile.width == 260)
        check("narrower, fewer across", grid(10, .medium, 35, on: large).columns == 3)
        let narrow = grid(3, .fit, 30, on: laptop), area = SwitcherPanel.gridArea(on: laptop, percent: 30)
        check("a tile is never wider than the grid may be", narrow.size.width <= area.width, "\(Int(narrow.size.width)) of \(Int(area.width)) pt")
        check("few windows aren't spread out", grid(2, .medium, largeWidth, on: large).size.width < 600)
        func display(_ uuid: String) -> LayoutDisplay {
            LayoutDisplay(id: 0, uuid: uuid, name: uuid, frame: CGRect(x: 0, y: 0, width: 2800, height: 1400), usable: CGRect(x: 0, y: 0, width: 2800, height: 1400))
        }
        var widths = SwitcherConfig()
        check("a new display gets what suits it", widths.gridWidth(for: display("new")) == 50)
        widths.gridWidths["a"] = 70
        check("a display keeps its own", widths.gridWidth(for: display("a")) == 70 && widths.gridWidth(for: display("b")) == 50)
        widths.gridWidthForAll = 60
        widths.gridWidths = [:]
        check("applied to all, every display has it, and new ones", widths.gridWidth(for: display("a")) == 60 && widths.gridWidth(for: display("new")) == 60)
        widths.gridWidths["a"] = 40
        check("and one can still differ", widths.gridWidth(for: display("a")) == 40 && widths.gridWidth(for: display("b")) == 60)
        let saved = (try? JSONEncoder().encode(widths)).flatMap { try? JSONDecoder().decode(SwitcherConfig.self, from: $0) }
        check("kept when saved", saved?.gridWidths == ["a": 40] && saved?.gridWidthForAll == 60)

        // Defaults.
        let fresh = SwitcherConfig()
        let empty = try? JSONDecoder().decode(SwitcherConfig.self, from: Data("{}".utf8))
        check("small icons by default", fresh.previewIcons == .small && empty?.previewIcons == .small)
        check("previews by default", fresh.style == .previews && empty?.style == .previews)
        check("no colours by default", !fresh.appColors && empty?.appColors == false)

        // The second line of a tile.
        check("a window named after its app has no second line", SwitcherItem.title("Music", without: "Music") == nil)
        check("whatever the case", SwitcherItem.title("MUSIC", without: "Music") == nil)
        check("the app's name off the end", SwitcherItem.title("Inbox - Mail", without: "Mail") == "Inbox")
        check("and off the start", SwitcherItem.title("Safari — Start Page", without: "Safari") == "Start Page")
        check("kept inside a sentence", SwitcherItem.title("Notes for Monday", without: "Notes") == "Notes for Monday")
        check("kept at the end of one", SwitcherItem.title("My Notes", without: "Notes") == "My Notes")
        check("kept in a longer word", SwitcherItem.title("Mailbox - Inbox", without: "Mail") == "Mailbox - Inbox")
        check("a title with no app name stays", SwitcherItem.title("Inbox", without: "Mail") == "Inbox")

        // Colours.
        func smallest(_ apps: [String], _ choices: AppColorChoices) -> Double {
            var smallest = Double.infinity
            for (index, app) in apps.enumerated() {
                for other in apps[(index + 1)...] { smallest = min(smallest, AppPalette.difference(choices.color(of: app)!, choices.color(of: other)!)) }
            }
            return smallest
        }
        for count in [2, 6, 12, 14] {
            var choices = AppColorChoices()
            let apps = (0..<count).map { "app\($0)" }
            for app in apps { choices.assign(app, iconHue: 250, open: Set(apps)) }
            let found = smallest(apps, choices)
            check("\(count) open with one icon colour: each looks different", found >= AppColorChoices.enough, String(format: "smallest %.3f", found))
        }
        var crowded = AppColorChoices()
        let many = (0..<24).map { "app\($0)" }
        for app in many { crowded.assign(app, iconHue: nil, open: Set(many)) }
        check("24 open: still none the same", smallest(many, crowded) > 0.015, String(format: "smallest %.3f", smallest(many, crowded)))

        var kept = AppColorChoices()
        let before = kept.assign("kept", iconHue: 250, open: [])
        kept.assign("kept", iconHue: 10, open: [])
        check("an app keeps its colour", kept.color(of: "kept") == before)

        var icons = AppColorChoices()
        let green = icons.assign("green", iconHue: 150, open: ["green", "blue"])
        let blue = icons.assign("blue", iconHue: 250, open: ["green", "blue"])
        check("a colour near the icon's when there's room",
              AppPalette.hueDistance(green.hue, 150) <= 30 && AppPalette.hueDistance(blue.hue, 250) <= 30, "\(green.hue) \(blue.hue)")

        // Made while the other was closed, then open together.
        var alike = AppColorChoices()
        let old = alike.assign("old", iconHue: 250, open: [])
        alike.assign("new", iconHue: 250, open: [])
        check("made apart, they can look alike", AppPalette.difference(old, alike.color(of: "new")!) < AppColorChoices.enough)
        check("open together, the newer gets a new colour", alike.separate(open: ["old", "new"]))
        check("the older keeps its own", alike.color(of: "old") == old)
        check("and they look different", AppPalette.difference(old, alike.color(of: "new")!) >= AppColorChoices.enough)
        check("nothing changes after that", !alike.separate(open: ["old", "new"]))
        let settled = alike.color(of: "new")
        alike.separate(open: ["new"])
        check("nor once one closes", alike.color(of: "new") == settled)

        var again = AppColorChoices(), other = AppColorChoices()
        let names = ["a", "b", "c"]
        check("the same on every launch", names.map { again.assign($0, iconHue: nil, open: Set(names)) } == names.map { other.assign($0, iconHue: nil, open: Set(names)) })

        var timing = AppColorChoices()
        let open = Set((0..<20).map { "app\($0)" })
        for app in open.sorted() { timing.assign(app, iconHue: nil, open: open) }
        let timed = Date()
        timing.separate(open: open)
        print(String(format: "     comparing 20 open apps, when one opens or closes: %.1f ms", Date().timeIntervalSince(timed) * 1000))

        let start = Date()
        for _ in 0..<20 { _ = AppPalette.dominantHue(of: NSWorkspace.shared.icon(forFile: "/System/Applications/Mail.app")) }
        print(String(format: "     looking at an icon, once per app: %.1f ms", Date().timeIntervalSince(start) / 20 * 1000))
        print(failures == 0 ? "all passed" : "\(failures) failed")
    }

    static func listSearch(_ query: String, file: String?) {
        let index = AppIndex.shared
        index.refresh()
        let catalog = WindowCatalog()
        if AXIsProcessTrusted() { catalog.start() }
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let rows = catalog.snapshot().items
        var lines = ["trusted \(AXIsProcessTrusted()), \(rows.count) rows, \(index.apps.count) installed apps"]
        for item in results(query, rows: rows, installed: index.apps, otherName: index.otherName) {
            let score = score(query, app: item.appName, otherName: index.otherName(of: item.bundleID), title: item.title) ?? -1
            lines.append("\(score)\t\(item.state)\t\(item.appName)\t\(item.appURL?.path ?? "-")\t\(item.title)")
        }
        let output = lines.joined(separator: "\n") + "\n"
        print(output, terminator: "")
        if let file { try? output.write(toFile: file, atomically: true, encoding: .utf8) }
    }

    /// `--list-badges`: what the Dock shows on its icons now, and what asking costs.
    static func listBadges() {
        guard AXIsProcessTrusted() else { return print("Accessibility is not granted to the process running this.") }
        let start = Date()
        DockBadges.shared.read { badges in
            print(String(format: "%d badges, in %.1f ms", badges.count, Date().timeIntervalSince(start) * 1000))
            for (app, badge) in badges.sorted(by: { $0.key < $1.key }) { print("\(app)\t\(badge)") }
            exit(0)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(5))
    }
    #endif
}

/// The numbers on apps' icons, which only the Dock knows, hidden or not.
/// Asked off the main thread, and only once the list is on screen, so a quick
/// ⌘Tab asks nothing and the list never waits: it shows the last answer, then
/// this one when it comes.
final class DockBadges {
    static let shared = DockBadges()

    /// By the file name of the app, since one app can be at several paths
    /// (Safari's, say, is in /Applications to the Dock and elsewhere to itself).
    private(set) var last: [String: String] = [:]
    private var reading = false
    private let queue = DispatchQueue(label: "dev.jalves.macos-toolkit.dock-badges", qos: .userInitiated)
    /// How long the Dock gets to answer, per question and in all.
    private static let answerTime: Float = 0.2, totalTime = 0.5

    func read(then done: @escaping ([String: String]) -> Void) {
        guard !reading else { return }
        reading = true
        queue.async {
            let badges = Self.ask()
            DispatchQueue.main.async { [self] in
                reading = false
                last = badges
                done(badges)
            }
        }
    }

    private static func ask() -> [String: String] {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, answerTime)
        func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? T
        }
        let start = Date()
        var badges: [String: String] = [:]
        for list in attribute(app, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
            for item in attribute(list, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
                guard Date().timeIntervalSince(start) < totalTime else { return badges }
                guard let label: String = attribute(item, "AXStatusLabel"), !label.isEmpty,
                      let url: URL = attribute(item, kAXURLAttribute) else { continue }
                badges[url.lastPathComponent] = label
            }
        }
        return badges
    }
}
