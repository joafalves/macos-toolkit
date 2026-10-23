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
        let shown = [WindowSuggestions.OnScreen(id: 1, frame: LayoutGeometry.place(left, in: laptop.usable, gap: 8)),
                     WindowSuggestions.OnScreen(id: 2, frame: CGRect(x: 300, y: 200, width: 600, height: 400)),
                     WindowSuggestions.OnScreen(id: 3, frame: CGRect(x: 2000, y: 200, width: 600, height: 400)),
                     WindowSuggestions.OnScreen(id: 4, frame: rightHalf.insetBy(dx: 3, dy: 3))]
        check("a slot with a window in it is filled", WindowSuggestions.filled(rightHalf, by: shown, except: [1]))
        check("not by the window just dropped", !WindowSuggestions.filled(rightHalf, by: Array(shown.prefix(3)), except: [1]))
        let maximized = WindowSuggestions.OnScreen(id: 9, frame: LayoutGeometry.place(CGRect(x: 0, y: 0, width: 1, height: 1), in: laptop.usable, gap: 8))
        check("nor by one in the slot but under a maximized window", !WindowSuggestions.filled(rightHalf, by: [shown[0], maximized, shown[3]], except: [1]))
        check("but by one in front of it", WindowSuggestions.filled(rightHalf, by: [shown[0], shown[3], maximized], except: [1]))
        func row(_ id: CGWindowID, _ state: SwitcherItem.State = .window) -> SwitcherItem {
            SwitcherItem(id: "w\(id)", window: id, pid: 1, title: "\(id)", appName: "App", icon: nil, state: state)
        }
        let offered = WindowSuggestions.candidates([row(4), row(2), row(3), row(1), row(5, .minimized), row(6)],
                                            onScreen: shown, on: laptop, in: pair, excluding: [1])
        check("offered, always: this display's open windows first, then the other display's, not the dropped one",
              offered.compactMap(\.window) == [4, 2, 3], "\(offered.compactMap(\.window))")
        let only = WindowSuggestions.candidates([row(4), row(2), row(3)], onScreen: shown, on: laptop, in: pair, excluding: [1], from: .display)
        check("this display only: not the other display's", only.compactMap(\.window) == [4, 2])
        let fallback = WindowSuggestions.candidates([row(4), row(2), row(3)], onScreen: shown, on: laptop, in: pair, excluding: [1], from: .fallback)
        check("if none here, with some here: just this display's", fallback.compactMap(\.window) == [4, 2])
        let elsewhere = WindowSuggestions.candidates([row(4), row(2), row(3)], onScreen: shown, on: wide, in: pair, excluding: [1, 3], from: .fallback)
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
                    // Through the controller: a maximize is our own frame, even with no gap.
                    layout.place(window, .action(.maximize), displays: displays, gap: 0, cycle: false)
                    let maximized = window.frame
                    check("maximize with no gap takes the display", maximized.map { LayoutWindow.near($0, unit(.maximize)) } ?? false, text(maximized))
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
                func order() -> [CGWindowID] { WindowSuggestions.onScreen().map(\.id) }
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
        // A regular app, with a Dock icon, for the switcher to list it.
        app.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)
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

    private static func launchHelper(regular: Bool = false) -> Process? {
        guard let path = Bundle.main.executablePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--layout-test-window"] + (regular ? ["--regular"] : [])
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
        let onScreen = WindowSuggestions.onScreen()
        let items = WindowCatalog.shared.snapshot().items
        var lines = ["\(onScreen.count) windows on screen, \(items.filter { $0.state == .window }.count) open in the list"]
        for display in displays {
            let offered = WindowSuggestions.candidates(items, onScreen: onScreen, on: display, in: displays, excluding: [])
            lines.append("\(display.name): \(offered.count) — " + offered.map { "\($0.appName): \($0.title)" }.joined(separator: " | "))
        }
        let output = lines.joined(separator: "\n") + "\n"
        print(output, terminator: "")
        if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}

