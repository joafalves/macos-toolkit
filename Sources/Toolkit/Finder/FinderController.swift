import AppKit
import ApplicationServices

/// Small additions to Finder. Cut is done by watching the keyboard while Finder
/// is in front: Finder has no Cut, so ⌘X is ⌘C now and "Move Item Here" (⌥⌘V)
/// at the next ⌘V. The right-click menu items come from the Finder extension,
/// which hands them to `handle(_:)`.
final class FinderController: ObservableObject {
    @Published var config: FinderConfig {
        didSet {
            guard config != oldValue else { return }
            if persists { config.save() }
            if !config.enabled || !config.cut { cutMark = nil }
            apply()
        }
    }

    /// Accessibility is granted but macOS still refused the event tap; this
    /// happens when the grant predates the running process.
    @Published private(set) var tapFailed = false

    /// Whether the Finder extension is switched on. macOS keeps it off until
    /// the user turns it on.
    @Published private(set) var extensionEnabled = false

    private static let extensionID = "dev.jalves.macos-toolkit.finder"

    /// False for `--snapshot`, which shows default settings and a working
    /// setup without reading or writing anything of the user's.
    private var persists = true
    private(set) var isPreview = false

    static func preview() -> FinderController {
        let finder = FinderController()
        finder.persists = false
        finder.isPreview = true
        finder.config = FinderConfig()
        finder.extensionEnabled = true
        return finder
    }

    private enum Key {
        static let x: Int64 = 7, c: Int64 = 8, v: Int64 = 9, enter: Int64 = 36
    }

    /// Stamped on the keys we post, so the tap lets them through.
    private static let marker: Int64 = 0x46494E44
    private static let finder = "com.apple.finder"

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?

    /// The pasteboard's change count right after the copy that ⌘X made. While
    /// the pasteboard still has that count, the next ⌘V in Finder is a move.
    private var cutMark: Int?
    /// The key whose press we took, so its repeats and its release are taken too.
    private var heldKey: Int64?

    init() {
        config = FinderConfig.load()
    }

    // MARK: - Lifecycle

