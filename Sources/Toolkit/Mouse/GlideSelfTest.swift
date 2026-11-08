#if TOOLKIT_DEV
import AppKit
import QuartzCore

extension Glide {
    /// `--test-glide`: how smooth scrolling lands on the display's frames,
    /// posting nothing. First the clocks, for real: a 120 Hz timer on a
    /// thread of its own, as the glide was driven before 0.28.0, against the
    /// main display's frames. Then a notch and a spin played out by the old
    /// glide on those timer ticks and by the new one on the frames, as each
    /// frame would show them.
    static func selfTest() {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { print("no display"); return }

        // The clocks: when each fires, for three seconds.
        let ticks = Locked([Double]())
        let thread = Thread {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in ticks.value.append(CACurrentMediaTime()) }
            RunLoop.current.add(timer, forMode: .common)
            RunLoop.current.run(until: Date().addingTimeInterval(3.2))
            timer.invalidate()
        }
        thread.qualityOfService = .userInteractive
        let recorder = FrameRecorder()
        let link = screen.displayLink(target: recorder, selector: #selector(FrameRecorder.frame(_:)))
        link.add(to: .main, forMode: .common)
        thread.start()
        RunLoop.main.run(until: Date().addingTimeInterval(3.3))
        link.invalidate()
        let frames = recorder.times
        let timerTicks = ticks.value
        guard frames.count > 20, timerTicks.count > 20 else { print("too few frames (\(frames.count)) or ticks (\(timerTicks.count))"); return }
        let rate = Double(frames.count - 1) / (frames.last! - frames.first!)
        print(String(format: "display: %.1f frames a second (%d frames); timer: %d ticks", rate, frames.count, timerTicks.count))

        var perFrame = [Int](repeating: 0, count: frames.count - 1)
        for tick in timerTicks {
            guard let i = frames.lastIndex(where: { $0 <= tick }), i < perFrame.count else { continue }
            perFrame[i] += 1
        }
        let counts = Dictionary(grouping: perFrame, by: { min($0, 3) }).mapValues(\.count)
        print("old: timer ticks in each frame: " + (0...3).map { "\($0 == 3 ? "3+" : "\($0)"): \(counts[$0] ?? 0)" }.joined(separator: ", ")
              + String(format: " (a steady %.0f a frame is smooth)", 120 / rate))

        // A notch, and a spin of eight at 15 a second, on the real frames and ticks.
        let start = frames[10]
        let scenarios: [(String, [Double])] = [("one notch of 90 pt", [0]), ("a spin, 8 notches at 15 a second", (0..<8).map { Double($0) / 15 })]
        for (name, notches) in scenarios {
            print("\n\(name):")
            let old = oldGlide(notches: notches.map { start + $0 }, ticks: timerTicks, frames: frames)
            let new = newGlide(notches: notches.map { start + $0 }, frames: frames, length: GlideSpeed.normal.duration)
            report("old (timer, 0.07 s ease)", old, total: 90 * Double(notches.count))
            report("new (frames, 0.22 s curve)", new, total: 90 * Double(notches.count))
        }
    }

    /// What each frame shows of the old glide: a share of what's left at
    /// every timer tick, as `WheelEngine.tick` did, added up frame by frame.
    private static func oldGlide(notches: [Double], ticks: [Double], frames: [Double]) -> [Int] {
        var remaining = 0.0, carry = 0.0, last = 0.0
        var shown = [Int](repeating: 0, count: frames.count - 1)
        var pending = notches
        for tick in ticks where tick >= notches[0] {
            while let next = pending.first, next <= tick {
                if remaining == 0 { last = next }
                remaining += 90
                pending.removeFirst()
            }
            guard remaining != 0 else { if pending.isEmpty { break } else { continue } }
            let dt = min(tick - last, 0.05)
            last = tick
            var move = remaining * (1 - exp(-dt / 0.07))
            if abs(remaining) < 0.5 { move = remaining }
            remaining -= move
            carry += move
            let whole = carry.rounded(.towardZero)
            carry -= whole
            if abs(remaining) < 0.01 { remaining = 0; carry = 0 }
            if let i = frames.lastIndex(where: { $0 <= tick }), i < shown.count { shown[i] += Int(whole) }
        }
        return shown
    }

    /// What each frame shows of the new glide: a step at each frame's time.
    private static func newGlide(notches: [Double], frames: [Double], length: Double) -> [Int] {
        var axis = Axis()
        var shown = [Int](repeating: 0, count: frames.count - 1)
        var pending = notches
        for (i, time) in frames.enumerated() where i < shown.count && time >= notches[0] {
            while let next = pending.first, next <= time {
                axis.add(90, at: next, length: length)
                pending.removeFirst()
            }
            // The step lands on the next frame shown, as a display link's target time.
            shown[i] = Int(axis.step(at: frames[i + 1]))
            if !axis.isMoving, pending.isEmpty { break }
        }
        return shown
    }

    /// Frames that move; stalls (a frame with nothing in the middle of a
    /// glide); bumps (the speed rising again while it slows, beyond a notch
    /// arriving); the crawl at the end (frames of a point or less); and the distance.
    private static func report(_ name: String, _ shown: [Int], total: Double) {
        guard let first = shown.firstIndex(where: { $0 != 0 }), let last = shown.lastIndex(where: { $0 != 0 }) else {
            print("  \(name): nothing moved"); return
        }
        let glide = Array(shown[first...last])
        let stalls = glide.filter { $0 == 0 }.count
        var bumps = 0
        for i in 2..<max(glide.count, 2) where glide[i] > glide[i - 1] && glide[i - 1] < glide[i - 2] { bumps += 1 }
        var crawl = 0
        for step in glide.reversed() { if abs(step) <= 1 { crawl += 1 } else { break } }
        let steps = glide.prefix(14).map(String.init).joined(separator: " ")
        print("  \(name): \(glide.count) frames, \(stalls) stalls, \(bumps) bumps, \(crawl) crawling at the end, largest step \(glide.max() ?? 0), "
              + "\(glide.reduce(0, +)) of \(Int(total)) pt")
        print("    first frames: \(steps)\(glide.count > 14 ? " …" : "")")
    }

    private final class FrameRecorder: NSObject {
        var times: [Double] = []
        @objc func frame(_ link: CADisplayLink) { times.append(link.targetTimestamp) }
    }
}
#endif