extension LayoutController {
    /// `--test-drag [report]`: real drags, posted as mouse events, on the
    /// title bar of a helper's window that macOS filled, which macOS gives its
    /// old size back as the drag starts, and resizes by an edge and a corner.
    /// Says whether the drag watcher took each for a window being moved. The
    /// pointer moves on its own for a while: leave the mouse alone.
    static func dragTest(report path: String?) {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func text(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil" }
        func finish() {
            lines.append(failures == 0 ? "all passed" : "\(failures) failed")
            let output = lines.joined(separator: "\n") + "\n"
            print(output, terminator: "")
            if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        guard AXIsProcessTrusted() else {
            lines.append("skip: Accessibility is not granted to this process (run the app bundle with `open -n`)")
            return finish()
        }
        guard let helper = launchHelper() else { return finish() }
        defer { helper.terminate() }
        let pid = helper.processIdentifier
        guard let window = helperWindows(pid: pid).first(where: { $0.1 == "Layout Test" }).flatMap({ LayoutWindow.find(id: $0.0, pid: pid) }),
              let start = window.frame, let display = LayoutGeometry.display(of: start, in: LayoutDisplay.all())
        else {
            check("helper window found", false)
            return finish()
        }
        let watcher = DragWatcher()
        var started: [CGRect] = []
        var moves = 0
        watcher.onStart = { started.append($0.frame) }
        watcher.onMove = { _, _ in moves += 1 }
        guard watcher.start(active: false) else {
            check("the drag watcher starts", false)
            return finish()
        }
        defer { watcher.stop() }
        let front = NSWorkspace.shared.frontmostApplication
        let home = CGEvent(source: nil)?.location
        defer {
            if let home { CGWarpMouseCursorPosition(home) }
            front?.activate()
        }
        var mouse = PostedMouse()
        func wait(_ seconds: TimeInterval) { PostedMouse.wait(seconds) }
        /// Presses at `from`, moves `steps` events of `step` each, and lets
        /// go. Returns whether the watcher saw a window move.
        func drag(from: CGPoint, step: CGVector, steps: Int = 30) -> Bool {
            started = []
            moves = 0
            mouse.drag(from: from, through: (1...steps).map { CGPoint(x: from.x + step.dx * CGFloat($0), y: from.y + step.dy * CGFloat($0)) })
            return !started.isEmpty
        }
        func fill() -> CGRect? {
            NSRunningApplication(processIdentifier: pid)?.activate()
            for _ in 0..<20 where !window.isFocusedInApp { wait(0.05) }
            wait(0.2)
            for _ in 0..<20 where !window.perform(.fill) { wait(0.1) }
            wait(0.6)
            return window.frame
        }

        lines.append("     helper window on \(display.name), usable \(text(display.usable))")
        // Filled by macOS, then put somewhere smaller: still in macOS's
        // tiling, so as a drag starts macOS gives it back the size it had
        // before the Fill, over a few frames, while it moves. (A window left
        // filled doesn't move for posted events at all; one placed after the
        // Fill does, and is what a window snapped after a maximize is.)
        // Dragged by the title bar, held at a few places across it and at a
        // few speeds: each must be seen as a move.
        let before = CGRect(x: display.usable.minX + 150, y: display.usable.minY + 100, width: 1000, height: 700)
        let placedAt = CGRect(x: display.usable.minX + 300, y: display.usable.minY + 300, width: 600, height: 420)
        let speeds: [(String, CGVector)] = [("slow", CGVector(dx: 1, dy: 1)), ("steady", CGVector(dx: 4, dy: 3)), ("fast", CGVector(dx: 15, dy: 10))]
        var seenCount = 0, total = 0
        for across in [0.5, 0.2, 0.8] {
            for (name, step) in speeds {
                for attempt in 1...3 {
                    window.setFrame(before, within: display.usable)
                    wait(0.3)
                    guard fill() != nil else { continue }
                    window.setFrame(placedAt, within: display.usable)
                    wait(0.4)
                    guard let placed = window.frame else { continue }
                    let grab = CGPoint(x: (placed.minX + placed.width * across).rounded(), y: placed.minY + 14)
                    let seen = drag(from: grab, step: step)
                    let after = window.frame
                    let restored = after.map { !LayoutWindow.close($0.size, placed.size) } ?? false
                    total += 1
                    if seen { seenCount += 1 }
                    check("tiled, dragged \(name) at \(Int(across * 100))% across (\(attempt)): seen as a move", seen,
                          "\(text(placed)) → \(text(after)), macOS gave its size back: \(restored), started at \(text(started.first))")
                }
            }
        }
        lines.append("     tiled windows seen moving: \(seenCount) of \(total)")
        // Not filled: a plain window, dragged, then resized by its edges.
        let plain = CGRect(x: display.usable.minX + 200, y: display.usable.minY + 150, width: 600, height: 420)
        func reset() {
            window.setFrame(plain, within: display.usable)
            wait(0.3)
        }
        reset()
        if let f = window.frame {
            check("a plain window dragged by its title bar: a move", drag(from: CGPoint(x: f.midX, y: f.minY + 14), step: CGVector(dx: 4, dy: 3)))
        }
        let resizes: [(String, (CGRect) -> CGPoint, CGVector, CGEventFlags)] = [
            ("right edge", { CGPoint(x: $0.maxX - 2, y: $0.midY) }, CGVector(dx: 4, dy: 0), []),
            ("left edge", { CGPoint(x: $0.minX + 1, y: $0.midY) }, CGVector(dx: -4, dy: 0), []),
            ("bottom edge", { CGPoint(x: $0.midX, y: $0.maxY - 2) }, CGVector(dx: 0, dy: 4), []),
            ("bottom right corner", { CGPoint(x: $0.maxX - 2, y: $0.maxY - 2) }, CGVector(dx: 4, dy: 4), []),
            ("top left corner", { CGPoint(x: $0.minX + 1, y: $0.minY + 1) }, CGVector(dx: -4, dy: -3), []),
            // Both sides at once, about the middle.
            ("right edge with ⌥", { CGPoint(x: $0.maxX - 2, y: $0.midY) }, CGVector(dx: 4, dy: 0), .maskAlternate),
            ("bottom right corner with ⌥", { CGPoint(x: $0.maxX - 2, y: $0.maxY - 2) }, CGVector(dx: 4, dy: 4), .maskAlternate),
        ]
        for (name, point, step, held) in resizes {
            reset()
            mouse.flags = held
            defer { mouse.flags = [] }
            guard let f = window.frame else { continue }
            let seen = drag(from: point(f), step: step)
            let after = window.frame
            let resized = after.map { !LayoutWindow.close($0.size, f.size) } ?? false
            check("resized by the \(name): not a move", resized && !seen, "resized \(resized), \(text(f)) → \(text(after))")
        }
        window.setFrame(start, within: display.usable)
        finish()
    }
}

/// Real mouse events, for the live drag tests: they move the pointer.
private struct PostedMouse {
    private let source = CGEventSource(stateID: .hidSystemState)
    var flags: CGEventFlags = []

    static func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func post(_ type: CGEventType, _ point: CGPoint, delta: CGVector = .zero) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setDoubleValueField(.mouseEventDeltaX, value: delta.dx)
        event.setDoubleValueField(.mouseEventDeltaY, value: delta.dy)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Presses at `from`, moves through `points`, `interval` apart, stays a
    /// moment at the last if asked, and lets go there.
    func drag(from: CGPoint, through points: [CGPoint], interval: TimeInterval = 0.008, linger: TimeInterval = 0) {
        post(.leftMouseDown, from)
        Self.wait(0.05)
        var last = from
        for point in points {
            post(.leftMouseDragged, point, delta: CGVector(dx: point.x - last.x, dy: point.y - last.y))
            last = point
            Self.wait(interval)
        }
        if linger > 0 {
            post(.leftMouseDragged, last)
            Self.wait(linger)
        }
        post(.leftMouseUp, last)
        Self.wait(0.3)
    }

    /// A straight line to `to`, `step` points at a time.
    static func line(from: CGPoint, to: CGPoint, step: CGFloat = 15) -> [CGPoint] {
        let count = max(Int((hypot(to.x - from.x, to.y - from.y) / step).rounded(.up)), 1)
        return (1...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            return CGPoint(x: (from.x + (to.x - from.x) * t).rounded(), y: (from.y + (to.y - from.y) * t).rounded())
        }
    }
}

extension LayoutController {
    /// `--test-snap [report]`: the installed app's Window Layout, with the
    /// settings saved here, on a helper's windows dragged for real: one
    /// maximized at the top edge, another snapped to the right, their gaps
    /// compared, the right one taken out and snapped again, every corner,
    /// halves side by side, a maximized window into a corner, and the other
    /// displays. Install the build first. Leave the mouse alone.
    static func snapTest(report path: String?) {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func text(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil" }
        func finish() {
            lines.append(failures == 0 ? "all passed" : "\(failures) failed")
            let output = lines.joined(separator: "\n") + "\n"
            print(output, terminator: "")
            if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        guard AXIsProcessTrusted() else {
            lines.append("skip: Accessibility is not granted to this process (run the app bundle with `open -n`)")
            return finish()
        }
        guard let helper = launchHelper() else { return finish() }
        defer { helper.terminate() }
        let pid = helper.processIdentifier
        let found = helperWindows(pid: pid)
        func helperWindow(_ title: String) -> LayoutWindow? {
            found.first { $0.1 == title }.flatMap { LayoutWindow.find(id: $0.0, pid: pid) }
        }
        guard let a = helperWindow("Layout Test"), let b = helperWindow("Layout Test Three"), let start = a.frame,
              let display = LayoutGeometry.display(of: start, in: LayoutDisplay.all())
        else {
            check("helper windows found", false)
            return finish()
        }
        // The installed app does the snapping, as it does for any window:
        // this only drags and looks.
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) else {
            check("the installed app is running, to do the snapping", false)
            return finish()
        }
        let config = LayoutConfig.load()
        let displays = LayoutDisplay.all()
        let gap = CGFloat(config.gap)
        lines.append("     on \(display.name), usable \(text(display.usable)); gap \(Int(gap)), suggest \(config.suggest), restore on drag out \(config.restoreOnDragOut)")
        let front = NSWorkspace.shared.frontmostApplication
        let home = CGEvent(source: nil)?.location
        defer {
            if let home { CGWarpMouseCursorPosition(home) }
            front?.activate()
        }
        let mouse = PostedMouse()
        /// By the title bar to `to`, by way of `via`, where it stays a moment,
        /// and dropped. `settle` is how long it's left before looking, and
        /// before the next drag.
        func drag(_ window: LayoutWindow, to: CGPoint, via: [CGPoint] = [], settle: TimeInterval = 0.9) -> CGRect? {
            // In front, as a window you can see to grab is.
            window.raise()
            PostedMouse.wait(settle < 0.5 ? 0.05 : 0.3)
            guard let f = window.frame else { return nil }
            let from = CGPoint(x: f.midX.rounded(), y: f.minY + 14)
            var path: [CGPoint] = []
            for point in via + [to] { path += PostedMouse.line(from: path.last ?? from, to: point) }
            mouse.drag(from: from, through: path, interval: 0.012, linger: 0.25)
            PostedMouse.wait(settle)
            return window.frame
        }
        func unit(_ action: LayoutAction, on d: LayoutDisplay? = nil) -> CGRect {
            let d = d ?? display
            return LayoutGeometry.place(LayoutGeometry.unit(for: action, portrait: d.portrait)!, in: d.usable, gap: gap)
        }
        func expect(_ name: String, _ got: CGRect?, _ action: LayoutAction, on d: LayoutDisplay? = nil) {
            let wanted = unit(action, on: d)
            check(name, got.map { LayoutWindow.close($0, wanted) } ?? false, "wanted \(text(wanted)), got \(text(got))")
        }
        let f = display.frame, u = display.usable
        a.setFrame(CGRect(x: u.minX + 100, y: u.minY + 120, width: 700, height: 500), within: u)
        b.setFrame(CGRect(x: u.midX, y: u.minY + 200, width: 600, height: 420), within: u)
        PostedMouse.wait(0.5)

        let middle = CGPoint(x: u.midX - 150, y: u.midY)
        let maximized = drag(a, to: CGPoint(x: u.minX + 500, y: f.minY + 1))
        expect("A to the top edge: maximized, with the gap", maximized, .maximize)
        let right = drag(b, to: CGPoint(x: f.maxX - 1, y: u.midY))
        expect("B to the right edge: the right half", right, .rightHalf)
        if let m = maximized, let r = right {
            check("the same gap at the right and top of both", abs((u.maxX - m.maxX) - (u.maxX - r.maxX)) <= 1 && abs((m.minY - u.minY) - (r.minY - u.minY)) <= 1,
                  "maximized: right \(Int(u.maxX - m.maxX)), top \(Int(m.minY - u.minY)); right half: right \(Int(u.maxX - r.maxX)), top \(Int(r.minY - u.minY))")
        }
        // Out and back, as when you change your mind: each time it snaps, and
        // out of it, it has the size it had before.
        for round in 1...5 {
            let out = drag(b, to: middle)
            check("round \(round): B taken out has its size from before", out.map { abs($0.width - 600) <= 2 && abs($0.height - 420) <= 2 } ?? false, "got \(text(out))")
            expect("round \(round): B back at the right edge snaps again", drag(b, to: CGPoint(x: f.maxX - 1, y: u.midY + CGFloat(round * 37 - 100))), .rightHalf)
        }
        // Side by side: the gap between the halves is the gap.
        let left = drag(b, to: CGPoint(x: f.minX, y: u.midY))
        expect("B to the left edge: the left half", left, .leftHalf)
        let aRight = drag(a, to: CGPoint(x: f.maxX - 1, y: u.midY - 80))
        expect("A, maximized, to the right edge: the right half", aRight, .rightHalf)
        if let l = left, let r = aRight {
            check("the gap between the halves is the gap", abs((r.minX - l.maxX) - gap) <= 1, "\(Int(r.minX - l.maxX)) between")
        }
        // Every corner, from the middle.
        let corners: [(String, CGPoint, LayoutAction)] = [("top left", CGPoint(x: f.minX, y: f.minY + 1), .topLeft),
                                                          ("top right", CGPoint(x: f.maxX - 1, y: f.minY + 1), .topRight),
                                                          ("bottom left", CGPoint(x: f.minX, y: f.maxY - 1), .bottomLeft),
                                                          ("bottom right", CGPoint(x: f.maxX - 1, y: f.maxY - 1), .bottomRight)]
        for (name, corner, action) in corners {
            _ = drag(b, to: middle)
            expect("B from the middle into the \(name) corner: a quarter", drag(b, to: corner), action)
        }
        // Straight from one snap to another, without a stop in between.
        for (name, corner, action) in corners.reversed() {
            expect("B straight on into the \(name) corner", drag(b, to: corner), action)
        }
        // Grabbed again straight after a snap, while the suggestions for the
        // rest of the display are coming up.
        for round in 1...4 {
            let first = drag(b, to: round % 2 == 1 ? CGPoint(x: f.maxX - 1, y: u.midY) : CGPoint(x: f.minX, y: u.midY), settle: 0.15)
            _ = first
            let next = drag(b, to: round % 2 == 1 ? CGPoint(x: f.minX, y: u.midY) : CGPoint(x: f.maxX - 1, y: u.midY))
            expect("quick round \(round): grabbed again at once, snaps to the other side", next, round % 2 == 1 ? .leftHalf : .rightHalf)
        }
        // A maximized window, taken by its title bar straight into a corner.
        for (name, corner, action) in corners {
            _ = drag(b, to: CGPoint(x: u.midX, y: f.minY + 1))
            expect("B maximized, then into the \(name) corner", drag(b, to: corner, via: [CGPoint(x: u.midX, y: u.midY)]), action)
        }
        // The other displays: each outer side, and the top edge.
        for other in displays where other.id != display.id {
            let o = other.frame, ou = other.usable
            let centre = CGPoint(x: o.midX, y: o.midY)
            func outer(_ x: CGFloat) -> Bool { !displays.contains { $0.id != other.id && $0.frame.contains(CGPoint(x: x, y: o.midY)) } }
            let there = drag(b, to: centre, via: [CGPoint(x: u.midX, y: u.midY)])
            check("B onto \(other.name)", there.map { LayoutGeometry.display(of: $0, in: displays)?.id == other.id } ?? false, "got \(text(there))")
            if outer(o.minX - 2) { expect("on \(other.name): the left edge, the left half", drag(b, to: CGPoint(x: o.minX, y: ou.midY)), .leftHalf, on: other) }
            if outer(o.maxX + 1) { expect("on \(other.name): the right edge, the right half", drag(b, to: CGPoint(x: o.maxX - 1, y: ou.midY)), .rightHalf, on: other) }
            expect("on \(other.name): the top edge, maximized", drag(b, to: CGPoint(x: o.midX, y: o.minY + 1), via: [centre]), .maximize, on: other)
            _ = drag(b, to: CGPoint(x: u.midX, y: u.midY), via: [centre])
        }
        a.setFrame(start, within: u)
        finish()
    }
}

extension LayoutController {
    /// `--test-gap [report]`: a maximized window and one in the left half, both by the controller, then the gap changed both ways
    /// with the helper in the background, as from the settings page: each
    /// must move to the new gap. Uses macOS's margins as they're set now.
    static func gapTest(report path: String?) {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func text(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil" }
        func finish() {
            lines.append(failures == 0 ? "all passed" : "\(failures) failed")
            let output = lines.joined(separator: "\n") + "\n"
            print(output, terminator: "")
            if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        guard AXIsProcessTrusted() else {
            lines.append("skip: Accessibility is not granted to this process (run the app bundle with `open -n`)")
            return finish()
        }
        guard let helper = launchHelper() else { return finish() }
        defer { helper.terminate() }
        let pid = helper.processIdentifier
        let found = helperWindows(pid: pid)
        func helperWindow(_ title: String) -> LayoutWindow? {
            found.first { $0.1 == title }.flatMap { LayoutWindow.find(id: $0.0, pid: pid) }
        }
        guard let a = helperWindow("Layout Test"), let b = helperWindow("Layout Test Three"), let start = a.frame,
              let display = LayoutGeometry.display(of: start, in: LayoutDisplay.all())
        else {
            check("helper windows found", false)
            return finish()
        }
        let front = NSWorkspace.shared.frontmostApplication
        defer { front?.activate() }
        let layout = LayoutController.testing()
        let displays = LayoutDisplay.all()
        let margins = SystemTiling.value(SystemTiling.marginsKey) ?? true
        lines.append("     on \(display.name), usable \(text(display.usable)); macOS's margins \(margins ? "on" : "off")")
        func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func unit(_ action: LayoutAction, _ gap: CGFloat) -> CGRect {
            LayoutGeometry.place(LayoutGeometry.unit(for: action, portrait: display.portrait)!, in: display.usable, gap: gap)
        }
        func gapTo(_ gap: Double) {
            layout.config.gap = gap
            layout.applyGap()
            // Moved on the controller's queue, and macOS may hold a tiled one a moment.
            wait(2)
        }
        let gaps: [(Double, Double)] = [(8, 2), (2, 8), (8, 4), (4, 8), (8, 2), (2, 0), (0, 8)]
        for (first, then) in gaps {
            layout.config.gap = first
            // From somewhere else each time: a second left half is the next display's.
            b.setFrame(CGRect(x: display.usable.midX, y: display.usable.minY + 200, width: 600, height: 420), within: display.usable, tiled: true)
            layout.place(a, .action(.maximize), displays: displays, gap: CGFloat(first), cycle: false)
            layout.place(b, .action(.leftHalf), displays: displays, gap: CGFloat(first), cycle: false)
            wait(0.6)
            let filled = a.isTiledByMacOS
            check("gap \(Int(first)): maximized", a.frame.map { LayoutWindow.close($0, unit(.maximize, CGFloat(first))) } ?? false,
                  "wanted \(text(unit(.maximize, CGFloat(first)))), got \(text(a.frame)), macOS's tiling \(filled)")
            // In the background, as while the settings page is in front.
            front?.activate()
            wait(1.5)
            gapTo(then)
            check("gap \(Int(first)) → \(Int(then)): the maximized window takes it", a.frame.map { LayoutWindow.close($0, unit(.maximize, CGFloat(then))) } ?? false,
                  "wanted \(text(unit(.maximize, CGFloat(then)))), got \(text(a.frame))")
            check("gap \(Int(first)) → \(Int(then)): so does the left half", b.frame.map { LayoutWindow.close($0, unit(.leftHalf, CGFloat(then))) } ?? false,
                  "wanted \(text(unit(.leftHalf, CGFloat(then)))), got \(text(b.frame))")
        }
        a.setFrame(start, within: display.usable)
        // One of our own, like the settings window.
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let own = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 640, height: 420), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            own.title = "Own Test"
            own.isReleasedWhenClosed = false
            app.activate(ignoringOtherApps: true)
            own.makeKeyAndOrderFront(nil)
            for _ in 0..<20 where !own.isKeyWindow { wait(0.05) }
            wait(0.4)
            if let window = LayoutWindow.find(id: CGWindowID(own.windowNumber), pid: ProcessInfo.processInfo.processIdentifier),
               let ownDisplay = window.frame.flatMap({ LayoutGeometry.display(of: $0, in: displays) }) {
                func ownUnit(_ gap: CGFloat) -> CGRect {
                    LayoutGeometry.place(CGRect(x: 0, y: 0, width: 1, height: 1), in: ownDisplay.usable, gap: gap)
                }
                layout.config.gap = 8
                // Off the work queue's main-thread hops, as the controller does it.
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    layout.place(window, .action(.maximize), displays: displays, gap: 8, cycle: false)
                    done.signal()
                }
                while done.wait(timeout: .now()) == .timedOut { wait(0.05) }
                wait(0.6)
                check("our own window, gap 8: maximized", window.frame.map { LayoutWindow.close($0, ownUnit(8)) } ?? false,
                      "wanted \(text(ownUnit(8))), got \(text(window.frame)), macOS's tiling \(window.isTiledByMacOS)")
                gapTo(2)
                check("our own window, gap 8 → 2: takes it", window.frame.map { LayoutWindow.close($0, ownUnit(2)) } ?? false,
                      "wanted \(text(ownUnit(2))), got \(text(window.frame))")
            } else {
                check("our own window found", false)
            }
            own.close()
        }
        finish()
    }
}

extension LayoutController {
    /// `--test-show-desktop [report]`: macOS's Show Desktop on and off again
    /// with a helper's windows out: they go aside, then come back exactly
    /// where they were. Every window on screen moves for a moment.
    static func showDesktopTest(report path: String?) {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func text(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil" }
        func finish() {
            lines.append(failures == 0 ? "all passed" : "\(failures) failed")
            let output = lines.joined(separator: "\n") + "\n"
            print(output, terminator: "")
            if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        guard let helper = launchHelper() else { return finish() }
        defer { helper.terminate() }
        let ids = helperWindows(pid: helper.processIdentifier).map(\.0)
        func frames() -> [CGWindowID: CGRect] { WindowCatalog.frames(of: ids) }
        func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let before = frames()
        check("helper windows found", before.count == ids.count && !ids.isEmpty, "\(before.count) of \(ids.count)")
        let start = Date()
        check("Show Desktop can be asked for", ShowDesktop.toggle())
        wait(1.2)
        let aside = frames()
        let moved = before.filter { id, frame in aside[id].map { !LayoutWindow.close($0, frame) } ?? false }
        let displays = LayoutDisplay.all()
        let offScreen = aside.values.filter { frame in !displays.contains { $0.frame.insetBy(dx: 40, dy: 40).intersects(frame) } }
        lines.append("     aside: \(aside.values.map { text($0) }.joined(separator: "; "))")
        check("with it on, every helper window has gone aside", moved.count == before.count, "\(moved.count) of \(before.count) moved, \(offScreen.count) all but off the displays")
        check("Show Desktop asked off", ShowDesktop.toggle())
        wait(1.2)
        let back = frames()
        let same = before.filter { id, frame in back[id].map { LayoutWindow.close($0, frame) } ?? false }
        check("off again, each is back exactly where it was", same.count == before.count,
              before.map { "\(text($0.value)) → \(text(back[$0.key]))" }.joined(separator: "; "))
        lines.append(String(format: "     both ways in %.1f s, the waits included", Date().timeIntervalSince(start)))

        // The same through its shortcut, which the installed app takes.
        let shortcut = LayoutAction.showDesktop.defaultShortcut
        let source = CGEventSource(stateID: .hidSystemState)
        func press() {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: down)
                event?.flags = [.maskControl, .maskAlternate, .maskCommand]
                event?.post(tap: .cghidEventTap)
            }
        }
        press()
        wait(1.2)
        let byKeys = frames()
        check("\(shortcut.display), pressed: every helper window has gone aside",
              before.allSatisfy { id, frame in byKeys[id].map { !LayoutWindow.close($0, frame) } ?? false },
              "the installed app runs this build and takes the shortcut")
        press()
        wait(1.2)
        let again = frames()
        check("\(shortcut.display) again: each is back exactly where it was",
              before.allSatisfy { id, frame in again[id].map { LayoutWindow.close($0, frame) } ?? false })
        finish()
    }
}

extension LayoutController {
    /// `--test-persist <step> <helper pid> [report]`, a step of
    /// `scripts/test-persist.sh`: the installed app snaps a helper's windows,
    /// is quit or killed and started again, and still knows them.
    /// `snap`: A to the left half and B to the right, by dragging.
    /// `check`: B dragged out gets its size from before, and ⌃⌥⌫ puts A back.
    /// `move`: A moved, while the app isn't running.
    /// `moved`: ⌃⌥⌫ leaves A where it is: it was moved since, so forgotten.
    static func persistTest(step: String, helper pid: pid_t, report path: String?) {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(step): \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func text(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil" }
        func finish() {
            lines.append(failures == 0 ? "all passed" : "\(failures) failed")
            let output = lines.joined(separator: "\n") + "\n"
            print(output, terminator: "")
            if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        let found = helperWindows(pid: pid)
        func helperWindow(_ title: String) -> LayoutWindow? {
            found.first { $0.1 == title }.flatMap { LayoutWindow.find(id: $0.0, pid: pid) }
        }
        guard let a = helperWindow("Layout Test"), let b = helperWindow("Layout Test Three"),
              let display = a.frame.flatMap({ LayoutGeometry.display(of: $0, in: LayoutDisplay.all()) })
        else {
            check("helper windows found", false)
            return finish()
        }
        let f = display.frame, u = display.usable, gap = CGFloat(LayoutConfig.load().gap)
        let aStart = CGRect(x: u.minX + 100, y: u.minY + 120, width: 700, height: 500)
        let bStart = CGRect(x: u.midX, y: u.minY + 200, width: 600, height: 420)
        func unit(_ action: LayoutAction) -> CGRect {
            LayoutGeometry.place(LayoutGeometry.unit(for: action, portrait: display.portrait)!, in: u, gap: gap)
        }
        let mouse = PostedMouse()
        func drag(_ window: LayoutWindow, to: CGPoint) -> CGRect? {
            window.raise()
            PostedMouse.wait(0.3)
            guard let frame = window.frame else { return nil }
            let from = CGPoint(x: frame.midX.rounded(), y: frame.minY + 14)
            mouse.drag(from: from, through: PostedMouse.line(from: from, to: to), interval: 0.012, linger: 0.25)
            PostedMouse.wait(0.9)
            return window.frame
        }
        /// ⌃⌥⌫ to the window, in front with its app.
        func restore(_ window: LayoutWindow) -> CGRect? {
            window.raise()
            PostedMouse.wait(0.5)
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: down)
                event?.flags = [.maskControl, .maskAlternate]
                event?.post(tap: .cghidEventTap)
            }
            PostedMouse.wait(1.2)
            return window.frame
        }
        switch step {
        case "snap":
            a.setFrame(aStart, within: u)
            b.setFrame(bStart, within: u)
            PostedMouse.wait(0.5)
            let left = drag(a, to: CGPoint(x: f.minX, y: u.midY))
            check("A to the left half", left.map { LayoutWindow.close($0, unit(.leftHalf)) } ?? false, "wanted \(text(unit(.leftHalf))), got \(text(left)), gap \(Int(gap))")
            // The suggestions for the rest of the display may be over B: not wanted.
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] { CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)?.post(tap: .cghidEventTap) }
            PostedMouse.wait(0.4)
            let right = drag(b, to: CGPoint(x: f.maxX - 1, y: u.midY))
            check("B to the right half", right.map { LayoutWindow.close($0, unit(.rightHalf)) } ?? false, "wanted \(text(unit(.rightHalf))), got \(text(right))")
        case "check":
            let out = drag(b, to: CGPoint(x: u.midX - 150, y: u.midY))
            check("B dragged out has its size from before the snap", out.map { abs($0.width - bStart.width) <= 2 && abs($0.height - bStart.height) <= 2 } ?? false, text(out))
            let back = restore(a)
            check("⌃⌥⌫ puts A back where it was before the snap", back.map { LayoutWindow.close($0, aStart) } ?? false, "wanted \(text(aStart)), got \(text(back))")
        case "move":
            a.setFrame(aStart.offsetBy(dx: 0, dy: 60), within: u)
            PostedMouse.wait(0.5)
            check("A moved by hand", a.frame.map { LayoutWindow.close($0, aStart.offsetBy(dx: 0, dy: 60)) } ?? false, text(a.frame))
        case "moved":
            let before = a.frame
            let after = restore(a)
            check("⌃⌥⌫ leaves A where it is: forgotten, as moved since", before.flatMap { b in after.map { LayoutWindow.close($0, b) } } ?? false,
                  "\(text(before)) → \(text(after))")
            let out = drag(b, to: CGPoint(x: u.midX - 150, y: u.midY))
            check("B, untouched, still gets its size back", out.map { abs($0.width - bStart.width) <= 2 && abs($0.height - bStart.height) <= 2 } ?? false, text(out))
        default:
            check("a known step", false)
        }
        finish()
    }
}

