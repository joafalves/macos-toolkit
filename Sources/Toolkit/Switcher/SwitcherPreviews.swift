import AppKit
import ScreenCaptureKit

/// Pictures of windows for the switcher's grid. They're taken only while the
/// switcher is open and kept in memory, at about the size they're shown, so
/// the next time it opens there is something to show straight away.
final class SwitcherPreviews {
    /// Called on the main queue as pictures come in.
    var onUpdate: ((CGWindowID, CGImage) -> Void)?

    private var cache: [CGWindowID: CGImage] = [:]
    private var task: Task<Void, Never>?
    /// The window list, asked for ahead of the pictures (see `prepare`).
    private var content: Task<SCShareableContent?, Never>?
    private(set) var busy = false

    static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    func cached(_ ids: [CGWindowID]) -> [CGWindowID: CGImage] {
        cache.filter { ids.contains($0.key) }
    }

    /// Asks ScreenCaptureKit for its window list, which takes most of the
    /// time before the first picture. Done when the switcher is invoked,
    /// before it shows: it takes no pictures, so a quick ⌘Tab costs little.
    func prepare() {
        content = Task { try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
    }

    /// Takes new pictures of `ids`, `width` pixels wide, replacing any taking
    /// still under way.
    func refresh(_ ids: [CGWindowID], width: Int) {
        task?.cancel()
        guard !ids.isEmpty else { return }
        busy = true
        // The prepared list once; later refreshes (Live) ask again, since
        // windows come and go.
        let pending = content ?? Task { try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        content = nil
        task = Task { [weak self] in
            defer { Task { @MainActor in self?.busy = false } }
            guard let content = await pending.value else { return }
            let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in ids {
                    guard let window = windows[id], window.frame.width > 0, window.frame.height > 0 else { continue }
                    group.addTask { (id, await Self.capture(window, width: width)) }
                }
                for await (id, image) in group {
                    guard !Task.isCancelled else { return }
                    guard let image else { continue }
                    await MainActor.run {
                        self?.cache[id] = image
                        self?.onUpdate?(id, image)
                    }
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        content = nil
        busy = false
    }

    /// Drops pictures of windows that are gone.
    func keep(only ids: Set<CGWindowID>) {
        cache = cache.filter { ids.contains($0.key) }
    }

    private static func capture(_ window: SCWindow, width: Int) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let aspect = window.frame.height / window.frame.width
        config.width = width
        config.height = max(Int(CGFloat(width) * aspect), 1)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.capturesAudio = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
