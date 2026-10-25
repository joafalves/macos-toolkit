import AppKit
import SwiftUI

extension StatsController {
    /// `--test-stats`: every stat read twice from this Mac, with what it
    /// reads; what a reading costs; and that with the tool off nothing is
    /// read and IOReport isn't even loaded.
    static func selfTest() {
        _ = NSApplication.shared
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }

        func time(_ name: String, _ body: () -> Void) {
            let start = cpuTime()
            for _ in 0..<20 { body() }
            print(String(format: "      %@: %.2f ms", name, (cpuTime() - start) / 20 * 1000))
        }
        let cpuReader = StatsReadings.CPU(), network = StatsReadings.Network(), disk = StatsReadings.Disk()
        time("cpu") { _ = cpuReader.read() }
        time("memory") { _ = StatsReadings.memory() }
        time("network") { _ = network.read() }
        time("disk") { _ = disk.read() }
        time("gpu") { _ = StatsReadings.gpu() }
        time("power (battery)") { _ = StatsReadings.power() }
        // A moment apart: closer, it gives the last watts again without reading.
        let energy = EnergyReport()
        _ = energy?.read()
        var spent = 0.0
        for _ in 0..<8 {
            usleep(250_000)
            let start = cpuTime()
            _ = energy?.read()
            spent += cpuTime() - start
        }
        print(String(format: "      power (IOReport): %.2f ms", spent / 8 * 1000))

        // Off: no timer, no readers, no IOReport subscription. (The library
        // itself is in every app already: macOS's own frameworks load it.)
        let stats = StatsController()
        stats.persists = false
        var config = StatsConfig()
        config.enabled = false
        stats.config = config
        check(stats.timer == nil && stats.reading.isEmpty && stats.energy == nil, "off: no timer, nothing read, no IOReport subscription")

        // On, everything shown, and a panel open for the top apps.
        config.enabled = true
        config.interval = 1
        for kind in StatKind.allCases { config.set(kind) { $0.shown = true } }
        stats.config = config
        stats.panel = [.cpu, .memory, .power]
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let busiest = stats.apps.max { $0.cpu < $1.cpu }
        check(stats.live.cpuOfAppsKnown, "top apps' CPU known a second after the panel opens" + (busiest.map { String(format: " (busiest %@, %.0f%%)", $0.name, $0.cpu * 100) } ?? ""))
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        check(stats.timer != nil, "on: one timer")
        if let cpu = stats.cpu {
            check((0...1).contains(cpu.total) && abs(cpu.user + cpu.system - cpu.total) < 0.001, String(format: "cpu %.0f%% (user %.0f%%, system %.0f%%), %d cores in %@",
                cpu.total * 100, cpu.user * 100, cpu.system * 100, cpu.cores.count, cpu.groups.map { "\($0.name) \($0.cores)" }.joined(separator: ", ")))
        } else { check(false, "cpu read") }
        if let memory = stats.memory {
            let parts = memory.app + memory.wired + memory.compressed + memory.cached + memory.free
            check(memory.neededShare > 0 && memory.neededShare < 1 && parts <= memory.total + memory.total / 10,
                  "memory: needed \(StatsController.memory(memory.needed)) of \(StatsController.memory(memory.total)) (app \(StatsController.memory(memory.app)), wired \(StatsController.memory(memory.wired)), compressed \(StatsController.memory(memory.compressed)), cached \(StatsController.memory(memory.cached)), free \(StatsController.memory(memory.free))), swap \(StatsController.memory(memory.swapUsed)), pressure \(memory.pressure)")
        } else { check(false, "memory read") }
        if let network = stats.network {
            check(network.up >= 0 && network.down >= 0, "network: ↓ \(speed(network.down)) ↑ \(speed(network.up)) on \(network.interface ?? "?"), \(network.address ?? "no address")")
        } else { print("      network: nothing read (no primary interface?)") }
        if let disk = stats.disk {
            check(disk.free > 0 && disk.free < disk.total && disk.read != nil, "disk: \(bytes(disk.free)) free of \(bytes(disk.total)), read \(disk.read.map(speed) ?? "?"), write \(disk.write.map(speed) ?? "?")")
        } else { check(false, "disk read") }
        if let gpu = stats.gpu { check((0...1).contains(gpu), String(format: "gpu %.0f%%", gpu * 100)) } else { print("      gpu: not reported") }
        if let power = stats.power {
            check(power.drawn != nil, "power: \(power.drawn.map(watts) ?? "?") drawn; cpu \(power.cpu.map(watts) ?? "not reported"), gpu \(power.gpu.map(watts) ?? "not reported"); charger \(power.charger.map { "\($0) W" } ?? "none"); battery \(power.battery.map { "\($0)%" } ?? "none"), health \(power.health.map { "\($0)%" } ?? "?"), cycles \(power.cycles.map(String.init) ?? "?")")
        } else { check(false, "power read") }
        check(stats.energy != nil, "power panel open: an IOReport subscription")
        // Closed, the battery's reading is enough, where there's a battery.
        stats.panel = [.cpu, .memory]
        let battery = StatsReadings.power()?.system != nil
        check((stats.energy == nil) == battery, battery ? "power panel closed: no IOReport, the battery reports the draw"
                                                       : "power panel closed, no battery: IOReport kept for the draw")
        stats.panel = [.cpu, .memory, .power]
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        check(stats.power?.cpu != nil || stats.power?.gpu != nil, "power panel opened again: its watts a moment later, not at the next reading")
        if let report = EnergyReport() {
            _ = report.read()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let first = report.read(), soon = report.read()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let next = report.read()
            check(soon == first && (next.cpu != nil || next.gpu != nil),
                  "IOReport read twice in a moment (the panel's first figures and the timer): the last watts again, and the next read still has them")
        }
        let top = stats.apps.sorted { $0.memory > $1.memory }.prefix(3).map { "\($0.name) \(StatsController.memory($0.memory))" }
        check(!stats.apps.isEmpty, "top apps by memory: \(top.joined(separator: ", "))")
        check(stats.segments().count == StatKind.allCases.count, "a menu bar part for each stat shown")