extension LayoutController {
    /// `--test-displays [report]`: the installed app's snaps following a
    /// display that goes and comes back. Two of a helper's windows snapped
    /// left and right on the display they're on, which is then made a mirror
    /// of another, so it's no longer a display of its own (as if unplugged),
    /// and then not. Undone by macOS when this ends, whatever happens.
    /// The displays flicker; leave the mouse alone.
    static func displaysTest(report path: String?) {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func text(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil" }
        func finish() {
            lines.append(failures == 0 ? "all passed" : "\(failures) failed")
            let output = lines.joined(separator: "\n") + "\n"
            print(output, terminator: "")
            if let path { try? output.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        guard AXIsProcessTrusted() else {
            lines.append("skip: Accessibility is not granted to this process (run the app bundle with `open -n`)")
            return finish()
        }
        guard let helper = launchHelper() else { return finish() }
        defer { helper.terminate() }
        let pid = helper.processIdentifier
        let found = helperWindows(pid: pid)
        func helperWindow(_ title: String) -> LayoutWindow? {
            found.first { $0.1 == title }.flatMap { LayoutWindow.find(id: $0.0, pid: pid) }
        }
        let before = LayoutDisplay.all()
        guard let a = helperWindow("Layout Test"), let b = helperWindow("Layout Test Three"),
              let leaving = a.frame.flatMap({ LayoutGeometry.display(of: $0, in: before) }),
              let staying = before.first(where: { $0.id != leaving.id })
        else {
            check("helper windows found, and a second display", false, "\(before.count) displays")
            return finish()
        }
        let gap = CGFloat(LayoutConfig.load().gap)
        lines.append("     \(leaving.name) goes, \(staying.name) stays; gap \(Int(gap))")
        func unit(_ action: LayoutAction, on d: LayoutDisplay) -> CGRect {
            LayoutGeometry.place(LayoutGeometry.unit(for: action, portrait: d.portrait)!, in: d.usable, gap: gap)
        }
        func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let mouse = PostedMouse()
        func drag(_ window: LayoutWindow, to: CGPoint) {
            window.raise()
            wait(0.3)
            guard let frame = window.frame else { return }
            let from = CGPoint(x: frame.midX.rounded(), y: frame.minY + 14)
            mouse.drag(from: from, through: PostedMouse.line(from: from, to: to), interval: 0.012, linger: 0.25)
            wait(0.9)
        }
        let f = leaving.frame, u = leaving.usable
        a.setFrame(CGRect(x: u.minX + 100, y: u.minY + 120, width: 700, height: 500), within: u)
        b.setFrame(CGRect(x: u.midX, y: u.minY + 200, width: 600, height: 420), within: u)
        wait(0.5)
        // Away from an edge shared with the other display, so it snaps here.
        let outerLeft = !before.contains { $0.id != leaving.id && $0.frame.contains(CGPoint(x: f.minX - 2, y: u.midY)) }
        let outerRight = !before.contains { $0.id != leaving.id && $0.frame.contains(CGPoint(x: f.maxX + 1, y: u.midY)) }
        drag(a, to: CGPoint(x: outerLeft ? f.minX : f.minX + 10, y: u.midY))
        drag(b, to: CGPoint(x: outerRight ? f.maxX - 1 : f.maxX - 10, y: u.midY))
        check("snapped left and right on \(leaving.name)",
              (a.frame.map { LayoutWindow.close($0, unit(.leftHalf, on: leaving)) } ?? false) && (b.frame.map { LayoutWindow.close($0, unit(.rightHalf, on: leaving)) } ?? false),
              "\(text(a.frame)), \(text(b.frame))")

        func mirror(_ on: Bool) -> Bool {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return false }
            CGConfigureDisplayMirrorOfDisplay(config, leaving.id, on ? staying.id : kCGNullDirectDisplay)
            return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
        }
        check("\(leaving.name) made a mirror of \(staying.name)", mirror(true))
        wait(6)
        let alone = LayoutDisplay.all()
        guard let remaining = alone.first(where: { $0.uuid == staying.uuid }) else {
            check("\(staying.name) still there", false)
            _ = mirror(false)
            return finish()
        }
        check("\(leaving.name) is no longer a display of its own", !alone.contains { $0.uuid == leaving.uuid }, "\(alone.map(\.name))")
        check("A, snapped left, is the left half of \(staying.name)", a.frame.map { LayoutWindow.close($0, unit(.leftHalf, on: remaining)) } ?? false,
              "wanted \(text(unit(.leftHalf, on: remaining))), got \(text(a.frame))")
        check("B, snapped right, is the right half of \(staying.name)", b.frame.map { LayoutWindow.close($0, unit(.rightHalf, on: remaining)) } ?? false,
              "wanted \(text(unit(.rightHalf, on: remaining))), got \(text(b.frame))")

        check("the mirror undone", mirror(false))
        wait(6)
        guard let returned = LayoutDisplay.all().first(where: { $0.uuid == leaving.uuid }) else {
            check("\(leaving.name) back", false)
            return finish()
        }
        check("A is back in the left half of \(leaving.name)", a.frame.map { LayoutWindow.close($0, unit(.leftHalf, on: returned)) } ?? false,
              "wanted \(text(unit(.leftHalf, on: returned))), got \(text(a.frame))")
        check("B is back in the right half of \(leaving.name)", b.frame.map { LayoutWindow.close($0, unit(.rightHalf, on: returned)) } ?? false,
              "wanted \(text(unit(.rightHalf, on: returned))), got \(text(b.frame))")
        finish()
    }
}
