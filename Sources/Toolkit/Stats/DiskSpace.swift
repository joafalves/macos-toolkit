import AppKit
import Darwin

/// A folder or file on the disk map, with what's under it, largest first.
final class SpaceItem: Identifiable {
    enum Kind: Equatable {
        case folder
        case file
        /// Files and folders each too small to show, added up: how many.
        case smaller(Int)
        /// What the scan didn't count: macOS itself, local snapshots, other
        /// volumes sharing the disk, folders it couldn't read.
        case other
    }

    let name: String
    let kind: Kind
    let size: Int64
    private(set) var children: [SpaceItem]
    private(set) weak var parent: SpaceItem?
    /// The root's own path; the others' come from their parents.
    private let rootPath: String?

    init(name: String, kind: Kind, size: Int64, children: [SpaceItem] = [], rootPath: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.children = children.sorted { $0.size > $1.size }
        self.rootPath = rootPath
        for child in self.children { child.parent = self }
    }

    /// Where it is, as Finder shows it: the data volume's folders are at the
    /// top of the startup disk.
    var path: String? {
        guard kind == .folder || kind == .file else { return nil }
        if let rootPath { return rootPath }
        guard let base = parent?.path else { return nil }
        return base == "/" ? "/" + name : base + "/" + name
    }

    var canOpen: Bool { kind == .folder && !children.isEmpty }

    /// From the top down to this one.
    var trail: [SpaceItem] {
        var items: [SpaceItem] = [self]
        while let parent = items[0].parent { items.insert(parent, at: 0) }
        return items
    }

    /// How many are kept, this one and all under it.
    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

/// What takes space on the startup disk: a scan of its folders, only when
/// asked for, in the background. Only what's large enough to show is kept:
/// the rest of each folder is one "smaller items" block, so the map holds
/// thousands of items rather than every file on the disk.
final class DiskSpace: ObservableObject {
    enum State {
        case idle
        /// How far through the disk's used space, and how many items so far.
        case scanning(share: Double, items: Int)
        case done(Result)
    }

    struct Result {
        let root: SpaceItem
        let at: Date
        /// Folders it couldn't look into, without Full Disk Access.
        let unreadable: Int
        let seconds: Double
        let items: Int
    }

    @Published private(set) var state = State.idle
    /// The folder the map shows, from the last scan.
    @Published var current: SpaceItem?

    /// The data volume: every folder that isn't macOS itself, which is sealed
    /// on a volume of its own and doesn't change.
    static let dataVolume = "/System/Volumes/Data"
    /// Smaller than this, a file or folder is added to its folder's
    /// "smaller items" rather than kept on its own.
    static let smallest: Int64 = 16 << 20
    /// A folder keeps at most this many of its largest items.
    static let most = 200

