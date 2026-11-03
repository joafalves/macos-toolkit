#if TOOLKIT_DEV
import AppKit

/// `--test-menu-bar-center <report>`: where macOS puts what's drawn in a
/// status item, against macOS's own items, on every display. Items with a
/// 22 pt image (as ours), with one only as tall as what's in it, with a
/// symbol as most apps use, and the toolkit's own item as it's drawn now.
/// Captures each menu bar (Screen Recording: run the app bundle with
/// `open -n`); the pictures go in a scratch folder and are deleted.
enum MenuBarCenterTest {
    static func run(into path: String) {
        _ = NSApplication.shared
        func box(height: CGFloat, mark: CGFloat) -> NSImage {
            let image = NSImage(size: NSSize(width: 14, height: height), flipped: false) { rect in
                NSColor.black.setFill()
                NSRect(x: 2, y: (rect.height - mark) / 2, width: 10, height: mark).fill()
                return true
            }
            image.isTemplate = true
            return image
        }
        func item(_ image: NSImage?) -> NSStatusItem {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleNone
            return item
        }
        let tests: [(String, NSStatusItem?)] = [
            ("22 pt image", item(box(height: 22, mark: 12))),
            ("12 pt image", item(box(height: 12, mark: 12))),
            ("symbol", item(NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil))),
        ]
        let ours = MenuBarItem()
        ours.show([MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit"),
                   MenuBarSegment(kind: .awake, glyph: MenuBarArt.awakeBadge(fraction: 0.6, time: "1:24"), label: "Keep Awake")])
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("menu-bar-center-\(getpid())")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        func bounds(_ info: [String: Any]) -> CGRect? {
            (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        var lines = ["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]

        for (index, screen) in NSScreen.screens.enumerated() {
            let frame = Coordinates.toCG(screen.frame)
            // The menu bar's own window is the bar, whatever the visible frame says.
            guard let bar = windows.compactMap({ info -> CGRect? in
                guard info[kCGWindowLayer as String] as? Int == barLevel, let b = bounds(info), abs(b.minY - frame.minY) < 1,
                      b.minX >= frame.minX - 1, b.maxX <= frame.maxX + 1 else { return nil }
                return b
            }).first else { lines.append("\(screen.localizedName): no menu bar showing"); continue }
            lines.append("\(screen.localizedName): scale \(screen.backingScaleFactor), bar \(bar.height) pt, visible frame stops \(screen.frame.maxY - screen.visibleFrame.maxY) pt down")
            let file = scratch.appendingPathComponent("\(index).png")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-R\(Int(bar.minX)),\(Int(bar.minY)),\(Int(bar.width)),\(Int(bar.height))", file.path]
            try? task.run()
            task.waitUntilExit()
            guard let data = try? Data(contentsOf: file), let picture = NSBitmapImageRep(data: data) else {
                lines.append("  no picture (Screen Recording?)")
                continue
            }
            let scale = CGFloat(picture.pixelsHigh) / bar.height
            func luminance(_ x: Int, _ y: Int) -> CGFloat {
                guard let c = picture.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
                return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            }
            // Each column against the bar's own colour there, at its top and
            // bottom rows, which items leave empty: what differs is drawn.
            let w = picture.pixelsWide, h = picture.pixelsHigh
            func drawn(_ x: Int, _ y: Int) -> Bool {
                abs(luminance(x, y) - (luminance(x, 1) + luminance(x, h - 2)) / 2) > 0.12
            }
            var inked = [Bool](repeating: false, count: w)
            for x in 0..<w { inked[x] = (2..<h - 2).contains { drawn(x, $0) } }
            // Runs of drawn columns, a few pixels of gap allowed inside one icon.
            var runs: [Range<Int>] = []
            var x = 0
            while x < w {
                guard inked[x] else { x += 1; continue }
                var end = x
                while end < w, inked[end] || (end + 1..<min(end + Int(4 * scale), w)).contains(where: { inked[$0] }) { end += 1 }
                runs.append(x..<end)
                x = end
            }
            // Ours by where their windows are; the rest are macOS's and other apps'.
            var places: [(String, ClosedRange<CGFloat>)] = tests.compactMap { name, item in
                item?.button?.window.map { (name, Coordinates.toCG($0.frame).minX...Coordinates.toCG($0.frame).maxX) }
            }
            if let window = ours.button?.window { places.append(("toolkit (now)", Coordinates.toCG(window.frame).minX...Coordinates.toCG(window.frame).maxX)) }
            // Where macOS put each item's window, its place and its button, from the bar's top.
            for (name, item) in tests + [("toolkit (now)", nil)] {
                guard let button = item?.button ?? (item == nil ? ours.button : nil), let window = button.window, let place = button.superview, window.screen == screen else { continue }
                func top(_ view: NSView) -> String {
                    let r = Coordinates.toCG(window.convertToScreen(view.convert(view.bounds, to: nil)))
                    return String(format: "%.1f–%.1f", r.minY - bar.minY, r.maxY - bar.minY)
                }
                let w = Coordinates.toCG(window.frame)
                lines.append(String(format: "  %@: window %.1f–%.1f, place %@, button %@", name as NSString, w.minY - bar.minY, w.maxY - bar.minY, top(place), top(button)))
            }
            for run in runs where run.count > Int(3 * scale) {
                let rows = (2..<h - 2).filter { y in run.contains { drawn($0, y) } }
                guard let top = rows.first, let bottom = rows.last else { continue }
                let left = bar.minX + CGFloat(run.lowerBound) / scale, right = bar.minX + CGFloat(run.upperBound) / scale
                let name = places.first { $0.1.contains((left + right) / 2) }?.0 ?? "other"
                let from = CGFloat(top) / scale, to = CGFloat(bottom + 1) / scale
                lines.append(String(format: "  %@ at x %.0f–%.0f: drawn %.1f–%.1f pt, middle %+.2f pt from the bar's",
                                    name as NSString, left, right, from, to, (from + to) / 2 - bar.height / 2))
            }
        }
        tests.compactMap(\.1).forEach { NSStatusBar.system.removeStatusItem($0) }
        ours.remove()
        let report = lines.joined(separator: "\n") + "\n"
        print(report, terminator: "")
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