    func start() {
        writeToken()
        refreshExtension()
        apply()
        // Accessibility may be granted after launch.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.apply() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asks pluginkit, whose listing starts with "+" when the extension is on.
    /// Not `FIFinderSyncController.isExtensionEnabled`: that starts an instance
    /// of the extension, and Finder shows the menu items once per instance.
    func refreshExtension() {
        guard !isPreview else { return }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", Self.extensionID]
        process.standardOutput = output
        process.terminationHandler = { [weak self] _ in
            let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let enabled = listing.hasPrefix("+")
            DispatchQueue.main.async {
                if self?.extensionEnabled != enabled { self?.extensionEnabled = enabled }
            }
        }
        try? process.run()
    }

    /// The same switch as the one in System Settings, which is hard to find.
    func enableExtension() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-e", "use", "-i", Self.extensionID]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshExtension() }
        }
        try? process.run()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        uninstall()
    }

    private func apply() {
        guard config.enabled, config.cut else { return uninstall() }
        guard tap == nil, AXIsProcessTrusted() else { return }
        let installed = installTap()
        NSLog("Toolkit: finder event tap started = \(installed)")
        if tapFailed == installed { tapFailed = !installed }
    }

    private func uninstall() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        self.tap = nil
        runLoopSource = nil
        heldKey = nil
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let controller = Unmanaged<FinderController>.fromOpaque(refcon!).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    // MARK: - Keyboard

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            heldKey = nil
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return pass }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            guard heldKey == code else { return pass }
            heldKey = nil
            return nil
        }
        if heldKey == code { return nil }

        // Cmd alone: other combinations belong to Finder.
        let flags = event.flags
        guard code == Key.x || code == Key.v, flags.contains(.maskCommand),
              flags.isDisjoint(with: [.maskShift, .maskAlternate, .maskControl])
        else { return pass }

        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == Self.finder,
              !Self.isEditingText(in: app.processIdentifier)
        else { return pass }

        if code == Key.x {
            cut()
        } else {
            guard let mark = cutMark, mark == NSPasteboard.general.changeCount else {
                cutMark = nil
                return pass
            }
            cutMark = nil
            Self.post(key: Key.v, flags: [.maskCommand, .maskAlternate])
        }
        heldKey = code
        return nil
    }

    /// Copies the selection, and remembers that it was meant as a cut.
    private func cut() {
        cutMark = nil
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        Self.post(key: Key.c, flags: .maskCommand)
        // Finder fills the pasteboard a moment later. Nothing selected means
        // it never does, and then there is nothing to move. Finder can't mark
        // the files as cut, so a sound says it worked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, pasteboard.changeCount != before,
                  pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            else { return }
            self.cutMark = pasteboard.changeCount
            NSSound(named: "Pop")?.play()
        }
    }

    // MARK: - Right-click menu

    // MARK: - The URL scheme's token

    /// A new secret for each launch, which the extension puts in every URL it
    /// sends. Any app or web page can open a `macos-toolkit:` URL; only the
    /// extension (and this user's own processes) can read the token.
    private var token = ""

    private static var tokenURL: URL {
        FinderConfig.fileURL.deletingLastPathComponent().appendingPathComponent("finder-token")
    }

    private func writeToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        let url = Self.tokenURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable by this user only.
        guard FileManager.default.createFile(atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        token = value
    }

    /// Compares every byte, so how long a wrong guess takes says nothing.
    private static func same(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// An action from the Finder extension: `macos-toolkit://<action>?token=…&target=<folder>&item=<path>`,
    /// where target is the folder Finder shows and item the first selected item, if any.
    func handle(_ url: URL) {
        // Only from the extension (it knows the token), and only while Finder
        // is in front, as it is right after its menu.
        guard config.enabled, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finder,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              Self.same(parts.queryItems?.first(where: { $0.name == "token" })?.value ?? "", token)
        else { return }
        func path(_ name: String) -> URL? {
            parts.queryItems?.first { $0.name == name }?.value.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        let item = path("item"), target = path("target")
        // Only ever a real folder: a terminal asked to open a file runs it.
        let folder = [item.flatMap { Self.isFolder($0) ? $0 : nil }, item?.deletingLastPathComponent(), target]
            .compactMap { $0 }.first(where: Self.isFolder)
        switch parts.host {
        case "cut" where config.cut:
            cut()
        case "new-file" where config.newTextFile:
            // Next to the item that was clicked, which may be in an expanded subfolder.
            if let folder = [item?.deletingLastPathComponent(), target].compactMap({ $0 }).first(where: Self.isFolder) {
                newTextFile(in: folder)
            }
        case "terminal" where config.openInTerminal:
            if let folder { openInTerminal(folder) }
        default:
            break
        }
    }

    /// Makes an empty "untitled.txt" (or "untitled 2.txt", ...) and starts renaming it.
    private func newTextFile(in folder: URL) {
        let files = FileManager.default
        var url = folder.appendingPathComponent("untitled.txt")
        var number = 2
        while files.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("untitled \(number).txt")
            number += 1
        }
        guard files.createFile(atPath: url.path, contents: Data()) else {
            NSLog("Toolkit: could not create \(url.path)")
            return NSSound.beep()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        // Return in Finder renames the selection. Finder needs a moment to show
        // the new file, and posting the key needs Accessibility.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard AXIsProcessTrusted(),
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finder
            else { return }
            Self.post(key: Key.enter, flags: [])
        }
    }

    private func openInTerminal(_ folder: URL) {
        let terminal = Terminals.resolve(config.terminal)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.id) else { return NSSound.beep() }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    private static func post(key: Int64, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down) else { return }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Whether Finder's keyboard focus is a text field (renaming, searching),
    /// where ⌘X and ⌘V mean text. Anything unclear counts as yes, so a slow or
    /// failing Finder never gets a key taken from it.
    private static func isEditingText(in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        // With no focused element (the desktop, say) there is no text to edit.
        if result == .noValue { return false }
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return true }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String
        else { return true }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }
}