        // A change of look keeps the timer and reads nothing early; a stat
        // turned on is read at once, the others aren't.
        let timer = stats.timer, tick = stats.live.tick, cpuBefore = stats.cpu
        stats.config.set(.cpu) { $0.look = .pill }
        check(stats.timer === timer && stats.live.tick == tick, "a new look: same timer, nothing read early")
        stats.config.set(.disk) { $0.shown = false }
        stats.config.set(.disk) { $0.shown = true }
        check(stats.disk != nil && stats.cpu == cpuBefore, "a stat turned on is read at once, and only it")
        var odd = StatsConfig()
        odd.interval = 0
        let decoded = (try? JSONEncoder().encode(odd)).flatMap { try? JSONDecoder().decode(StatsConfig.self, from: $0) }
        check(decoded?.interval == 2, "an interval of 0 from a file reads as 2 s")
        let old = try? JSONDecoder().decode(StatsConfig.self, from: Data(#"{"stats": {"gpu": {"shown": true, "look": "chart"}}}"#.utf8))
        check(old?.setting(.gpu) == StatSetting(shown: true, look: .chart) && old?.panelOnly == [], "a file from before panel-only stats keeps its stats")

        // Only in the panel: read all the while, for the panel's history; with
        // nothing in the menu bar, an icon there opens it.
        var panelOnly = stats.config
        for kind in StatKind.allCases { panelOnly.set(kind) { $0.place = kind == .gpu ? .panel : .off } }
        stats.config = panelOnly
        check(stats.timer != nil && stats.reading == [.cpu, .memory, .power, .gpu], "panel-only gpu is read with no part of its own (cpu, memory and power for the open panel)")
        let icon = stats.segments()
        check(icon.count == 1 && icon[0].kind == .stats && icon[0].text == nil, "nothing in the menu bar: one icon for the panel")
        stats.config.set(.disk) { $0.place = .menuBar }
        check(stats.segments().map(\.kind) == [.stat(.disk)], "a stat in the menu bar takes the icon's place")
        for kind in StatKind.allCases { stats.config.set(kind) { $0.place = .menuBar } }

        // What a reading of everything costs, top apps included and not.
        stats.stop()
        let start = cpuTime()
        for _ in 0..<20 { stats.read() }
        let withApps = (cpuTime() - start) / 20 * 1000
        stats.panel = []
        stats.stop()
        let plain = cpuTime()
        for _ in 0..<20 { stats.read() }
        let without = (cpuTime() - plain) / 20 * 1000
        print(String(format: "      a reading of every stat: %.2f ms of CPU, %.2f ms with the top apps", without, withApps))
        check(without < 3, "reading every stat stays under 3 ms")

        // Off again: everything let go of.
        stats.config.enabled = false
        check(stats.timer == nil && stats.cpuReader == nil && stats.energy == nil && stats.history.isEmpty && stats.apps.isEmpty,
              "off again: no timer, readers, history or subscription")
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }

    /// `--test-stats-panels`: each panel, sized to its content as the
    /// popover sizes it, costs nothing while nothing changes, and little as
    /// readings come in.
    static func panelTest() {
        _ = NSApplication.shared
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let stats = StatsController.preview()
        for kinds in StatKind.allCases.map({ [$0] }) + [StatKind.allCases] {
            let host = NSHostingController(rootView: StatsPanelView(stats: stats, kinds: kinds))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let start = cpu()
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            print(String(format: "%@ panel: %.1f%% of a core, left alone", kinds.count > 1 ? "every" : kinds[0].title, (cpu() - start) / 2 * 100))
            window.orderOut(nil)
        }

        // From a real menu bar item, as the app opens them: once closed, a
        // panel draws nothing as readings come in, and its view is let go of.
        let item = MenuBarItem()
        item.show([MenuBarSegment(kind: .toolkit, glyph: MenuBarArt.toolkit, label: "MacOS Toolkit")] + stats.segments())
        let popover = MenuBarPopover(menuBar: item)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        var failures = 0
        // The third taller than its room, so it scrolls, as on a short
        // display. In the last, something else holds on to the window, as a
        // cache in AppKit was seen to do with one panel in the app: it must
        // still let go of the panel.
        var kept: NSWindow?
        for (kinds, room, holdWindow) in [([StatKind.cpu], nil, false), (StatKind.allCases, nil, false), (StatKind.allCases, CGFloat(400), false),
                                          (StatKind.allCases, nil, true)] {
            let probe = PanelProbe()
            weak var held: PanelToken?
            var opened = false
            // Its own pool, as each event in the app has: the test runs
            // before the app's loop, which would otherwise keep it all.
            autoreleasepool {
                let token = PanelToken()
                held = token
                popover.show(from: .stat(kinds[0])) {
                    StatsPanelView(stats: stats, kinds: kinds, maxHeight: room).background(PanelProbeView(live: stats.live, probe: probe, token: token))
                }
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                opened = popover.isShown && probe.renders > 0
                if holdWindow { kept = NSApp.windows.first { "\(type(of: $0))".contains("Popover") && $0.isVisible } }
                if room != nil, let scroll = NSApp.windows.filter({ "\(type(of: $0))".contains("Popover") }).compactMap({ $0.contentView.flatMap(Self.scrollView) }).first {
                    // Scrolled part of the way down, as with the wheel.
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                }
                popover.close()
                RunLoop.main.run(until: Date().addingTimeInterval(1))
            }
            let before = probe.renders
            for _ in 0..<5 {
                stats.live.tick += 1
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            let ok = opened && probe.renders == before && held == nil
            print((ok ? "ok    " : "FAIL  ") + "\(kinds.count > 1 ? "every" : kinds[0].title) panel\(room == nil ? "" : ", scrolling,")\(holdWindow ? ", its window held elsewhere," : "") closed: \(probe.renders - before) renders after, view \(held == nil ? "let go of" : "kept")")
            if !ok { failures += 1 }
        }
        withExtendedLifetime(kept) {}

        // One opened while another is open, as a click on the next stat does.
        let first = PanelProbe()
        weak var firstHeld: PanelToken?
        autoreleasepool {
            let token = PanelToken()
            firstHeld = token
            popover.show(from: .stat(.cpu)) {
                StatsPanelView(stats: stats, kinds: [.cpu]).background(PanelProbeView(live: stats.live, probe: first, token: token))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            popover.show(from: .stat(.memory)) { StatsPanelView(stats: stats, kinds: [.memory]) }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        let before = first.renders
        for _ in 0..<5 {
            stats.live.tick += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let replaced = first.renders == before && firstHeld == nil && popover.isShown
        print((replaced ? "ok    " : "FAIL  ") + "a panel replaced by the next: \(first.renders - before) renders after, view \(firstHeld == nil ? "let go of" : "kept")")
        if !replaced { failures += 1 }
        autoreleasepool {
            popover.close()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        item.remove()
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }
}

extension StatsController {
    /// The first scroll view in a panel, to scroll it.
    fileprivate static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }
}

/// Counts a panel's renders.
private final class PanelProbe {
    var renders = 0
}

/// Held only by a panel's view, so it goes when the view does.
private final class PanelToken {}

private struct PanelProbeView: View {
    @ObservedObject var live: StatsLive
    let probe: PanelProbe
    let token: PanelToken

    var body: some View {
        probe.renders += 1
        return Color.clear
    }
}
