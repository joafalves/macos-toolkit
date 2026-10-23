import Foundation

/// macOS's own Show Desktop, as its gesture or F11 does it: the windows slide
/// to the edges, and come back where they were the next time (or with a
/// click on one). macOS moves them, not us, so nothing about them changes:
/// snapped windows are still snapped when they come back. Through the Dock's
/// private notification, looked up at run time so a macOS without it only
/// means the shortcut does nothing.
enum ShowDesktop {
    private typealias Send = @convention(c) (CFString, Int32) -> Void

    private static let send: Send? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let symbol = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: Send.self)
    }()

    /// On if it was off, off if it was on. False if macOS has no way to ask.
    @discardableResult
    static func toggle() -> Bool {
        guard let send else { return false }
        send("com.apple.showdesktop.awake" as CFString, 0)
        return true
    }
}
