import AppKit

extension NSRunningApplication {
    /// The app that owns the topmost window at `point`, in global coordinates
    /// from the top of the main display. Only normal windows (layer 0) count:
    /// the Dock keeps an invisible window over the whole screen on a higher
    /// layer, and menus and panels belong to whatever is under them.
    static func owningWindow(at point: CGPoint) -> NSRunningApplication? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point)
            else { continue }
            return (window[kCGWindowOwnerPID as String] as? pid_t).flatMap { NSRunningApplication(processIdentifier: $0) }
        }
        return nil
    }
}
