import AppKit
import Security

/// New versions, from the project's releases on GitHub. It looks when the
/// app starts and once a day (while that's on), or when asked, and only says
/// so: installing is a click. An update is only installed when it's signed
/// with the same certificate as the app that's running, which is also what
/// keeps macOS's permissions, as they go with the signature. No Apple ID or
/// notarization is involved: the check is against our own certificate.
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        /// The release's notes, Markdown. With versions skipped, each one's
        /// under a `# X.Y.Z` heading, newest first.
        let notes: String
        let archive: URL
        let page: URL
        /// Newer than this copy, this one among them: more than one when
        /// versions were skipped.
        var versions: [String] = []
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date {
        didSet { UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked) }
    }

    /// Looks by itself, at launch and once a day.
    var automatic = false {
        didSet { if automatic != oldValue { schedule() } }
    }

    private enum Keys {
        static let lastChecked = "updatesLastChecked"
        /// Development aid: another place to ask, for the update test.
        static let feed = "updateFeed"
    }

    /// The recent releases, not only the latest: the notes of every version
    /// skipped are shown too.
    private static let releases = URL(string: "https://api.github.com/repos/joafalves/macos-toolkit/releases?per_page=30")!
    private var feed: URL { UserDefaults.standard.string(forKey: Keys.feed).flatMap(URL.init(string:)) ?? Self.releases }
    private var timer: Timer?
    private var launchCheck: DispatchWorkItem?

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// For `--snapshot about available`: a made-up newer release on show.
    func preview(notes: String? = nil) {
        state = .available(Release(version: "9.9.0", notes: notes ?? """
            ### Added

            - **Window Switcher:** something new, in a line or two, wrapped as the changelog
              wraps it.

            ### Fixed

            - **Window Layout:** something that didn't work before.
            """, archive: URL(string: "https://example.invalid/app.zip")!, page: URL(string: "https://example.invalid")!))
    }

    func preview(feed: Data, since version: String) {
        if let release = try? Self.newer(in: feed, than: version) { state = .available(release) }
    }

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    // MARK: - When

    /// A moment after launch, once the rest has started, then every hour a
    /// look at whether a day has passed: a timer that sleeps with the Mac
    /// doesn't come round on time.
    private func schedule() {
        launchCheck?.cancel()
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        let first = DispatchWorkItem { [weak self] in self?.check(quietly: true) }
        launchCheck = first
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: first)
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, self.lastChecked.map({ Date().timeIntervalSince($0) >= 24 * 3600 }) ?? true else { return }
            self.check(quietly: true)
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Checking

    /// Quietly, as by itself: a failure (no network, say) leaves things as
    /// they were rather than showing an error nobody asked for.
    func check(quietly: Bool = false) {
        switch state {
        case .checking, .installing: return
        default: break
        }
        let before = state
        state = .checking
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacOS-Toolkit/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release?, Error> = Result {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200, let data else {
                    throw UpdateError("GitHub didn't answer (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
                }
                return try Self.newer(in: data, than: Self.currentVersion)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let release):
                    self.lastChecked = Date()
                    self.state = release.map(State.available) ?? .upToDate
                case .failure(let error):
                    self.state = quietly ? before : .failed(error.localizedDescription)
                }
            }
        }.resume()
    }

    /// The newest release in GitHub's answer (a list of releases, or one),
    /// if it's newer than `version` and has the app's zip, with the notes of
    /// every release since `version`.
    static func newer(in data: Data, than version: String) throws -> Release? {
        struct Answer: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let body: String?
            let assets: [Asset]
            let draft: Bool?
            let prerelease: Bool?
            var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        }
        let decoder = JSONDecoder()
        let answers: [Answer]
        if let list = try? decoder.decode([Answer].self, from: data) {
            answers = list
        } else {
            answers = [try decoder.decode(Answer.self, from: data)]
        }
        let newer = answers
            .filter { $0.draft != true && $0.prerelease != true && isNewer($0.version, than: version) }
            .sorted { isNewer($0.version, than: $1.version) }
        guard let top = newer.first else { return nil }
        let tag = top.version
        guard let zip = top.assets.first(where: { $0.name == "MacOS-Toolkit-\(tag).zip" }) ?? top.assets.first(where: { $0.name.hasSuffix(".zip") })
        else { throw UpdateError("Version \(tag) has no app to download yet.") }
        let notes = newer.count == 1 ? top.body ?? ""
            : newer.map { "# \($0.version)\n\n\($0.body ?? "")" }.joined(separator: "\n\n")
        return Release(version: tag, notes: notes, archive: zip.browser_download_url, page: top.html_url, versions: newer.map(\.version))
    }

    /// By number, part by part: 0.10.0 comes after 0.9.1.
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    /// Downloads it, checks it, puts it in place of this copy and starts it.
    func install() {
        guard let release = available else { return }
        state = .installing(release)
        let target = Bundle.main.bundleURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.fetch(release, replacing: target) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    Relaunch.now(target, restartingFinder: true)
                case .failure(let error):
                    // Still on offer, to try again or to get by hand.
                    self.state = .available(release)
                    Self.failed(release, error)
                }
            }
        }
    }

    /// The way round it, whatever went wrong: the release page has the app.
    private static func failed(_ release: Release, _ error: Error) {
        NSLog("Toolkit: update to \(release.version) not installed: \(error.localizedDescription)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "The update couldn't be installed")
        alert.informativeText = String(localized: "Download version \(release.version) from its release page and install it by hand.")
        alert.addButton(withTitle: String(localized: "Release Page"))
        alert.addButton(withTitle: String(localized: "OK"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }

    /// The whole way up to the swap, which leaves the running copy's files
    /// open and working until it quits. Off the main thread.
    static func fetch(_ release: Release, replacing target: URL) throws {
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError("\(folder.path) can't be written to, so the update can't be put there. Install it from the release page.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("macos-toolkit-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appendingPathComponent("update.zip")
        try download(release.archive, to: zip)
        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let apps = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw UpdateError("The download has no app in it.") }
        try verify(app, version: release.version)

        // Next to this copy, on the same volume, so the swap is one step.
        let staged = folder.appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent) \(release.version).app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError("The app couldn't be replaced: \(error.localizedDescription)")
        }
    }

    /// The same app, at the release's version, signed by the certificate this
    /// copy is signed with, its Finder extension included. Anything else is
    /// refused: a download that was changed, or signed by someone else.
    static func verify(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't MacOS Toolkit.")
        }
        let found = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard found == version else { throw UpdateError("The download is version \(found), not \(version).") }
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateError("This copy's own signature can't be read.") }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        // Signed ad hoc, its requirement is its own hash, which no other build has.
        guard (text as String?)?.contains("certificate") == true else {
            throw UpdateError("This copy isn't signed with a certificate, so an update can't be checked. Install it from the release page.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The download's signature can't be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError("The download isn't signed with this app's certificate, so it wasn't installed.")
        }
    }

    private static func download(_ url: URL, to destination: URL) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        URLSession.shared.downloadTask(with: url) { file, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let file else {
                failure = UpdateError("The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
                return
            }
            do { try FileManager.default.moveItem(at: file, to: destination) } catch { failure = error }
        }.resume()
        done.wait()
        if let failure { throw failure }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus)).") }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String.LocalizationValue) { self.message = String(localized: message) }
    var errorDescription: String? { message }
}

