import AppKit
import SwiftUI

enum Snapshot {
    static func write(to path: String, section: AppSection, light: Bool) {
        _ = NSApplication.shared
        let model = AppModel()
        model.persists = false
        model.general = GeneralConfig()
        model.section = section
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model, mouse: MouseController.preview(), switcher: SwitcherController.preview(), layout: LayoutController.preview(), mixer: MixerController.preview(), finder: FinderController.preview(), capture: CaptureController.preview(), awake: AwakeController.preview(), stats: StatsController.preview())))
        window.title = "MacOS Toolkit"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(NSSize(width: 780, height: 760))
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        guard let view = window.contentView?.superview ?? window.contentView else { return }
        save(view, to: path)
    }

    /// The window switcher's list, or with `grid` its previews, filled with
    /// made-up rows and drawn stand-ins for windows: nothing from the screen.
    static func writeSwitcher(to path: String, light: Bool, grid: Bool = false) {
        _ = NSApplication.shared
        func icon(_ app: String) -> NSImage { NSWorkspace.shared.icon(forFile: "/System/Applications/\(app).app") }
        func row(_ id: Int, _ title: String, _ app: String, _ state: SwitcherItem.State = .window) -> SwitcherItem {
            SwitcherItem(id: "\(id)", window: state == .window || state == .minimized ? CGWindowID(id) : nil, pid: 0,
                         title: title, appName: app, icon: icon(app), state: state)
        }
        let model = SwitcherListModel()
        model.items = [
            row(1, "Inbox — 3 new messages", "Mail"),
            row(2, "macos-toolkit — zsh — 120×40", "Terminal"),
            row(3, "A very long window title that will not fit in the space the row has for it at all", "TextEdit"),
            row(4, "Notes", "Notes"),
            row(5, "October 2026", "Calendar"),
            row(6, "Untitled", "TextEdit", .minimized),
            row(7, "Music", "Music", .hiddenApp),
            row(8, "Calculator", "Calculator", .noWindows),
        ]
        model.selection = 1
        model.shown = model.items.count
        var size = NSSize(width: 620, height: CGFloat(model.shown) * SwitcherListView.rowHeight + SwitcherListView.padding * 2)
        if grid {
            model.style = .previews
            model.layout = GridLayout(count: model.items.count, maxTileWidth: PreviewSize.medium.maxTileWidth, area: CGSize(width: 1180, height: 760))
            let colors: [NSColor] = [.systemBlue, .darkGray, .systemOrange, .systemYellow, .systemRed, .systemGray]
            for (index, item) in model.items.enumerated() where item.state == .window || item.state == .minimized {
                guard let id = item.window, let image = fakeWindow(accent: colors[index % colors.count], dark: !light, wide: index % 3 != 2) else { continue }
                model.previews[id] = image
            }
            size = model.layout.size
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SwitcherView(model: model).background(Color(nsColor: .windowBackgroundColor))))
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(size)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    /// A drawn window: a title bar, a sidebar and a few lines of "text".
    private static func fakeWindow(accent: NSColor, dark: Bool, wide: Bool) -> CGImage? {
        let size = NSSize(width: wide ? 640 : 480, height: 400)
        let image = NSImage(size: size, flipped: true) { rect in
            let base = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.98, alpha: 1)
            let line = dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.85, alpha: 1)
            base.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: rect.width * 0.26, height: rect.height).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18 + CGFloat(i) * 22, y: 16, width: 13, height: 13)).fill()
            }
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.width * 0.3, y: 50, width: rect.width * 0.4, height: 26), xRadius: 6, yRadius: 6).fill()
            line.setFill()
            for row in 0..<8 {
                let width = rect.width * (0.62 - CGFloat(row % 3) * 0.12)
                NSBezierPath(roundedRect: NSRect(x: rect.width * 0.3, y: 100 + CGFloat(row) * 32, width: width, height: 12), xRadius: 6, yRadius: 6).fill()
            }
            for row in 0..<6 {
                NSBezierPath(roundedRect: NSRect(x: 18, y: 60 + CGFloat(row) * 30, width: rect.width * 0.18, height: 12), xRadius: 6, yRadius: 6).fill()
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The Window Layout grid over a made-up desktop: a drawn backdrop and
    /// stand-in windows, nothing from the screen. With `slots`, the bar of
    /// layouts shown while a window is dragged with ⌥.
    static func writeLayoutGrid(to path: String, light: Bool, slots: Bool = false) {
        _ = NSApplication.shared
        let size = CGSize(width: 1512, height: 982)
        let display = LayoutDisplay(id: 1, uuid: "preview", name: "Built-in Display",
                                    frame: CGRect(origin: .zero, size: size), usable: CGRect(x: 0, y: 33, width: size.width, height: 949 - 70))
        let grid = GridSize(columns: 4, rows: 3)
        var range = CellRange(CellRange.Cell(column: 0, row: 0))
        range.cursor = CellRange.Cell(column: 2, row: 1)
        let gap: CGFloat = 8
        let overlay = LayoutOverlayView(display: display)
        if slots {
            var picker = SlotPicker(display: display, pointer: CGPoint(x: 560, y: 360))
            picker.hovered = SlotPicker.Hit(layout: 4, zone: 0)
            overlay.content = LayoutOverlayContent(
                highlight: LayoutGeometry.place(picker.unit(of: picker.hovered!), in: display.usable, gap: gap),
                hint: "Let go over a layout  ·  esc: don't snap", gap: gap, picker: picker)
        } else {
            overlay.content = LayoutOverlayContent(
                grid: grid, selection: range, highlight: LayoutGeometry.place(range.unit(in: grid), in: display.usable, gap: gap),
                labels: GridKeys.usLabels(for: grid), dim: 0.45, title: "Notes — Shopping list",
                hint: ["Type two corners", "←↑↓→ move", "⇧ extends", "↩ place", "⇥ next display", "esc cancel"].joined(separator: "  ·  "), gap: gap)
        }

        let desktop = NSImage(size: size, flipped: true) { rect in
            let colors: [NSColor] = light ? [NSColor(calibratedRed: 0.55, green: 0.7, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.75, blue: 0.95, alpha: 1)]
                                          : [NSColor(calibratedRed: 0.1, green: 0.14, blue: 0.3, alpha: 1), NSColor(calibratedRed: 0.3, green: 0.15, blue: 0.35, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: rect, angle: 60)
            (light ? NSColor(white: 1, alpha: 0.7) : NSColor(white: 0.1, alpha: 0.7)).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 33).fill()
            let windows: [(NSColor, CGRect, Bool)] = [
                (.systemOrange, CGRect(x: 820, y: 120, width: 600, height: 420), true),
                (.systemBlue, CGRect(x: 150, y: 300, width: 640, height: 400), true),
            ]
            for (accent, frame, wide) in windows {
                guard let image = fakeWindow(accent: accent, dark: !light, wide: wide) else { continue }
                NSImage(cgImage: image, size: frame.size).draw(in: frame)
            }
            return true
        }
        // The overlay is layers, which don't draw into a view's cache, so the
        // picture is put together by hand: the desktop, then the layers.
        overlay.scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        NSAppearance(named: light ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            desktop.draw(in: CGRect(origin: .zero, size: size))
            // Rendering by hand doesn't apply the root layer's top-down
            // geometry the way the screen does, so the image is turned here.
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            overlay.layer?.render(in: context.cgContext)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The toolkit's menu bar item in a few states, on a drawn strip of menu
    /// bar: plain, with a segment pressed, recording, and with the percentage.
    static func writeMenuBar(to path: String, light: Bool) {
        _ = NSApplication.shared
        let toolkit = MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit")
        let capture = MenuBarSegment(kind: .capture, glyph: MenuBarArt.glyph(AppSection.capture.symbol), label: "Screen Capture")
        let badge = MenuBarSegment(kind: .mixer, glyph: MenuBarArt.volumeBadge(volume: 0.6, muted: false), label: "Audio Mixer")
        let percent = MenuBarSegment(kind: .mixer, glyph: MenuBarArt.plainSpeaker(muted: false), text: "60%", widthOf: "100%", label: "Audio Mixer")
        let recording = MenuBarSegment(kind: .recording, colored: MenuBarArt.recordingDot(paused: false), text: "0:42 · 3.1 MB", label: "Recording")
        let awake = MenuBarSegment(kind: .awake, glyph: MenuBarArt.awakeBadge(fraction: 0.7, time: "1:24", widthOf: "2:00"), label: "Keep Awake")
        let awakeOff = MenuBarSegment(kind: .awake, glyph: MenuBarArt.cup(on: false), label: "Keep Awake")
        let awakeTime = MenuBarSegment(kind: .awake, glyph: MenuBarArt.cup(on: true, beforeText: true), text: "1:24", widthOf: "2:00", label: "Keep Awake")
        let awakeFull = MenuBarSegment(kind: .awake, glyph: MenuBarArt.awakeBadge(fraction: 1, time: nil), label: "Keep Awake")
        let rows: [([MenuBarSegment], MenuBarSegment.Kind?)] = [
            ([toolkit, capture, awake, badge], nil),
            ([toolkit, capture, awake, badge], .mixer),
            ([toolkit, recording, awakeTime, percent], nil),
            ([toolkit, awakeOff], nil),
            ([toolkit, awakeFull], .toolkit),
        ]
        // The real views, as the menu bar item has them, on drawn strips of menu bar.
        let strip = NSSize(width: 360, height: 30)
        let gap: CGFloat = 8
        let size = NSSize(width: strip.width, height: strip.height * CGFloat(rows.count) + gap * CGFloat(rows.count - 1))
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        for (index, row) in rows.enumerated() {
            let y = size.height - CGFloat(index + 1) * strip.height - CGFloat(index) * gap
            let bar = NSView(frame: NSRect(x: 0, y: y, width: strip.width, height: strip.height))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = (light ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).cgColor
            container.addSubview(bar)
            let view = MenuBarRow()
            view.show(row.0)
            view.setPressed(row.1)
            view.setFrameOrigin(NSPoint(x: strip.width - view.frame.width - 12, y: ((strip.height - view.frame.height) / 2).rounded()))
            bar.addSubview(view)
        }
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(container, to: path)
    }

    /// The menu bar item as it sits in a menu bar, for the top of the README:
    /// next to drawn stand-ins for macOS's own icons and a made-up clock.
    static func writeMenuBarStrip(to path: String, light: Bool) {
        _ = NSApplication.shared
        let row = MenuBarRow()
        row.show([
            MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit"),
        ] + StatsController.preview().segments() + [
            MenuBarSegment(kind: .capture, glyph: MenuBarArt.glyph(AppSection.capture.symbol), label: "Screen Capture"),
            MenuBarSegment(kind: .awake, glyph: MenuBarArt.awakeBadge(fraction: 0.7, time: "1:24", widthOf: "2:00"), label: "Keep Awake"),
            MenuBarSegment(kind: .mixer, glyph: MenuBarArt.volumeBadge(volume: 0.6, muted: false), label: "Audio Mixer"),
        ])
        let size = NSSize(width: 600, height: 30)
        let bar = NSView(frame: NSRect(origin: .zero, size: size))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = (light ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).cgColor
        var x = size.width - 14
        let clock = NSTextField(labelWithString: "Tue 21 Oct  9:41")
        clock.font = .menuBarFont(ofSize: 0)
        clock.textColor = .labelColor
        clock.sizeToFit()
        x -= clock.frame.width
        clock.setFrameOrigin(NSPoint(x: x, y: ((size.height - clock.frame.height) / 2).rounded()))
        bar.addSubview(clock)
        for symbol in ["switch.2", "wifi", "battery.75percent"] {
            let ink: NSColor = light ? .black : .white
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular).applying(.init(paletteColors: [ink]))) else { continue }
            let icon = NSImageView(image: image)
            icon.frame.size = image.size
            x -= icon.frame.width + 16
            icon.setFrameOrigin(NSPoint(x: x, y: ((size.height - icon.frame.height) / 2).rounded()))
            bar.addSubview(icon)
        }
        x -= row.frame.width + 12
        row.setFrameOrigin(NSPoint(x: x, y: ((size.height - row.frame.height) / 2).rounded()))
        bar.addSubview(row)
        let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = bar
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(bar, to: path)
    }

    /// System Stats in the menu bar, in each layout and look, from made-up readings.
    static func writeStatsBar(to path: String, light: Bool) {
        _ = NSApplication.shared
        let toolkit = MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit")
        let all = StatKind.allCases
        // The default, every stat as a number, then the pills, then the charts.
        let looks: [[StatKind: StatLook]] = [
            [.cpu: .number, .memory: .number, .network: .number, .power: .number],
            [.cpu: .pill, .memory: .pill, .gpu: .pill, .disk: .pill],
            [.cpu: .chart, .memory: .chart, .network: .chart, .power: .chart],
        ]
        var rows: [[MenuBarSegment]] = [[toolkit] + StatsController.preview().segments()]
        for look in looks {
            rows.append([toolkit] + StatsController.preview(looks: look, shown: Array(look.keys)).segments())
        }
        rows.append([toolkit] + StatsController.preview(layout: .compact, shown: [.cpu, .memory]).segments())
        rows.append([toolkit] + StatsController.preview(layout: .compact, shown: all).segments())
        let strip = NSSize(width: 520, height: 30)
        let gap: CGFloat = 8
        let size = NSSize(width: strip.width, height: strip.height * CGFloat(rows.count) + gap * CGFloat(rows.count - 1))
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        for (index, row) in rows.enumerated() {
            let y = size.height - CGFloat(index + 1) * strip.height - CGFloat(index) * gap
            let bar = NSView(frame: NSRect(x: 0, y: y, width: strip.width, height: strip.height))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = (light ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).cgColor
            container.addSubview(bar)
            let view = MenuBarRow()
            view.show(row)
            view.setFrameOrigin(NSPoint(x: strip.width - view.frame.width - 12, y: ((strip.height - view.frame.height) / 2).rounded()))
            bar.addSubview(view)
        }
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(container, to: path)
    }

    /// A System Stats panel, from made-up readings.
    static func writeStatsPanel(to path: String, light: Bool, kinds: [StatKind]) {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: StatsPanelView(stats: .preview(), kinds: kinds).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(host.view.fittingSize)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    /// Window Layout's suggestions after a drop on the left edge: a drawn
    /// window in the left half, and the switcher's grid of made-up windows
    /// in the right half. Nothing from the screen.
    static func writeLayoutSuggest(to path: String, light: Bool) {
        _ = NSApplication.shared
        let size = CGSize(width: 1512, height: 982)
        let usable = CGRect(x: 0, y: 33, width: size.width, height: 949 - 70)
        let gap: CGFloat = 8
        let leftHalf = LayoutGeometry.place(CGRect(x: 0, y: 0, width: 0.5, height: 1), in: usable, gap: gap)
        let rightHalf = LayoutGeometry.place(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), in: usable, gap: gap)
        // Core Graphics frames, top left origin, into this unflipped view.
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }

        let desktop = NSImage(size: size, flipped: true) { rect in
            let colors: [NSColor] = light ? [NSColor(calibratedRed: 0.55, green: 0.7, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.75, blue: 0.95, alpha: 1)]
                                          : [NSColor(calibratedRed: 0.1, green: 0.14, blue: 0.3, alpha: 1), NSColor(calibratedRed: 0.3, green: 0.15, blue: 0.35, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: rect, angle: 60)
            (light ? NSColor(white: 1, alpha: 0.7) : NSColor(white: 0.1, alpha: 0.7)).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 33).fill()
            if let image = fakeWindow(accent: .systemBlue, dark: !light, wide: false) {
                NSImage(cgImage: image, size: leftHalf.size).draw(in: leftHalf)
            }
            return true
        }
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        let background = NSImageView(frame: container.bounds)
        background.image = desktop
        background.imageScaling = .scaleAxesIndependently
        container.addSubview(background)

        func icon(_ app: String) -> NSImage { NSWorkspace.shared.icon(forFile: "/System/Applications/\(app).app") }
        let rows: [(String, String, NSColor)] = [("Inbox — 3 new messages", "Mail", .systemBlue), ("Notes", "Notes", .systemYellow),
                                                 ("October 2026", "Calendar", .systemRed), ("macos-toolkit — zsh", "Terminal", .darkGray),
                                                 ("Untitled", "TextEdit", .systemOrange)]
        let model = SwitcherListModel()
        model.items = rows.enumerated().map { index, row in
            SwitcherItem(id: "\(index)", window: CGWindowID(index + 1), pid: 0, title: row.0, appName: row.1, icon: icon(row.1), state: .window)
        }
        for (index, row) in rows.enumerated() {
            if let image = fakeWindow(accent: row.2, dark: !light, wide: index % 2 == 0) { model.previews[CGWindowID(index + 1)] = image }
        }
        model.style = .previews
        model.layout = GridLayout(count: rows.count, maxTileWidth: PreviewSize.large.maxTileWidth,
                                  area: CGSize(width: rightHalf.width - 24, height: rightHalf.height - 24))
        model.selection = 0
        let panelSize = model.layout.size
        let panelFrame = CGRect(x: rightHalf.midX - panelSize.width / 2, y: rightHalf.midY - panelSize.height / 2,
                                width: panelSize.width, height: panelSize.height)
        // The part offered, outlined the way the app shows it.
        let display = LayoutDisplay(id: 1, uuid: "preview", name: "Built-in Display", frame: CGRect(origin: .zero, size: size), usable: usable)
        let outline = LayoutOverlayView(display: display)
        outline.content = LayoutOverlayContent(highlight: rightHalf)
        outline.frame = container.bounds
        container.addSubview(outline)
        let panel = NSView(frame: local(panelFrame))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.backgroundColor = (light ? NSColor(white: 0.96, alpha: 0.92) : NSColor(white: 0.16, alpha: 0.92)).cgColor
        let grid = NSHostingView(rootView: SwitcherView(model: model))
        grid.frame = panel.bounds
        panel.addSubview(grid)
        container.addSubview(panel)

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        save(container, to: path)
    }

    /// Window Layout's tabs: a drawn window in the left half, and three
    /// made-up ones sharing the right half, with their tab strip at the
    /// bottom. Nothing from the screen.
    static func writeLayoutTabs(to path: String, light: Bool) {
        _ = NSApplication.shared
        let size = CGSize(width: 1512, height: 982)
        let usable = CGRect(x: 0, y: 33, width: size.width, height: 949 - 70)
        let gap: CGFloat = 8
        let leftHalf = LayoutGeometry.place(CGRect(x: 0, y: 0, width: 0.5, height: 1), in: usable, gap: gap)
        let rightHalf = LayoutGeometry.place(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), in: usable, gap: gap)
        let shown = TabGeometry.member(in: rightHalf, style: .strip, position: .bottom)
        let strip = TabGeometry.tabs(in: rightHalf, style: .strip, position: .bottom, count: 3)
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }

        let desktop = NSImage(size: size, flipped: true) { rect in
            let colors: [NSColor] = light ? [NSColor(calibratedRed: 0.55, green: 0.7, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.75, blue: 0.95, alpha: 1)]
                                          : [NSColor(calibratedRed: 0.1, green: 0.14, blue: 0.3, alpha: 1), NSColor(calibratedRed: 0.3, green: 0.15, blue: 0.35, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: rect, angle: 60)
            (light ? NSColor(white: 1, alpha: 0.7) : NSColor(white: 0.1, alpha: 0.7)).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 33).fill()
            if let image = fakeWindow(accent: .systemBlue, dark: !light, wide: false) { NSImage(cgImage: image, size: leftHalf.size).draw(in: leftHalf) }
            if let image = fakeWindow(accent: .systemOrange, dark: !light, wide: true) { NSImage(cgImage: image, size: shown.size).draw(in: shown) }
            return true
        }
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        let background = NSImageView(frame: container.bounds)
        background.image = desktop
        background.imageScaling = .scaleAxesIndependently
        container.addSubview(background)

        func icon(_ app: String) -> NSImage { NSWorkspace.shared.icon(forFile: "/System/Applications/\(app).app") }
        let model = TabStripModel()
        model.tabs = [TabItem(id: 1, title: "Notes — Shopping list", appName: "Notes", icon: icon("Notes")),
                      TabItem(id: 2, title: "Inbox — 3 new messages", appName: "Mail", icon: icon("Mail")),
                      TabItem(id: 3, title: "October 2026", appName: "Calendar", icon: icon("Calendar"))]
        model.shown = 1
        let tabs = NSHostingView(rootView: TabStripView(model: model))
        tabs.frame = local(strip)
        container.addSubview(tabs)

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        save(container, to: path)
    }

    /// The menu bar mixer, filled with made-up rows.
    static func writeMixer(to path: String, light: Bool, outputs: Bool, software: Bool, equalizer: Bool) {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: MixerPopoverView(mixer: .preview(software: software, equalizer: equalizer), showOutputs: outputs, showEqualizer: equalizer).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.setContentSize(host.view.fittingSize)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    /// The Screen Capture toolbar, as ⇧⌘5 shows it.
    static func writeCaptureToolbar(to path: String, light: Bool, video: Bool) {
        _ = NSApplication.shared
        let capture = CaptureController.preview()
        capture.config.kind = video ? .video : .photo
        let host = NSHostingController(rootView: CaptureToolbarView(capture: capture).padding(16))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.backgroundColor = light ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.16, alpha: 1)
        window.setContentSize(host.view.fittingSize)
        onRetina(window)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let view = window.contentView { save(view, to: path) }
    }

    /// Images come out at the scale of the display the window is on, so the
    /// window goes to a Retina one when there is one.
    private static func onRetina(_ window: NSWindow) {
        if let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) {
            window.setFrameOrigin(screen.frame.origin)
        }
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