    private var cancelled: Locked<Bool>?

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    func scan() {
        guard !isScanning else { return }
        let cancelled = Locked(false)
        self.cancelled = cancelled
        state = .scanning(share: 0, items: 0)
        let thread = Thread { [weak self] in
            let result = Self.scan(Self.dataVolume, cancelled: cancelled) { share, items in
                DispatchQueue.main.async {
                    guard let self, self.cancelled === cancelled else { return }
                    self.state = .scanning(share: share, items: items)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.cancelled === cancelled else { return }
                self.cancelled = nil
                if let result {
                    Log.stats.notice("disk scanned: \(result.items, privacy: .public) items in \(result.seconds, format: .fixed(precision: 1), privacy: .public) s, \(result.root.count, privacy: .public) kept, \(result.unreadable, privacy: .public) unreadable")
                    self.state = .done(result)
                    self.current = result.root
                } else {
                    self.state = .idle
                }
            }
        }
        thread.qualityOfService = .utility
        thread.name = "Disk space"
        thread.start()
    }

    func cancel() {
        cancelled?.value = true
        cancelled = nil
        state = .idle
    }

    /// A folder's names from the disk down, for the window's history.
    static func names(_ item: SpaceItem) -> [String] {
        item.trail.dropFirst().map(\.name)
    }

    /// Opens the map at the folder with these names, or as far down as the
    /// last scan still has them.
    func open(_ names: [String]) {
        guard case .done(let result) = state else { return }
        var folder = result.root
        for name in names {
            guard let next = folder.children.first(where: { $0.name == name && $0.canOpen }) else { break }
            folder = next
        }
        if current !== folder { current = folder }
    }

    /// Gone with the tool, so a map from long ago isn't kept around.
    func clear() {
        cancel()
        current = nil
    }

    /// Goes through `path` and what's under it, on this volume only, and
    /// builds the map; nil if cancelled. `report` is called now and then
    /// with how far it is.
    static func scan(_ path: String, smallest: Int64 = smallest, cancelled: Locked<Bool>,
                     report: (Double, Int) -> Void) -> Result? {
        let result = walk(path, smallest: smallest, cancelled: cancelled, report: report)
        // What the walk took, millions of names and the folders open on the
        // way, is freed by now, but malloc keeps the pages unless asked.
        malloc_zone_pressure_relief(nil, 0)
        return result
    }

    private static func walk(_ path: String, smallest: Int64, cancelled: Locked<Bool>,
                             report: (Double, Int) -> Void) -> Result? {
        let start = ProcessInfo.processInfo.systemUptime
        // A file kept in the cloud, not downloaded, has only its name here:
        // looking at it mustn't bring it down.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        var stats = statfs()
        let used = statfs(path, &stats) == 0 ? Int64(stats.f_blocks - stats.f_bavail) * Int64(stats.f_bsize) : 0

        /// A folder being gone through.
        struct Folder {
            var name: String
            var size: Int64 = 0
            var kept: [SpaceItem] = []
            var small: Int64 = 0
            var smallCount = 0

            mutating func add(_ item: SpaceItem, smallest: Int64) {
                size += item.size
                if item.size >= smallest {
                    kept.append(item)
                } else {
                    small += item.size
                    smallCount += 1
                }
            }

            func item(rootPath: String? = nil, smallest: Int64) -> SpaceItem {
                var children = kept.sorted { $0.size > $1.size }
                var small = self.small, smallCount = self.smallCount
                if children.count > DiskSpace.most {
                    for item in children[DiskSpace.most...] {
                        small += item.size
                        smallCount += 1
                    }
                    children.removeLast(children.count - DiskSpace.most)
                }
                // Only next to something else: on its own it says nothing more than its folder.
                if small > 0, !children.isEmpty {
                    children.append(SpaceItem(name: String(localized: "Smaller items"), kind: .smaller(smallCount), size: small))
                }
                return SpaceItem(name: name, kind: .folder, size: size, children: children, rootPath: rootPath)
            }
        }

        var roots: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(roots[0]) }
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }

        var stack: [Folder] = []
        var root: SpaceItem?
        var unreadable = 0
        var items = 0
        var scanned: Int64 = 0
        var lastReport = start
        // A file with more than one name counts once, as du counts it.
        var linked = Set<UInt64>()

        func finish() {
            guard let folder = stack.popLast() else { return }
            if stack.isEmpty {
                root = folder.item(rootPath: "/", smallest: smallest)
            } else {
                stack[stack.count - 1].add(folder.size >= smallest ? folder.item(smallest: smallest) : SpaceItem(name: folder.name, kind: .folder, size: folder.size),
                                           smallest: smallest)
            }
        }

