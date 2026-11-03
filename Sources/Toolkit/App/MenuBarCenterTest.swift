#if TOOLKIT_DEV
import AppKit

/// `--test-menu-bar-center <report>`: where macOS puts what's drawn in a
/// status item, against everyone else's, on every display: a plain 22 pt
/// image, a symbol as most apps use, and the toolkit's own item, with how
/// sharp each one's top and bottom edges are. On a 1x display with a 30 pt
/// bar, macOS puts every item's place a point high: a plain image (ours, and
/// its own clock's) sits there, sharp; a symbol half a point lower, blurred.
/// Captures each menu bar (Screen Recording: run the app bundle with
/// `open -n`); the pictures go in a scratch folder and are deleted.
enum MenuBarCenterTest {
    static func run(into path: String) {
        _ = NSApplication.shared
        func box(height: CGFloat, mark: CGFloat, width: CGFloat = 10) -> NSImage {
            let image = NSImage(size: NSSize(width: width + 4, height: height), flipped: false) { rect in
                NSColor.black.setFill()
                NSRect(x: 2, y: (rect.height - mark) / 2, width: width, height: mark).fill()
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
        let symbol = NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil)
        // A symbol's half-point alignment rect, drawn straight to the screen
        // (not cached) with its edges put on whole pixels where it lands.
        func snapped(width: CGFloat, cache: NSImage.CacheMode) -> NSImage {
            let image = NSImage(size: NSSize(width: width + 4, height: 22), flipped: false) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                let device = context.userSpaceToDeviceSpaceTransform
                let off = device.ty - device.ty.rounded(.down)
                if off > 0.01, off < 0.99, device.d != 0 { context.translateBy(x: 0, y: -off / device.d) }
                NSColor.black.setFill()
                NSRect(x: 2, y: 5, width: width, height: 12).fill()
                return true
            }
            image.isTemplate = true
            image.cacheMode = cache
            image.alignmentRect = NSRect(x: 0, y: 0.5, width: image.size.width, height: 21)
            return image
        }
        let tests: [(String, NSStatusItem?)] = [
            ("22 pt image", item(box(height: 22, mark: 12))),
            ("symbol", item(symbol)),
            ("aligned, cached (6 wide)", item(snapped(width: 6, cache: .default))),
            ("aligned, never cached (8 wide)", item(snapped(width: 8, cache: .never))),
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
                // How strong the first and last drawn rows are against the strongest:
                // about 100% for an edge on a pixel, about half for one between two (blurred).
                func strength(_ y: Int) -> CGFloat {
                    run.map { abs(luminance($0, y) - (luminance($0, 1) + luminance($0, h - 2)) / 2) }.max() ?? 0
                }
                let strongest = rows.map(strength).max() ?? 1
                let edges = (strength(top) / max(strongest, 0.01), strength(bottom) / max(strongest, 0.01))
                lines.append(String(format: "  %@ at x %.0f–%.0f: drawn %.1f–%.1f pt, middle %+.2f pt from the bar's, edges %.0f%% %.0f%%",
                                    name as NSString, left, right, from, to, (from + to) / 2 - bar.height / 2, edges.0 * 100, edges.1 * 100))
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

#if TOOLKIT_DEV
/// `--test-menu-bar-focus <report> [rounds]`: the same items with the focus on
/// each display in turn (a small window of ours on it, in front), each bar
/// captured every time: where each item is drawn and how sharp, so an item
/// that moves as the focus moves shows. Items are told apart by their width,
/// on any display, the item itself or macOS's copy of it.
enum MenuBarFocusTest {
    struct Probe {
        let name: String
        let width: CGFloat
        let item: AnyObject
    }

    /// Events handed to windows as an app's own loop does: a click has to
    /// reach the window for its display to become the active one.
    private static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private static var current = ""

    /// Where to keep each bar's picture, named by focus and display, when set.
    static var keep: URL?

    static func run(into path: String, rounds: Int) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        func box(_ width: CGFloat, alignment: NSRect? = nil) -> NSImage {
            let image = NSImage(size: NSSize(width: width + 4, height: 22), flipped: false) { _ in
                NSColor.black.setFill()
                NSRect(x: 2, y: 5, width: width, height: 12).fill()
                return true
            }
            image.isTemplate = true
            if let alignment { image.alignmentRect = alignment }
            return image
        }
        func plain(_ image: NSImage?) -> NSStatusItem {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleNone
            return item
        }
        let symbol = NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil)
        let toolkit = MenuBarItem()
        toolkit.show([MenuBarSegment(kind: .toolkit, glyph: box(9), label: "probe")])
        let probes = [
            Probe(name: "plain 22 pt image", width: 5, item: plain(box(5))),
            Probe(name: "toolkit item", width: 9, item: toolkit),
            Probe(name: "symbol", width: 12, item: plain(symbol)),
        ]
        pump(2)
        var lines = ["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("menu-bar-focus-\(getpid())")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let pointer = CGEvent(source: nil)?.location
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }
        for round in 1...max(rounds, 1) {
            for focus in NSScreen.screens {
                let frame = NSRect(x: focus.visibleFrame.midX - 100, y: focus.visibleFrame.midY - 60, width: 200, height: 120)
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false, screen: focus)
                window.setFrame(window.frameRect(forContentRect: frame), display: true)
                window.isReleasedWhenClosed = false
                window.title = "Menu bar focus test"
                // Above every other window, so the click below can only land on it.
                window.level = .floating
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                pump(0.5)
                // A click of its own, in its window: what moves the active menu bar, as a person's does.
                let point = CGPoint(x: Coordinates.toCG(window.frame).midX, y: Coordinates.toCG(window.frame).midY)
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                pump(1.5)
                current = "\(round)-\(focus.localizedName.prefix(4))"
                lines.append("round \(round), focus on \(focus.localizedName): key window on \(NSApp.keyWindow?.screen?.localizedName ?? "none"), main screen \(NSScreen.main?.localizedName ?? "?"), toolkit item's window on \(toolkit.button?.window?.screen?.localizedName ?? "?"), trusted \(AXIsProcessTrusted())")
                for screen in NSScreen.screens {
                    lines += measure(screen, probes: probes, in: scratch).map { "  " + $0 }
                }
                window.close()
            }
        }
        for probe in probes {
            if let item = probe.item as? NSStatusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        toolkit.remove()
        let report = lines.joined(separator: "\n") + "\n"
        print(report, terminator: "")
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The bar on this display, captured, and each probe found on it by width.
    private static func measure(_ screen: NSScreen, probes: [Probe], in scratch: URL) -> [String] {
        let frame = Coordinates.toCG(screen.frame)
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let bar = windows.compactMap({ info -> CGRect? in
            guard info[kCGWindowLayer as String] as? Int == level,
                  let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  abs(b.minY - frame.minY) < 1, b.midX > frame.minX, b.midX < frame.maxX else { return nil }
            return b
        }).first else { return ["\(screen.localizedName): no menu bar"] }
        let file = scratch.appendingPathComponent("\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R\(Int(bar.minX)),\(Int(bar.minY)),\(Int(bar.width)),\(Int(bar.height))", file.path]
        try? task.run()
        task.waitUntilExit()
        guard let data = try? Data(contentsOf: file), let picture = NSBitmapImageRep(data: data) else { return ["\(screen.localizedName): no picture"] }
        if let keep { try? data.write(to: keep.appendingPathComponent("focus \(current), bar \(screen.localizedName.prefix(4)).png")) }
        let scale = CGFloat(picture.pixelsHigh) / bar.height, w = picture.pixelsWide, h = picture.pixelsHigh
        func luminance(_ x: Int, _ y: Int) -> CGFloat {
            guard let c = picture.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        }
        func strength(_ x: Int, _ y: Int) -> CGFloat { abs(luminance(x, y) - (luminance(x, 1) + luminance(x, h - 2)) / 2) }
        var inked = [Bool](repeating: false, count: w)
        for x in 0..<w { inked[x] = (2..<h - 2).contains { strength(x, $0) > 0.12 } }
        var runs: [Range<Int>] = []
        var x = 0
        while x < w {
            guard inked[x] else { x += 1; continue }
            var end = x
            while end < w, inked[end] { end += 1 }
            runs.append(x..<end)
            x = end
        }
        var lines: [String] = []
        for probe in probes {
            // Items are laid out from the right end of the bar, the same on
            // every display: where it is on the one it's on, as far from the end here.
            let button = (probe.item as? NSStatusItem)?.button ?? (probe.item as? MenuBarItem)?.button
            guard let window = button?.window, let home = window.screen else { continue }
            let fromEnd = home.frame.maxX - window.frame.midX
            let expected = (screen.frame.maxX - fromEnd - screen.frame.minX) * scale
            // Nearest where it should be, and as wide as it is (a symbol's ink is about 12).
            let wide = runs.filter { abs(CGFloat($0.count) / scale - probe.width) <= (probe.width == 12 ? 2 : 0.5) }
            guard let run = wide.min(by: { abs(CGFloat($0.lowerBound + $0.upperBound) / 2 - expected) < abs(CGFloat($1.lowerBound + $1.upperBound) / 2 - expected) }),
                  abs(CGFloat(run.lowerBound + run.upperBound) / 2 - expected) < 40 * scale else {
                let near = runs.filter { abs(CGFloat($0.lowerBound + $0.upperBound) / 2 - expected) < 40 * scale }
                    .map { String(format: "%.1f wide at %+.0f", CGFloat($0.count) / scale, (CGFloat($0.lowerBound + $0.upperBound) / 2 - expected) / scale) }
                lines.append("\(screen.localizedName) \(probe.name): not found; near it: \(near.joined(separator: ", "))")
                continue
            }
            let rows = (2..<h - 2).filter { y in run.contains { strength($0, y) > 0.12 } }
            guard let top = rows.first, let bottom = rows.last else { continue }
            let strongest = rows.map { y in run.map { strength($0, y) }.max() ?? 0 }.max() ?? 1
            let edge = { (y: Int) in (run.map { strength($0, y) }.max() ?? 0) / max(strongest, 0.01) * 100 }
            let from = CGFloat(top) / scale, to = CGFloat(bottom + 1) / scale
            lines.append(String(format: "%@ %@ (%@): middle %+.2f pt, edges %.0f%% %.0f%%", screen.localizedName, probe.name,
                                home == screen ? "the item" : "macOS's copy", (from + to) / 2 - bar.height / 2, edge(top), edge(bottom)))
        }
        return lines
    }
}
#endif