extension Updater {
    /// `--test-update <feeds> <copy> [report]`: from a folder of made-up
    /// releases served at `feeds` (a local URL; GitHub isn't asked), each
    /// checked and installed over `copy`, a copy of the app: a newer one
    /// signed with this app's certificate replaces it; one changed after
    /// signing, one signed ad hoc and an older one don't, and leave it as it
    /// was. Then the whole check, through the feed setting. Run the app
    /// bundle, so its own signature is the one to match.
    static func selfTest(feeds: URL, copy: URL, report path: String?) {
        _ = NSApplication.shared
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        // From the file: `Bundle` keeps what it read first for a path.
        func version(of app: URL) -> String? {
            NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        }
        func feed(_ name: String) -> Data? {
            let done = DispatchSemaphore(value: 0)
            var data: Data?
            URLSession.shared.dataTask(with: feeds.appendingPathComponent(name)) { d, _, _ in data = d; done.signal() }.resume()
            done.wait()
            return data
        }
        let before = version(of: copy)
        lines.append("     this app \(currentVersion), the copy \(before ?? "missing")")
        check("isNewer: 0.10.0 after 0.9.1, not 0.9.1 after 0.10.0, not the same", isNewer("0.10.0", than: "0.9.1") && !isNewer("0.9.1", than: "0.10.0") && !isNewer("0.18.0", than: "0.18.0"))

        for (name, wants) in [("tampered.json", "refused"), ("adhoc.json", "refused"), ("old.json", "nothing"), ("good.json", "installed")] {
            guard let data = feed(name) else { check("\(name): served", false); continue }
            do {
                guard let release = try newer(in: data, than: currentVersion) else {
                    check("\(name): no update offered", wants == "nothing")
                    continue
                }
                do {
                    try fetch(release, replacing: copy)
                    let now = version(of: copy)
                    check("\(name): installed", wants == "installed" && now == release.version, "the copy is now \(now ?? "missing")")
                } catch {
                    let now = version(of: copy)
                    check("\(name): refused, the copy left as it was", wants == "refused" && now == before, "\(error.localizedDescription) — the copy is \(now ?? "missing")")
                }
            } catch {
                check("\(name): read", false, error.localizedDescription)
            }
        }
        // The installed copy is whole and signed as before.
        var code: SecStaticCode?
        let valid = SecStaticCodeCreateWithPath(copy as CFURL, [], &code) == errSecSuccess && code.map {
            SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), nil) == errSecSuccess
        } == true
        check("the copy's signature holds after the swap, its extension too", valid)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path))?.filter { $0.hasPrefix(".") && $0.hasSuffix(".app") } ?? []
        check("nothing left beside it", leftovers.isEmpty, leftovers.joined(separator: ", "))

        // The check as the app does it, from the feed setting.
        UserDefaults.standard.set(feeds.appendingPathComponent("good.json").absoluteString, forKey: "updateFeed")
        defer { UserDefaults.standard.removeObject(forKey: "updateFeed") }
        let updater = Updater()
        updater.check()
        let deadline = Date().addingTimeInterval(10)
        while updater.state == .checking, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check("a check finds the new version", updater.available?.version == "0.99.0", "\(updater.state)")
        UserDefaults.standard.set(feeds.appendingPathComponent("missing.json").absoluteString, forKey: "updateFeed")
        updater.check(quietly: true)
        while updater.state == .checking, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check("a quiet check that fails leaves what it had", updater.available?.version == "0.99.0", "\(updater.state)")
        updater.check()
        while updater.state == .checking, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if case .failed = updater.state { check("one asked for says it failed", true) } else { check("one asked for says it failed", false, "\(updater.state)") }

        lines.append(failures == 0 ? "all passed" : "\(failures) failed")
        let output = lines.joined(separator: "\n") + "\n"
        print(output, terminator: "")
        if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
