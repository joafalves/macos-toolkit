#if TOOLKIT_DEV
import AppKit

extension DiskSpace {
    /// `--test-disk-history`: the settings window's back and forward through
    /// the made-up disk's map, by ⌘[ and ⌘] as they're pressed, in a window
    /// that's never shown.
    static func historyTest() {
        _ = NSApplication.shared
        TweaksModel.previewing = true
        let model = AppModel()
        model.persists = false
        model.general = GeneralConfig()
        model.section = .stats
        let stats = StatsController.preview()
        let window = MainWindow.make(MainView(
            model: model, mouse: MouseController.preview(), switcher: SwitcherController.preview(), layout: LayoutController.preview(),
            mixer: MixerController.preview(), finder: FinderController.preview(), capture: CaptureController.preview(),
            awake: AwakeController.preview(), stats: stats, dock: FloatingDockController.preview()))
        window.setContentSize(NSSize(width: 860, height: 900))
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func press(_ key: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "[" ? 33 : 30)!
            _ = window.performKeyEquivalent(with: event)
            settle()
        }
        let space = stats.space
        var failures = 0
        func at(_ section: AppSection, _ path: [String], _ what: String) {
            let shown = space.current.map(DiskSpace.names) ?? []
            let ok = model.section == section && shown == path && (section != .stats || stats.tab == .stat(.disk))
            print((ok ? "ok    " : "FAIL  ") + "\(what): \(model.section?.rawValue ?? "none"), \(shown)")
            if !ok { failures += 1 }
        }
        func child(_ name: String) -> SpaceItem? { space.current?.children.first { $0.name == name } }

        settle()
        stats.tab = .stat(.disk)
        settle()
        space.current = child("Users")
        settle()
        space.current = child("alex")
        settle()
        space.current = child("Library")
        settle()
        at(.stats, ["Users", "alex", "Library"], "three folders in")
        press("[")
        at(.stats, ["Users", "alex"], "⌘[ goes up the way it came")
        press("[")
        press("[")
        at(.stats, [], "⌘[ twice more, the disk itself")
        press("]")
        press("]")
        at(.stats, ["Users", "alex"], "⌘] twice, back in")
        // Somewhere other than where ⌘] led: what was ahead goes.
        space.current = child("Movies")
        settle()
        press("[")
        at(.stats, ["Users", "alex"], "another way down, ⌘[ to where it turned")
        press("]")
        at(.stats, ["Users", "alex", "Movies"], "⌘] the new way, not the old")
        // Another page, then back to the map where it was left.
        model.section = .mouse
        settle()
        press("[")
        at(.stats, ["Users", "alex", "Movies"], "from another page, ⌘[ to the map's folder")
        stats.tab = .stat(.cpu)
        settle()
        press("[")
        at(.stats, ["Users", "alex", "Movies"], "from another tab, ⌘[ to the Disk tab at its folder")
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }

    /// `--test-disk-space`: the map of a made-up folder against what went in,
    /// then the startup disk read for real (nothing is changed): how long it
    /// takes, what's kept, what it costs in memory, and a cancel.
    static func selfTest() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }

        // Sizes are what's allocated, so files are written, not made sparse.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-disk-space-\(getpid())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let mb = 1 << 20
        func write(_ path: String, _ bytes: Int) {
            let url = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
        }
        write("Big/movie", 3 * mb)
        write("Big/notes", 100_000)
        write("Big/Inner/a", 2 * mb)
        write("Small/one", 200_000)
        write("Small/two", 200_000)
        write("top", 4 * mb)
        // Small, so whichever name the scan meets first, nothing else changes.
        try? FileManager.default.linkItem(at: folder.appendingPathComponent("Small/one"), to: folder.appendingPathComponent("Big/same as one"))

        let smallest = Int64(mb)
        guard let result = scan(folder.path, smallest: smallest, cancelled: Locked(false), report: { _, _ in }) else {
            check(false, "the made-up folder was read")
            return
        }
        // The scan's own root is named after the disk and has "System and other";
        // the folder's own items are what's under it.
        let items = result.root.children.filter { $0.kind != .other }
        func named(_ name: String, in list: [SpaceItem]) -> SpaceItem? { list.first { $0.name == name } }
        let big = named("Big", in: items)
        check(named("top", in: items)?.kind == .file, "a large file is kept: \(items.map(\.name))")
        check(big?.kind == .folder && named("movie", in: big?.children ?? []) != nil && named("Inner", in: big?.children ?? []) != nil,
              "a large folder keeps its large items: \(big?.children.map(\.name) ?? [])")
        check(named("Small", in: items) == nil && items.contains { if case .smaller(let n) = $0.kind { return n == 1 } else { return false } },
              "a small folder goes into the smaller items")
        check(named("notes", in: big?.children ?? []) == nil && named("same as one", in: big?.children ?? []) == nil,
              "small files are added up, and a second name for a file counts nothing")
        let total = items.reduce(0) { $0 + $1.size }
        check(total >= 9_900_000 && total < 10_100_000, "everything is counted once: \(total / 1000) KB")
        check(items.map(\.size) == items.map(\.size).sorted(by: >), "largest first")
        check(scan(folder.path, smallest: smallest, cancelled: Locked(true), report: { _, _ in }) == nil, "cancelled, there's no map")

        // The startup disk, for real.
        let before = processFootprint()
        var reports = 0
        guard let disk = scan(dataVolume, cancelled: Locked(false), report: { _, _ in reports += 1 }) else {
            check(false, "the startup disk was read")
            return
        }
        let after = processFootprint()
        let gb = 1e9
        let other = disk.root.children.first { $0.kind == .other }?.size ?? 0
        print(String(format: "      %.1f s, %d items, %d kept, %d not readable, %d reports", disk.seconds, disk.items, disk.root.count, disk.unreadable, reports))
        print(String(format: "      %.0f GB used, %.0f GB in folders, %.0f GB not counted", Double(disk.root.size) / gb,
                     Double(disk.root.size - other) / gb, Double(other) / gb))
        check(disk.root.count < 100_000, "the map keeps few items: \(disk.root.count)")
        check(after - before < 64 << 20, "memory after the scan: \((after - before) >> 20) MB more")
        // A map let go of and made again: nothing kept from the first must grow.
        _ = scan(dataVolume, cancelled: Locked(false), report: { _, _ in })
        let again = processFootprint()
        check(again - after < 8 << 20, "memory after a second scan: \((again - after) >> 20) MB more than after the first")

        let cancelled = Locked(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { cancelled.value = true }
        let start = Date()
        let none = scan(dataVolume, cancelled: cancelled, report: { _, _ in })
        let stopped = Date().timeIntervalSince(start)
        check(none == nil && stopped < 1.5, String(format: "cancelled a second in, it stops: %.2f s", stopped))

        // As the Scan button does it: on a thread, with progress and the map on the main thread.
        let space = DiskSpace()
        var shares: [Double] = []
        let watch = space.$state.sink { state in
            if case .scanning(let share, _) = state { shares.append(share) }
        }
        space.scan()
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, space.isScanning { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        var shown = false
        if case .done(let result) = space.state { shown = space.current === result.root }
        check(shown && shares.count > 5 && shares.last ?? 0 > 0.5,
              String(format: "the button's scan: progress shown %d times up to %.0f%%, then the map at the disk", shares.count, (shares.last ?? 0) * 100))
        watch.cancel()
        space.scan()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        space.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        var idle = false
        if case .idle = space.state { idle = true }
        check(idle, "Cancel goes back to the Scan button, and nothing comes after")
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }
}
#endif