        func name(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
            withUnsafePointer(to: &entry.pointee.fts_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.fts_namelen) + 1) { String(cString: $0) }
            }
        }

        while let entry = fts_read(fts) {
            items += 1
            if items % 4096 == 0 {
                if cancelled.value { return nil }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastReport > 0.25 {
                    lastReport = now
                    report(used > 0 ? min(1, Double(scanned) / Double(used)) : 0, items)
                }
            }
            let stat = entry.pointee.fts_statp
            let own = stat.map { Int64($0.pointee.st_blocks) * 512 } ?? 0
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                stack.append(Folder(name: entry.pointee.fts_level == 0 ? "" : name(entry), size: own))
                scanned += own
            case FTS_DP:
                finish()
            case FTS_DNR, FTS_ERR:
                unreadable += 1
                // A folder that couldn't be read comes back this way instead
                // of finished, so it's finished here, with what it has.
                if stack.count > Int(entry.pointee.fts_level) { finish() }
            case FTS_DC, FTS_NS:
                break
            default:
                // A file, a link, or anything else that takes room.
                if let stat, stat.pointee.st_nlink > 1, (stat.pointee.st_mode & S_IFMT) == S_IFREG {
                    guard linked.insert(stat.pointee.st_ino).inserted else { break }
                }
                scanned += own
                guard !stack.isEmpty, own > 0 else { break }
                if own >= smallest {
                    stack[stack.count - 1].add(SpaceItem(name: name(entry), kind: .file, size: own), smallest: smallest)
                } else {
                    // Not made into an item at all: most files are small.
                    stack[stack.count - 1].size += own
                    stack[stack.count - 1].small += own
                    stack[stack.count - 1].smallCount += 1
                }
            }
        }
        if cancelled.value { return nil }
        guard let scannedRoot = root else { return nil }
        // What's used but wasn't counted, as a block of its own beside the folders.
        var top = scannedRoot.children
        if used > scannedRoot.size { top.append(SpaceItem(name: String(localized: "System and other"), kind: .other, size: used - scannedRoot.size)) }
        let volume = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        let named = SpaceItem(name: volume ?? String(localized: "Startup disk"), kind: .folder, size: max(used, scannedRoot.size),
                              children: top, rootPath: path == dataVolume ? "/" : path)
        return Result(root: named, at: Date(), unreadable: unreadable, seconds: ProcessInfo.processInfo.systemUptime - start, items: items)
    }

    // MARK: - Preview

    /// For `--snapshot … stats disk inside`: the map opened at the made-up home folder.
    static var previewInside = false

    /// A made-up disk, for `--snapshot`: nothing from this Mac.
    static func preview() -> DiskSpace {
        // In the units the sizes are shown in, so the figures come out round.
        let gb: Int64 = 1_000_000_000
        func folder(_ name: String, _ size: Int64, _ children: [SpaceItem] = []) -> SpaceItem {
            let counted = children.reduce(0) { $0 + $1.size }
            let all = counted < size && !children.isEmpty
                ? children + [SpaceItem(name: String(localized: "Smaller items"), kind: .smaller(1_240), size: size - counted)] : children
            return SpaceItem(name: name, kind: .folder, size: size, children: all)
        }
        let home = folder("alex", 412 * gb, [
            folder("Movies", 118 * gb, [SpaceItem(name: "Holiday.mov", kind: .file, size: 41 * gb), folder("Final Cut Projects", 62 * gb)]),
            folder("Library", 96 * gb, [folder("Containers", 31 * gb), folder("Application Support", 27 * gb), folder("Caches", 14 * gb),
                                        folder("Developer", 19 * gb)]),
            folder("Pictures", 74 * gb, [folder("Photos Library.photoslibrary", 71 * gb)]),
            folder("Documents", 46 * gb), folder("Downloads", 33 * gb, [SpaceItem(name: "Installer.dmg", kind: .file, size: 12 * gb)]),
            folder("Music", 21 * gb), folder("Projects", 17 * gb), folder("Desktop", 4 * gb),
        ])
        let root = SpaceItem(name: "Macintosh HD", kind: .folder, size: 682 * gb, children: [
            folder("Users", 413 * gb, [home, folder("Shared", 1 * gb)]),
            folder("Applications", 64 * gb), folder("Library", 38 * gb), folder("private", 27 * gb), folder("opt", 9 * gb),
            SpaceItem(name: String(localized: "System and other"), kind: .other, size: 131 * gb),
        ], rootPath: "/")
        let space = DiskSpace()
        space.state = .done(Result(root: root, at: Date().addingTimeInterval(-240), unreadable: 512, seconds: 38, items: 2_400_000))
        space.current = previewInside ? home : root
        return space
    }
}
