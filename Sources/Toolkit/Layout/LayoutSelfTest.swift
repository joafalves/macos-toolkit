import AppKit
import ScreenCaptureKit
import Carbon.HIToolbox

extension LayoutController {
    /// `--test-layout [report]`: checks the geometry, then places two windows
    /// of a helper process through Accessibility (so no real app's windows
    /// are touched) and compares where they land with where they should.
    static func selfTest(report path: String?) {
        _ = NSApplication.shared
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : "  \(detail())")")
        }
        func text(_ r: CGRect?) -> String {
            guard let r else { return "nil" }
            return "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))"
        }

        // Geometry, on made-up displays: a laptop with a wide display to its right.
        let laptop = LayoutDisplay(id: 1, uuid: "a", name: "A", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   usable: CGRect(x: 0, y: 33, width: 1512, height: 949))
        let wide = LayoutDisplay(id: 2, uuid: "b", name: "B", frame: CGRect(x: 1512, y: -200, width: 3440, height: 1440),
                                 usable: CGRect(x: 1512, y: -175, width: 3440, height: 1415))
        let pair = [laptop, wide]
        let half = LayoutGeometry.place(CGRect(x: 0, y: 0, width: 0.5, height: 1), in: laptop.usable, gap: 10)
        let other = LayoutGeometry.place(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), in: laptop.usable, gap: 10)
        check("gap at the edges", half.minX == 10 && half.minY == 43 && half.maxY == 972, text(half))
        check("gap between halves", other.minX - half.maxX == 10, "\(text(half)) \(text(other))")
        check("thirds run down a portrait display", LayoutGeometry.unit(for: .firstThird, portrait: true) == CGRect(x: 0, y: 0, width: 1, height: 1.0 / 3))
        check("left edge is a half", LayoutGeometry.edgeZone(at: CGPoint(x: 1, y: 500), in: pair)?.1 == .leftHalf)
        check("top left corner is a quarter", LayoutGeometry.edgeZone(at: CGPoint(x: 3, y: 10), in: pair)?.1 == .topLeft)
        check("top edge maximizes", LayoutGeometry.edgeZone(at: CGPoint(x: 700, y: 0), in: pair)?.1 == .maximize)
        check("edge shared with a display snaps in a wider strip", LayoutGeometry.edgeZone(at: CGPoint(x: 1505, y: 500), in: pair)?.1 == .rightHalf)
        check("but not further in", LayoutGeometry.edgeZone(at: CGPoint(x: 1480, y: 500), in: pair) == nil)
        check("bottom edge is the bottom half", LayoutGeometry.edgeZone(at: CGPoint(x: 700, y: 981), in: pair)?.1 == .bottomHalf)
        check("the menu bar is the top edge", LayoutGeometry.edgeZone(at: CGPoint(x: 700, y: 20), in: pair)?.1 == .maximize)
        check("and just below it", LayoutGeometry.edgeZone(at: CGPoint(x: 700, y: 37), in: pair)?.1 == .maximize)
        check("but not further down", LayoutGeometry.edgeZone(at: CGPoint(x: 700, y: 45), in: pair) == nil)
        check("a corner reaches into the menu bar", LayoutGeometry.edgeZone(at: CGPoint(x: 2, y: 45), in: pair)?.1 == .topLeft)
        check("an outer edge has the narrow strip", LayoutGeometry.edgeZone(at: CGPoint(x: 6, y: 500), in: pair)?.1 == .leftHalf)
        check("and no more", LayoutGeometry.edgeZone(at: CGPoint(x: 12, y: 500), in: pair) == nil)
        check("a shared edge has the wide strip", LayoutGeometry.edgeZone(at: CGPoint(x: 1490, y: 500), in: pair)?.1 == .rightHalf)
        check("the wide display's right edge snaps", LayoutGeometry.edgeZone(at: CGPoint(x: 4951, y: 500), in: pair)?.1 == .rightHalf)
        check("wide display's left neighbour", LayoutGeometry.neighbour(of: wide, .left, in: pair)?.id == laptop.id)
        check("a display gets halves", GridSize.suggested(for: laptop.frame.size) == GridSize(columns: 2, rows: 1))
        check("an ultrawide gets quarters", GridSize.suggested(for: wide.frame.size) == GridSize(columns: 4, rows: 1))
        // Stopping at the edge between displays. While held, the cursor
        // doesn't move, so events keep coming at the held point and only
        // their movement says where the mouse went. The first event after
        // a catch carries the catch itself and is ignored.
        let none = CGVector.zero
        let edgePoint = CGPoint(x: 1511, y: 500)
        func caught(_ displays: [LayoutDisplay] = pair) -> EdgeHold {
            var hold = EdgeHold()
            _ = hold.step(CGPoint(x: 1400, y: 500), delta: none, in: displays, now: 0)
            _ = hold.step(CGPoint(x: 1509, y: 500), delta: CGVector(dx: 3, dy: 0), in: displays, now: 0.01)
            return hold
        }
        func push(_ hold: inout EdgeHold, by delta: CGVector, every step: TimeInterval, from t0: TimeInterval) -> (Int, EdgeHold.Step) {
            var held = 0
            var t = t0
            while held < 500 {
                let result = hold.step(edgePoint, delta: delta, in: pair, now: t)
                guard case .hold(let p) = result, p == edgePoint else { return (held, result) }
                held += 1
                t += step
            }
            return (held, .free)
        }
        var hold = EdgeHold()
        _ = hold.step(CGPoint(x: 1400, y: 500), delta: none, in: pair, now: 0)
        check("away from the edge: free", hold.step(CGPoint(x: 1450, y: 500), delta: CGVector(dx: 5, dy: 0), in: pair, now: 0.01) == .free)
        check("caught right at the edge, on this side", hold.step(CGPoint(x: 1509, y: 500), delta: CGVector(dx: 3, dy: 0), in: pair, now: 0.02) == .hold(edgePoint))
        check("the event after the catch doesn't let go", hold.step(edgePoint, delta: CGVector(dx: -2, dy: 0), in: pair, now: 0.03) == .hold(edgePoint))
        let (steady, crossed) = push(&hold, by: CGVector(dx: 9, dy: 1), every: 0.01, from: 1)
        check("a steady push, a little wobbly, stays put and crosses after a fifth of a second", steady == 20, "held for \(steady) events")
        check("just over the edge", crossed == .release(CGPoint(x: 1513, y: 500)), "\(crossed)")
        check("then it moves freely there", hold.step(CGPoint(x: 1530, y: 500), delta: CGVector(dx: 5, dy: 0), in: pair, now: 2) == .free)
        check("once through, going back isn't held", hold.step(CGPoint(x: 1510, y: 500), delta: CGVector(dx: -20, dy: 0), in: pair, now: 2.1) == .free)
        check("nor going forward again", hold.step(CGPoint(x: 1513, y: 500), delta: CGVector(dx: 3, dy: 0), in: pair, now: 2.2) == .free)
        var next = EdgeHold()
        _ = next.step(CGPoint(x: 1400, y: 500), delta: none, in: pair, now: 3)
        check("the next drag holds again", next.step(CGPoint(x: 1509, y: 500), delta: CGVector(dx: 3, dy: 0), in: pair, now: 3.1) == .hold(edgePoint))

        var along = caught()
        _ = along.step(edgePoint, delta: none, in: pair, now: 0.02)
        check("moving along the edge lets the cursor move", along.step(edgePoint, delta: CGVector(dx: 1, dy: 7), in: pair, now: 0.03) == .release(nil))
        var back = caught()
        _ = back.step(edgePoint, delta: none, in: pair, now: 0.02)
        check("moving back lets go at once", back.step(edgePoint, delta: CGVector(dx: -4, dy: 0), in: pair, now: 0.03) == .release(nil))
        check("pushing again catches it again", back.step(CGPoint(x: 1513, y: 520), delta: CGVector(dx: 4, dy: 0), in: pair, now: 0.04) == .hold(CGPoint(x: 1511, y: 520)))

        var flick = EdgeHold()
        _ = flick.step(CGPoint(x: 1400, y: 500), delta: none, in: pair, now: 0)
        check("a flick past the edge in one jump is caught at it", flick.step(CGPoint(x: 1700, y: 500), delta: CGVector(dx: 300, dy: 0), in: pair, now: 0.01) == .hold(edgePoint))
        _ = flick.step(edgePoint, delta: none, in: pair, now: 0.02)
        let (fast, _) = push(&flick, by: CGVector(dx: 300, dy: 0), every: 0.01, from: 1)
        check("and held as long as a steady push", fast == 20, "held for \(fast) events")

        var open = EdgeHold()
        _ = open.step(CGPoint(x: 100, y: 500), delta: none, in: pair, now: 0)
        check("an outer edge doesn't hold", open.step(CGPoint(x: 1, y: 500), delta: CGVector(dx: -3, dy: 0), in: pair, now: 0.01) == .free)

        let stacked = [LayoutDisplay(id: 5, uuid: "t", name: "T", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), usable: CGRect(x: 0, y: 33, width: 1512, height: 949)),
                       LayoutDisplay(id: 6, uuid: "u", name: "U", frame: CGRect(x: 0, y: 982, width: 1512, height: 982), usable: CGRect(x: 0, y: 1015, width: 1512, height: 949))]
        var down = EdgeHold()
        _ = down.step(CGPoint(x: 700, y: 500), delta: none, in: stacked, now: 0)
        check("stacked: caught at the bottom edge", down.step(CGPoint(x: 700, y: 979), delta: CGVector(dx: 0, dy: 3), in: stacked, now: 0.01) == .hold(CGPoint(x: 700, y: 981)))
        _ = down.step(CGPoint(x: 700, y: 981), delta: none, in: stacked, now: 0.02)
        check("pushing down with a little sideways stays put", down.step(CGPoint(x: 700, y: 981), delta: CGVector(dx: 2, dy: 8), in: stacked, now: 0.03) == .hold(CGPoint(x: 700, y: 981)))
        // macOS's settings, remembered and put back, on a made-up domain and file.
        let realDomain = SystemTiling.domain, realFile = SystemTiling.savedURL
        let testDomain = "dev.jalves.macos-toolkit.selftest.tiling" as CFString
        SystemTiling.domain = testDomain
        SystemTiling.savedURL = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-selftest-tiling.json")
        try? FileManager.default.removeItem(at: SystemTiling.savedURL)
        func put(_ key: String, _ on: Bool?) {
            CFPreferencesSetValue(key as CFString, on.map { NSNumber(value: $0) }, testDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        let margins = SystemTiling.marginsKey, edge = SystemTiling.dragKeys[0]
        put(margins, true)
        put(edge, nil)
        SystemTiling.change([margins: false, edge: false])
        check("margins off, edge tiling off", SystemTiling.value(margins) == false && SystemTiling.value(edge) == false)
        SystemTiling.change([margins: true])
        SystemTiling.change([margins: false])
        SystemTiling.restore([margins])
        check("margins back as they were first, the rest still changed", SystemTiling.value(margins) == true && SystemTiling.value(edge) == false)
        SystemTiling.restore()
        check("edge tiling back to never set", SystemTiling.value(edge) == nil)
        check("nothing left to put back", !FileManager.default.fileExists(atPath: SystemTiling.savedURL.path))
        put(margins, false)
        SystemTiling.change([margins: false])
        check("a key already right isn't remembered", !FileManager.default.fileExists(atPath: SystemTiling.savedURL.path))
        put(margins, true)
        SystemTiling.change([margins: false, edge: false])
        SystemTiling.hand([edge: true])
        SystemTiling.restore()
        check("handed back stays, the rest is put back", SystemTiling.value(edge) == true && SystemTiling.value(margins) == true)
        put(margins, nil)
        put(edge, nil)
        CFPreferencesSynchronize(testDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // The made-up domain leaves an empty file behind otherwise.
        let leftover = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(testDomain).plist")
        try? FileManager.default.removeItem(at: leftover)
        SystemTiling.domain = realDomain
        SystemTiling.savedURL = realFile

        // Tabs: where the windows and the tabs go in a slot.
        let slotRect = CGRect(x: 0, y: 30, width: 1000, height: 800)
        check("tab strip at the bottom: the windows above it", TabGeometry.member(in: slotRect, style: .strip, position: .bottom) == CGRect(x: 0, y: 30, width: 1000, height: 762))
        check("and the strip along the bottom edge", TabGeometry.tabs(in: slotRect, style: .strip, position: .bottom, count: 3) == CGRect(x: 0, y: 796, width: 1000, height: 34))
        check("tab strip at the top: the windows below it", TabGeometry.member(in: slotRect, style: .strip, position: .top).minY == 68)
        // With the pill back (see TabsStyle):
        // check("a pill leaves the windows the whole slot", TabGeometry.member(in: slotRect, style: .pill, position: .bottom) == slotRect)
        // check("a pill is as wide as its icons, centred", TabGeometry.tabs(in: slotRect, style: .pill, position: .bottom, count: 3).width == 102)
        // and TabGeometry.index(at: 40, width: 102, count: 3, style: .pill) == 1 below.
        check("clicks find the tab under them", TabGeometry.index(at: 600, width: 1000, count: 3, style: .strip) == 2
              && TabGeometry.index(at: 990, width: 1000, count: 3, style: .strip) == nil)

        // What's left after a drop, for the suggestions.
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        check("beside the left half: the right half", LayoutGeometry.complement(of: left) == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        check("beside the bottom third: the top two thirds",
              LayoutGeometry.complement(of: CGRect(x: 0, y: 2.0 / 3, width: 1, height: 1.0 / 3)).map { abs($0.height - 2.0 / 3) < 0.001 && $0.minY == 0 } ?? false)
        check("beside a quarter: nothing clean", LayoutGeometry.complement(of: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)) == nil)
        check("beside the whole display: nothing", LayoutGeometry.complement(of: CGRect(x: 0, y: 0, width: 1, height: 1)) == nil)
        let rightHalf = LayoutGeometry.place(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), in: laptop.usable, gap: 8)
        let shown = [SnapAssist.OnScreen(id: 1, frame: LayoutGeometry.place(left, in: laptop.usable, gap: 8)),
                     SnapAssist.OnScreen(id: 2, frame: CGRect(x: 300, y: 200, width: 600, height: 400)),
                     SnapAssist.OnScreen(id: 3, frame: CGRect(x: 2000, y: 200, width: 600, height: 400)),
                     SnapAssist.OnScreen(id: 4, frame: rightHalf.insetBy(dx: 3, dy: 3))]
        check("a slot with a window in it is filled", SnapAssist.filled(rightHalf, by: shown, except: [1]))
        check("not by the window just dropped", !SnapAssist.filled(rightHalf, by: Array(shown.prefix(3)), except: [1]))
        let maximized = SnapAssist.OnScreen(id: 9, frame: LayoutGeometry.place(CGRect(x: 0, y: 0, width: 1, height: 1), in: laptop.usable, gap: 8))
        check("nor by one in the slot but under a maximized window", !SnapAssist.filled(rightHalf, by: [shown[0], maximized, shown[3]], except: [1]))
        check("but by one in front of it", SnapAssist.filled(rightHalf, by: [shown[0], shown[3], maximized], except: [1]))
        func row(_ id: CGWindowID, _ state: SwitcherItem.State = .window) -> SwitcherItem {
            SwitcherItem(id: "w\(id)", window: id, pid: 1, title: "\(id)", appName: "App", icon: nil, state: state)
        }
        let offered = SnapAssist.candidates([row(4), row(2), row(3), row(1), row(5, .minimized), row(6)],
                                            onScreen: shown, on: laptop, in: pair, excluding: [1])
        check("offered, always: this display's open windows first, then the other display's, not the dropped one",
              offered.compactMap(\.window) == [4, 2, 3], "\(offered.compactMap(\.window))")
        let only = SnapAssist.candidates([row(4), row(2), row(3)], onScreen: shown, on: laptop, in: pair, excluding: [1], from: .display)
        check("this display only: not the other display's", only.compactMap(\.window) == [4, 2])
        let fallback = SnapAssist.candidates([row(4), row(2), row(3)], onScreen: shown, on: laptop, in: pair, excluding: [1], from: .fallback)
        check("if none here, with some here: just this display's", fallback.compactMap(\.window) == [4, 2])
        let elsewhere = SnapAssist.candidates([row(4), row(2), row(3)], onScreen: shown, on: wide, in: pair, excluding: [1, 3], from: .fallback)
        check("if none here, with none here: the other display's", elsewhere.compactMap(\.window) == [4, 2], "\(elsewhere.compactMap(\.window))")
        let picker = SlotPicker(display: laptop, pointer: CGPoint(x: 700, y: 500))
        check("layouts bar sits above the pointer", picker.frame.maxY <= 500 - 20 && picker.frame.contains(CGPoint(x: 700, y: picker.frame.midY)))
        check("or below it near the top", SlotPicker(display: laptop, pointer: CGPoint(x: 700, y: 60)).frame.minY > 60)
        let halves = picker.tiles[1]
        check("left of the halves picks the left half", picker.hit(CGPoint(x: halves.minX + 5, y: halves.midY)) == SlotPicker.Hit(layout: 1, zone: 0))
        check("between the miniatures picks nothing", picker.hit(CGPoint(x: halves.maxX + 3, y: halves.midY)) == nil)
        check("an ultrawide gets fourths too", SlotPicker.layouts(for: wide).count == SlotPicker.layouts(for: laptop).count + 2)
        let grid = GridSize(columns: 4, rows: 3)
        check("Q is the top left cell", GridKeys.cell(for: 12, in: grid) == CellRange.Cell(column: 0, row: 0))
        check("V is the bottom right cell", GridKeys.cell(for: 9, in: grid) == CellRange.Cell(column: 3, row: 2))
        check("T is outside a 4-column grid", GridKeys.cell(for: 17, in: grid) == nil)
        check("four rows start at the number row", GridKeys.cell(for: 18, in: GridSize(columns: 4, rows: 4)) == CellRange.Cell(column: 0, row: 0))
        // This Mac's displays: where two meet top to bottom, the lower one's
        // top rows snap to it.
        let real = LayoutDisplay.all()
        for lower in real {
            for upper in real where upper.id != lower.id && abs(upper.frame.maxY - lower.frame.minY) < 1 {
                let x = (max(upper.frame.minX, lower.frame.minX) + min(upper.frame.maxX, lower.frame.maxX)) / 2
                guard x > lower.frame.minX + 40, x < lower.frame.maxX - 40 else { continue }
                let name = "\(lower.name) below \(upper.name)"
                check("\(name): its first row snaps", LayoutGeometry.edgeZone(at: CGPoint(x: x, y: lower.frame.minY), in: real).map { $0.0.id == lower.id && $0.1 == .maximize } ?? false)
                check("\(name): so does the menu bar", LayoutGeometry.edgeZone(at: CGPoint(x: x, y: lower.usable.minY - 1), in: real)?.1 == .maximize)
                check("\(name): and a little below it", LayoutGeometry.edgeZone(at: CGPoint(x: x, y: lower.usable.minY + 8), in: real)?.1 == .maximize)
                check("\(name): but not further down", LayoutGeometry.edgeZone(at: CGPoint(x: x, y: lower.usable.minY + 30), in: real) == nil)
                check("\(name): the row above is the bottom of the other", LayoutGeometry.edgeZone(at: CGPoint(x: x, y: lower.frame.minY - 1), in: real).map { $0.0.id == upper.id && $0.1 == .bottomHalf } ?? false)
                check("\(name): so is a strip above that", LayoutGeometry.edgeZone(at: CGPoint(x: x, y: upper.usable.maxY - 8), in: real).map { $0.0.id == upper.id && $0.1 == .bottomHalf } ?? false)
            }
        }
        // A hidden overlay lets go of its panel and the picture it holds.
        if let screen = real.first {
            let overlay = LayoutOverlay()
            weak var shown: NSWindow?
            for interactive in [false, true] {
                autoreleasepool {
                    overlay.content = LayoutOverlayContent(grid: GridSize(columns: 2, rows: 1))
                    overlay.show(on: screen, interactive: interactive)
                    shown = overlay.window
                    overlay.hide()
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                check("a hidden \(interactive ? "grid" : "drag") overlay is freed", shown == nil)
            }
        }
        // What the grid overlay costs while it's up, on the largest display.
        if let screen = real.max(by: { $0.frame.width * ($0.screen?.backingScaleFactor ?? 1) < $1.frame.width * ($1.screen?.backingScaleFactor ?? 1) }) {
            let overlay = LayoutOverlay()
            let size = GridSize(columns: 4, rows: 3)
            var range = CellRange(CellRange.Cell(column: 0, row: 0))
            range.cursor = CellRange.Cell(column: 2, row: 1)
            let before = processFootprint()
            autoreleasepool {
                overlay.content = LayoutOverlayContent(grid: size, selection: range,
                                                       highlight: LayoutGeometry.place(range.unit(in: size), in: screen.usable, gap: 0),
                                                       labels: GridKeys.usLabels(for: size), dim: 0.45, title: "Test", hint: "Hint")
                overlay.show(on: screen, interactive: false)
                for column in 0..<4 {
                    range.cursor = CellRange.Cell(column: column, row: 2)
                    overlay.content.selection = range
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                }
            }
            let during = processFootprint()
            // A picture of the overlay window alone, as the screen shows it,
            // next to the report: only our own window, with made-up content.
            if let path, let id = overlay.window?.windowID {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    defer { done.signal() }
                    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                          let window = content.windows.first(where: { $0.windowID == id }) else { return }
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width)
                    config.height = Int(window.frame.height)
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    else { return }
                    let url = URL(fileURLWithPath: path + ".overlay.png")
                    if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, image, nil)
                        CGImageDestinationFinalize(dest)
                    }
                }
                while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            overlay.hide()
            let cost = Double(during - before) / 1_048_576
            check("the grid overlay costs little memory while it's up", cost < 8, String(format: "%.1f MB on %@", cost, screen.name))
            lines.append(String(format: "     grid overlay: %.1f MB on %@", cost, screen.name))
        }
        lines.append("     labels on this keyboard: \(GridKeys.labels(for: grid).sorted { $0.key < $1.key }.map(\.value).joined(separator: " "))")

        // Live, against a helper's windows.
        if !AXIsProcessTrusted() {
            lines.append("skip live checks: Accessibility is not granted to this process (run the app bundle with `open -n`)")
        } else if let helper = launchHelper() {
            defer { helper.terminate() }
            let windows = helperWindows(pid: helper.processIdentifier)
            let displays = LayoutDisplay.all()
            let layout = LayoutController.testing()
            if let window = windows.first(where: { $0.1 == "Layout Test" }).flatMap({ LayoutWindow.find(id: $0.0, pid: helper.processIdentifier) }),
               let start = window.frame, let display = LayoutGeometry.display(of: start, in: displays) {
                lines.append("     helper window \(text(start)) on \(display.name), usable \(text(display.usable))")
                func expect(_ name: String, _ target: Target, _ wanted: CGRect, cycle: Bool = false) {
                    layout.place(window, target, displays: displays, gap: 0, cycle: cycle)
                    let actual = window.frame
                    check(name, actual.map { LayoutWindow.close($0, wanted) } ?? false, "wanted \(text(wanted)), got \(text(actual))")
                }
                func unit(_ action: LayoutAction, _ step: Int = 0, on d: LayoutDisplay? = nil) -> CGRect {
                    LayoutGeometry.place(LayoutGeometry.unit(for: action, step: step)!, in: (d ?? display).usable, gap: 0)
                }
                // Left is a trip across the displays; sizes only at the outer edge, and only if asked for.
                expect("left half", .action(.leftHalf), unit(.leftHalf))
                var edge = display
                if let left = LayoutGeometry.neighbour(of: display, .left, in: displays) {
                    expect("again: straight on to the right half of the display on the left", .action(.leftHalf), unit(.rightHalf, on: left))
                    expect("again: its left half", .action(.leftHalf), unit(.leftHalf, on: left))
                    edge = left
                }
                if LayoutGeometry.neighbour(of: edge, .left, in: displays) == nil {
                    expect("at the outer edge: stays", .action(.leftHalf), unit(.leftHalf, on: edge))
                    expect("with sizes at the edge: ⅔", .action(.leftHalf), unit(.leftHalf, 1, on: edge), cycle: true)
                    expect("then ⅓", .action(.leftHalf), unit(.leftHalf, 2, on: edge), cycle: true)
                    expect("then ½", .action(.leftHalf), unit(.leftHalf, on: edge), cycle: true)
                    layout.place(window, .action(.leftHalf), displays: displays, gap: 0, cycle: true)
                    if edge != display {
                        expect("right from ⅔ against the edge: the right half", .action(.rightHalf), unit(.rightHalf, on: edge))
                        expect("right again: back on its own display, left half", .action(.rightHalf), unit(.leftHalf))
                    }
                }
                expect("restore brings it back", .action(.restore), start)
                // A new gap: windows we placed, and still there, take it.
                layout.place(window, .action(.leftHalf), displays: displays, gap: 0, cycle: false)
                layout.config.gap = 12
                layout.applyGap()
                let regapped = LayoutGeometry.place(CGRect(x: 0, y: 0, width: 0.5, height: 1), in: display.usable, gap: 12)
                for _ in 0..<40 where !(window.frame.map { LayoutWindow.close($0, regapped) } ?? false) {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                check("a new gap moves a placed window to match", window.frame.map { LayoutWindow.close($0, regapped) } ?? false, text(window.frame))
                window.setFrame(CGRect(x: 300, y: 300, width: 500, height: 400), within: display.usable)
                layout.config.gap = 20
                layout.applyGap()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                check("but not one moved by hand since", window.frame.map { LayoutWindow.close($0, CGRect(x: 300, y: 300, width: 500, height: 400)) } ?? false, text(window.frame))
                layout.config.gap = 0
                window.setFrame(start, within: display.usable)
                // The real window list, as a drag sees it: through the Dock's
                // overlay and anything else that covers a display.
                if let frame = window.frame {
                    // In front for this one, then the app that was there gets the keyboard back.
                    let previous = NSWorkspace.shared.frontmostApplication
                    window.raise()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    let grab = DragWatcher.window(at: CGPoint(x: frame.midX, y: frame.minY + 10))
                    previous?.activate()
                    for _ in 0..<20 where window.isFocusedInApp { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                    check("a drag on the title bar finds the window", grab?.pid == helper.processIdentifier, "found \(grab.map { "pid \($0.pid)" } ?? "nothing")")
                    let seen = grab.flatMap { DragWatcher.bounds(of: $0.id) }
                    check("and can follow where it is", seen.flatMap { s in grab.map { LayoutWindow.close(s, $0.frame) } } ?? false, "\(text(seen)) vs \(text(grab?.frame))")
                }
                // Up and down go by where the window is, not by what was pressed before.
                expect("top half", .action(.topHalf), unit(.topHalf))
                expect("up again: maximized", .action(.topHalf), unit(.maximize))
                if let above = LayoutGeometry.neighbour(of: display, .up, in: displays) {
                    expect("up on a maximized window: maximized on the display above", .action(.topHalf), unit(.maximize, on: above))
                    expect("down there: its bottom half", .action(.bottomHalf), unit(.bottomHalf, on: above))
                    expect("down again: top half of the display below", .action(.bottomHalf), unit(.topHalf))
                } else {
                    expect("up on a maximized window, nothing above: stays", .action(.topHalf), unit(.maximize))
                    expect("down on a maximized window: bottom half", .action(.bottomHalf), unit(.bottomHalf))
                }
                if let below = LayoutGeometry.neighbour(of: display, .down, in: displays) {
                    layout.place(window, .action(.maximize), displays: displays, gap: 0, cycle: true)
                    expect("down on a maximized window: bottom half, not the next display", .action(.bottomHalf), unit(.bottomHalf))
                    expect("down again: top half of the display below", .action(.bottomHalf), unit(.topHalf, on: below))
                    expect("down again: its bottom half", .action(.bottomHalf), unit(.bottomHalf, on: below))
                    expect("up from there: top half", .action(.topHalf), unit(.topHalf, on: below))
                    expect("up again: maximized", .action(.topHalf), unit(.maximize, on: below))
                    expect("up again: back up, maximized", .action(.topHalf), unit(.maximize))
                    // Maximized some other way, on the lower display: one press goes up.
                    window.setFrame(unit(.maximize, on: below), within: below.usable)
                    expect("up on a window maximized elsewhere: the display above", .action(.topHalf), unit(.maximize))
                }
                // Put at the left half some other way: ← carries on from there.
                window.setFrame(unit(.leftHalf), within: display.usable)
                if let left = LayoutGeometry.neighbour(of: display, .left, in: displays) {
                    expect("left on a window already at ½: on to the next display", .action(.leftHalf), unit(.rightHalf, on: left))
                } else {
                    expect("left on a window already at ½, with sizes: ⅔", .action(.leftHalf), unit(.leftHalf, 1), cycle: true)
                }
                // A window moved by hand counts from there.
                expect("restore: back to where it was put by hand", .action(.restore), unit(.leftHalf))
                window.setFrame(start, within: display.usable)
                expect("maximize", .action(.maximize), unit(.maximize))
                // Fill through the helper's Window menu, as macOS would do it. Only
                // the app in front has a focused window, so the helper comes
                // forward for a moment, and the app that was there goes back.
                let front = NSWorkspace.shared.frontmostApplication
                NSRunningApplication(processIdentifier: helper.processIdentifier)?.activate()
                for _ in 0..<20 where !window.isFocusedInApp { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                // Its menus are filled in once it's in front.
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                if window.isFocusedInApp {
                    layout.place(window, .action(.restore), displays: displays, gap: 0, cycle: false)
                    var filled = false
                    var attempts = 0
                    while !filled, attempts < 50 {
                        attempts += 1
                        filled = window.perform(.fill)
                        if !filled { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
                    }
                    lines.append("     Fill pressed: \(filled) after \(attempts) tries, focused \(window.isFocusedInApp)")
                    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    let after = window.frame
                    check("macOS's Fill is there to press", filled)
                    let inset = after.map { a in [a.minX - display.usable.minX, a.minY - display.usable.minY, display.usable.maxX - a.maxX, display.usable.maxY - a.maxY].map { Int($0) } } ?? []
                    lines.append("     macOS Fill: \(text(after)) in \(text(display.usable)), margins \(inset), EnableTiledWindowMargins = \(SystemTiling.value(SystemTiling.marginsKey).map(String.init) ?? "missing")")
                    if SystemTiling.value(SystemTiling.marginsKey) == false {
                        check("with macOS's margins off, Fill takes the whole display", after.map { LayoutWindow.close($0, display.usable) } ?? false, text(after))
                    }
                    // Through the controller: a maximize with no gap is macOS's Fill.
                    layout.place(window, .action(.maximize), displays: displays, gap: 0, cycle: false)
                    let maximized = window.frame
                    check("maximize with no gap uses macOS's Fill", maximized.map { LayoutWindow.near($0, unit(.maximize)) } ?? false, text(maximized))
                    // Filled by macOS, then placed by us: ours sticks.
                    layout.place(window, .action(.leftHalf), displays: displays, gap: 0, cycle: false)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    check("a window macOS filled still goes where we put it", window.frame.map { LayoutWindow.close($0, unit(.leftHalf)) } ?? false, text(window.frame))
                    window.setFrame(start, within: display.usable)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                } else {
                    lines.append("skip Fill check: the helper's window isn't its focused one")
                }
                // The rest with the helper in the background, placed by our own frames.
                front?.activate()
                for _ in 0..<20 where window.isFocusedInApp { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                var cells = CellRange(CellRange.Cell(column: 1, row: 1))
                cells.cursor = CellRange.Cell(column: 2, row: 2)
                expect("grid cells", .unit(cells.unit(in: grid), display),
                       LayoutGeometry.place(cells.unit(in: grid), in: display.usable, gap: 0))
                expect("restore", .action(.restore), start)
                if displays.count > 1 {
                    let next = displays[(displays.firstIndex(of: display)! + 1) % displays.count]
                    expect("top left", .action(.topLeft), unit(.topLeft))
                    expect("next display keeps it snapped", .action(.nextDisplay), unit(.topLeft, on: next))
                    expect("and back", .action(.previousDisplay), unit(.topLeft))
                }
                layout.place(window, .action(.restore), displays: displays, gap: 0, cycle: false)

                // What the work queue does next, waited for.
                func settle(_ wanted: CGRect, _ name: String, sizeOnly: Bool = false) {
                    let deadline = Date().addingTimeInterval(2)
                    var actual = window.frame
                    while Date() < deadline {
                        if let a = actual, sizeOnly ? LayoutWindow.close(a.size, wanted.size) : LayoutWindow.close(a, wanted) { break }
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                        actual = window.frame
                    }
                    let ok = actual.map { sizeOnly ? LayoutWindow.close($0.size, wanted.size) : LayoutWindow.close($0, wanted) } ?? false
                    check(name, ok, "wanted \(text(wanted)), got \(text(actual))")
                }
                func key(_ code: Int, shift: Bool = false) {
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
                                                       windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                       isARepeat: false, keyCode: UInt16(code)) else { return }
                    _ = layout.gridKey(event)
                }
                let size = layout.gridSize(for: display)
                func block(_ a: CellRange.Cell, _ b: CellRange.Cell) -> CGRect {
                    var range = CellRange(a)
                    range.cursor = b
                    return LayoutGeometry.place(range.unit(in: size), in: display.usable, gap: 0)
                }
                let top = CellRange.Cell(column: 0, row: 0), far = CellRange.Cell(column: min(2, size.columns - 1), row: min(1, size.rows - 1))
                layout.beginGrid(window, title: "Layout Test", frame: window.frame ?? start)
                check("grid opens", layout.gridIsOpen)
                key(GridKeys.keyCode(for: top, in: size))
                key(GridKeys.keyCode(for: far, in: size))
                settle(block(top, far), "grid: two corner keys")
                check("grid closes after placing", !layout.gridIsOpen)
                layout.beginGrid(window, title: "Layout Test", frame: window.frame ?? start)
                key(kVK_UpArrow)
                key(kVK_LeftArrow)
                key(kVK_LeftArrow)
                key(kVK_LeftArrow)
                key(kVK_RightArrow, shift: true)
                key(kVK_Return)
                settle(block(top, CellRange.Cell(column: min(1, size.columns - 1), row: 0)), "grid: arrows, ⇧ arrow, return")
                layout.beginGrid(window, title: "Layout Test", frame: window.frame ?? start)
                key(kVK_Escape)
                check("grid: esc cancels", !layout.gridIsOpen)

                // A drag, fed straight to the controller: to an open side, then onto the grid with ⇧.
                let sides = [(CGPoint(x: display.frame.maxX - 1, y: display.frame.midY), LayoutAction.rightHalf),
                             (CGPoint(x: display.frame.minX, y: display.frame.midY), LayoutAction.leftHalf)]
                if let (point, action) = sides.first(where: { LayoutGeometry.edgeZone(at: $0.0, in: displays)?.1 == $0.1 }) {
                    func drag(_ points: [CGPoint], _ flags: CGEventFlags) {
                        guard let frame = window.frame else { return }
                        layout.dragStarted(DragWatcher.Grab(id: window.id, pid: helper.processIdentifier, frame: frame))
                        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                        for p in points { layout.dragMoved(p, flags) }
                        layout.dropped(points.last!, flags)
                    }
                    layout.place(window, .action(.restore), displays: displays, gap: 0, cycle: false)
                    let before = window.frame ?? start
                    drag([point], [])
                    settle(unit(action), "drag to the \(action == .rightHalf ? "right" : "left") edge")
                    func middle(of cell: CellRange.Cell) -> CGPoint {
                        let r = block(cell, cell)
                        return CGPoint(x: r.midX, y: r.midY)
                    }
                    let near = CellRange.Cell(column: min(1, size.columns - 1), row: min(1, size.rows - 1))
                    drag([middle(of: top), middle(of: near)], .maskShift)
                    settle(block(top, near), "drag with ⇧ onto the grid")
                    // With ⌥: the layouts bar appears at the pointer; let go over ⅔.
                    let p0 = CGPoint(x: display.usable.midX, y: display.usable.midY)
                    let bar = SlotPicker(display: display, pointer: p0)
                    if let index = bar.layouts.firstIndex(where: { $0.first?.width ?? 0 > 0.6 && $0.count == 2 }) {
                        let zone = bar.rect(of: bar.layouts[index][0], in: bar.tiles[index])
                        drag([p0, CGPoint(x: zone.midX, y: zone.midY)], .maskAlternate)
                        settle(LayoutGeometry.place(bar.layouts[index][0], in: display.usable, gap: 0), "drag with ⌥ onto ⅔ in the layouts bar")
                    }
                    // Back to its old size with the same spot under the pointer,
                    // wherever the pointer is now: a quarter across, 12 down.
                    layout.place(window, .action(.maximize), displays: displays, gap: 0, cycle: false)
                    if let full = window.frame {
                        let pointer = CGPoint(x: display.usable.midX, y: display.usable.midY)
                        let grab = DragWatcher.Grab(id: window.id, pid: helper.processIdentifier, frame: full,
                                                    pointer: CGPoint(x: full.minX + full.width / 4, y: full.minY + 12))
                        layout.restoreUnderPointer(window, size: CGSize(width: 520, height: 408), grab: grab, frame: full,
                                                   pointer: pointer, current: { pointer })
                        let after = window.frame ?? .null
                        check("dragged out: the same spot of the title bar under the pointer",
                              abs(after.minY - (pointer.y - 12)) <= 3 && abs(after.minX - (pointer.x - after.width / 4)) <= 3,
                              "pointer \(Int(pointer.x)), \(Int(pointer.y)); window \(text(after))")
                    }
                    // Dragging a snapped window out puts its old size back.
                    layout.place(window, .action(.leftHalf), displays: displays, gap: 0, cycle: false)
                    if let frame = window.frame {
                        layout.dragStarted(DragWatcher.Grab(id: window.id, pid: helper.processIdentifier, frame: frame))
                        settle(before, "dragged out: old size back", sizeOnly: true)
                        layout.dropped(CGPoint(x: display.frame.midX, y: display.frame.midY), [])
                    }
                } else {
                    lines.append("skip drag checks: this display has no side that isn't shared")
                }
            } else {
                check("helper window found", false, "windows: \(windows)")
            }
            // Tabs, live: the helper's two windows in the right half of a display.
            let found = ["Layout Test", "Layout Test Big"].compactMap { title in
                windows.first(where: { $0.1 == title }).flatMap { LayoutWindow.find(id: $0.0, pid: helper.processIdentifier) }
            }
            if found.count == 2, let display = found[0].frame.flatMap({ LayoutGeometry.display(of: $0, in: displays) }) {
                let (a, b) = (found[0], found[1])
                let tabsFront = NSWorkspace.shared.frontmostApplication
                let startA = a.frame ?? .zero, startB = b.frame ?? .zero
                let tabs = layout.tabs
                tabs.gap = 0
                // The big one has a minimum width: the right half if it fits, else the whole display.
                let right = display.usable.width / 2 >= 920 ? CGRect(x: 0.5, y: 0, width: 0.5, height: 1) : CGRect(x: 0, y: 0, width: 1, height: 1)
                let slotFrame = LayoutGeometry.place(right, in: display.usable, gap: 0)
                for window in [a, b] { layout.place(window, .unit(right, display), displays: displays, gap: 0, cycle: false) }
                func member(_ w: LayoutWindow) -> WindowTabs.Member { WindowTabs.Member(id: w.id, pid: w.pid) }
                func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
                func order() -> [CGWindowID] { SnapAssist.onScreen().map(\.id) }
                tabs.join(member(b), unit: right, display: display, with: member(a))
                wait(1.2)
                let stack = tabs.stack(containing: a.id)
                let memberFrame = stack.map { tabs.memberFrame(of: $0) } ?? .null
                check("tabs: both windows share the slot, above the strip", [a, b].allSatisfy { $0.frame.map { LayoutWindow.near($0, memberFrame) } ?? false },
                      "\(text(a.frame)) \(text(b.frame)) vs \(text(memberFrame))")
                if let stack {
                    let strip = CGWindowID(stack.strip.windowNumber)
                    let z = order()
                    let (iStrip, iA, iB) = (z.firstIndex(of: strip), z.firstIndex(of: a.id), z.firstIndex(of: b.id))
                    check("the strip is right above the window shown, the other behind",
                          iStrip != nil && iB != nil && iA != nil && iStrip! < iB! && iB! < iA!, "strip \(String(describing: iStrip)) b \(String(describing: iB)) a \(String(describing: iA))")
                    tabs.select(a.id, in: stack)
                    wait(0.8)
                    let z2 = order()
                    check("picking the other tab brings it forward, the strip with it",
                          (z2.firstIndex(of: a.id) ?? 99) < (z2.firstIndex(of: b.id) ?? -1) && (z2.firstIndex(of: strip) ?? 99) < (z2.firstIndex(of: a.id) ?? -1))
                    // Back and forth quickly, as clicks on the tabs: each stays picked, its window in front.
                    var picks: [Bool] = []
                    for id in [b.id, a.id, b.id] {
                        tabs.select(id, in: stack)
                        wait(0.45)
                        let z = order()
                        picks.append(stack.shown == id && z.first(where: { $0 == a.id || $0 == b.id }) == id)
                    }
                    wait(1)
                    let z3 = order()
                    check("tabs picked one after another: each comes forward and stays picked", picks.allSatisfy { $0 } && stack.shown == b.id
                          && z3.first(where: { $0 == a.id || $0 == b.id }) == b.id, "\(picks) shown \(stack.shown == b.id ? "b" : "a")")
                    tabs.remove(a.id, raiseNext: false)
                    wait(0.8)
                    check("taking one out of two: no tabs left, the other gets its slot back",
                          tabs.stack(containing: b.id) == nil && (b.frame.map { LayoutWindow.near($0, slotFrame) } ?? false), text(b.frame))
                    check("and the strip is gone", !order().contains(strip))
                    // Resized by hand: out of the tabs.
                    tabs.join(member(b), unit: right, display: display, with: member(a))
                    wait(1.8)
                    a.setFrame(CGRect(x: display.usable.minX + 100, y: display.usable.minY + 100, width: 500, height: 400), within: display.usable)
                    wait(1.0)
                    check("a window moved by hand leaves its tabs", tabs.stack(containing: a.id) == nil)

                    // ⌃ while dragging: the window in the slot is outlined, and dropping over it stacks the two.
                    layout.place(a, .unit(right, display), displays: displays, gap: 0, cycle: false)
                    // In front, so none of this Mac's own windows covers it.
                    a.raise()
                    wait(0.6)
                    let over = CGPoint(x: slotFrame.midX, y: slotFrame.midY)
                    check("⌃ while dragging outlines the window in the slot",
                          layout.stackTargets(on: display, excluding: b.id).contains { $0.occupant.id == a.id })
                    func drag(_ window: LayoutWindow, to point: CGPoint, _ flags: CGEventFlags) {
                        guard let frame = window.frame else { return }
                        layout.dragStarted(DragWatcher.Grab(id: window.id, pid: window.pid, frame: frame))
                        wait(0.3)
                        layout.dragMoved(point, flags)
                        layout.dropped(point, flags)
                        wait(1.4)
                    }
                    drag(b, to: over, .maskControl)
                    check("let go over it with ⌃: the two are stacked", tabs.stack(containing: a.id)?.contains(b.id) == true)
                    // Dragged out to the middle of nowhere: the other keeps its slot.
                    drag(b, to: CGPoint(x: display.usable.minX + 300, y: display.usable.midY), [])
                    check("one dragged out of two: the other gets its whole slot back",
                          tabs.stack(containing: a.id) == nil && (a.frame.map { LayoutWindow.near($0, slotFrame) } ?? false), text(a.frame))
                    // Broken up, the slot is taken at once, before the last window has grown back into it.
                    tabs.join(member(b), unit: right, display: display, with: member(a))
                    wait(1.2)
                    check("a stack's slot is taken", tabs.occupies(slotFrame))
                    tabs.remove(b.id, raiseNext: false)
                    check("and still is the moment it's broken up", tabs.occupies(slotFrame))
                    wait(1.2)
                    // Two windows snapped into the same slot, no stacks: ⌃ stacks with the one in front.
                    if let c = windows.first(where: { $0.1 == "Layout Test Three" }).flatMap({ LayoutWindow.find(id: $0.0, pid: helper.processIdentifier) }) {
                        let startC = c.frame ?? .zero
                        layout.place(c, .unit(right, display), displays: displays, gap: 0, cycle: false)
                        c.raise()
                        wait(0.6)
                        let targets = layout.stackTargets(on: display, excluding: b.id).filter { $0.frame.contains(over) }
                        check("two in one slot: ⌃ outlines the one in front", targets.first?.occupant.id == c.id,
                              "\(targets.map { $0.occupant.id == c.id ? "front" : $0.occupant.id == a.id ? "behind" : "other" })")
                        drag(b, to: over, .maskControl)
                        check("and stacks with it, not the one behind", tabs.stack(containing: c.id)?.contains(b.id) == true && tabs.stack(containing: a.id) == nil)
                        // A window snapped over that stack: now that one is the one in front.
                        layout.place(a, .unit(right, display), displays: displays, gap: 0, cycle: false)
                        a.raise()
                        wait(0.8)
                        let covered = layout.stackTargets(on: display, excluding: kCGNullWindowID).filter { $0.frame.contains(over) }
                        check("a stack under another window isn't offered, the window over it is", covered.first?.occupant.id == a.id,
                              "\(covered.map { $0.occupant.id })")
                        tabs.dissolveAll(restore: false)
                        c.setFrame(startC, within: display.usable)
                    }
                }
                tabs.dissolveAll(restore: false)
                a.setFrame(startA, within: display.usable)
                b.setFrame(startB, within: display.usable)
                tabsFront?.activate()
            }
            if let window = windows.first(where: { $0.1 == "Layout Test Big" }).flatMap({ LayoutWindow.find(id: $0.0, pid: helper.processIdentifier) }),
               let start = window.frame, let display = LayoutGeometry.display(of: start, in: displays) {
                let target = LayoutGeometry.place(LayoutGeometry.unit(for: .topLeft)!, in: display.usable, gap: 0)
                layout.place(window, .action(.topLeft), displays: displays, gap: 0, cycle: false)
                let actual = window.frame ?? .null
                let centred = abs(actual.midX - target.midX) <= 2 || actual.minX == display.usable.minX || actual.maxX == display.usable.maxX
                check("too big for a quarter: centred on it, on the display",
                      actual.width >= 900 && centred && display.usable.insetBy(dx: -1, dy: -1).contains(actual),
                      "target \(text(target)), got \(text(actual))")
            }
        }

        lines.append(failures == 0 ? "all passed" : "\(failures) failed")
        let output = lines.joined(separator: "\n") + "\n"
        print(output, terminator: "")
        if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    /// `--layout-test-window`: the helper's three windows, one of them with a
    /// minimum size larger than a quarter of most displays.
    static func runTestWindows() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // A Window menu, which macOS fills with its tiling commands, as every app has.
        let main = NSMenu()
        main.addItem(withTitle: "Helper", action: nil, keyEquivalent: "").submenu = NSMenu()
        let windowMenu = NSMenu(title: "Window")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        app.mainMenu = main
        app.windowsMenu = windowMenu
        func window(_ title: String, _ frame: CGRect, min: CGSize? = nil) -> NSWindow {
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.title = title
            if let min { window.contentMinSize = min }
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return window
        }
        let windows = [
            window("Layout Test", CGRect(x: 240, y: 240, width: 520, height: 380)),
            window("Layout Test Big", CGRect(x: 300, y: 200, width: 960, height: 640), min: CGSize(width: 900, height: 600)),
            window("Layout Test Three", CGRect(x: 360, y: 280, width: 480, height: 360)),
        ]
        // The key window of its app, without the app coming to the front:
        // the Window menu's commands act on that one.
        windows[0].makeKeyAndOrderFront(nil)
        app.run()
    }

    private static func launchHelper() -> Process? {
        guard let path = Bundle.main.executablePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--layout-test-window"]
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            if list.filter({ $0[kCGWindowOwnerPID as String] as? pid_t == process.processIdentifier }).count >= 3 { break }
        }
        // A moment for its windows to answer Accessibility.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return process
    }

    /// Through Accessibility: the window server only gives other apps'
    /// titles with Screen Recording.
    private static func helperWindows(pid: pid_t) -> [(CGWindowID, String)] {
        let windows: [AXUIElement] = LayoutWindow.attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        return windows.compactMap { element in
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success else { return nil }
            return (id, LayoutWindow.attribute(element, kAXTitleAttribute) ?? "")
        }
    }
}

extension LayoutController {
    /// `--dump-menus <app name>`: the app's menu items with their key
    /// equivalents and identifiers, to find macOS's own tiling commands.
    static func dumpMenus(_ name: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
            print("not running: \(name)")
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = LayoutWindow.attribute(element, kAXMenuBarAttribute) else { return print("no menu bar") }
        func walk(_ item: AXUIElement, _ depth: Int) {
            let children: [AXUIElement] = LayoutWindow.attribute(item, kAXChildrenAttribute) ?? []
            for child in children {
                let title: String = LayoutWindow.attribute(child, kAXTitleAttribute) ?? ""
                let char: String = LayoutWindow.attribute(child, kAXMenuItemCmdCharAttribute) ?? ""
                let mods: Int = LayoutWindow.attribute(child, kAXMenuItemCmdModifiersAttribute) ?? -1
                let key: Int = LayoutWindow.attribute(child, kAXMenuItemCmdVirtualKeyAttribute) ?? -1
                let glyph: Int = LayoutWindow.attribute(child, kAXMenuItemCmdGlyphAttribute) ?? -1
                let id: String = LayoutWindow.attribute(child, "AXIdentifier") ?? ""
                let role: String = LayoutWindow.attribute(child, kAXRoleAttribute) ?? ""
                if role != "AXMenu" {
                    print(String(repeating: "  ", count: depth) + "\(title) | char=\(char) mods=\(mods) key=\(key) glyph=\(glyph) id=\(id)")
                }
                if depth < 4 { walk(child, role == "AXMenu" ? depth : depth + 1) }
            }
        }
        let top: [AXUIElement] = LayoutWindow.attribute(bar, kAXChildrenAttribute) ?? []
        for item in top {
            let title: String = LayoutWindow.attribute(item, kAXTitleAttribute) ?? ""
            print("[\(title)]")
            walk(item, 1)
        }
    }
}

extension LayoutController {
    /// `--list-suggestions [file]`: per display, the windows the suggestions
    /// would offer now, front to back.
    static func dumpSuggestions(_ path: String?) {
        _ = NSApplication.shared
        WindowCatalog.shared.start()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let displays = LayoutDisplay.all()
        let onScreen = SnapAssist.onScreen()
        let items = WindowCatalog.shared.snapshot().items
        var lines = ["\(onScreen.count) windows on screen, \(items.filter { $0.state == .window }.count) open in the list"]
        for display in displays {
            let offered = SnapAssist.candidates(items, onScreen: onScreen, on: display, in: displays, excluding: [])
            lines.append("\(display.name): \(offered.count) — " + offered.map { "\($0.appName): \($0.title)" }.joined(separator: " | "))
        }
        let output = lines.joined(separator: "\n") + "\n"
        print(output, terminator: "")
        if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
