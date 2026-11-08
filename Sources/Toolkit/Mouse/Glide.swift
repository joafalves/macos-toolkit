import AppKit
import QuartzCore

/// Smooth scrolling: each notch's distance played out over a short ease-out,
/// one step a frame of the display the pointer is on, timed by its display
/// link. On a timer of its own the steps beat against the display's frames,
/// some frames getting two and some none, which showed as judder.
///
/// Each axis is one curve from where it is to where the notches so far add up
/// to. A notch during a glide starts a new curve from there, at the speed it
/// was going (`Axis.add`), so a spin speeds up smoothly rather than jumping
/// at every notch, and every curve ends at rest at a set time rather than
/// crawling a point at a time.
///
/// Lives on the wheel tap's thread. The display links are made on the main
/// thread, run on the tap's, and are paused between glides, when they cost nothing.
final class Glide {
    /// One frame's step, in whole points each way, on the tap's thread.
    private let post: (_ x: Int32, _ y: Int32) -> Void
    private var x = Axis()
    private var y = Axis()
    /// Each display's link and where it is, in the events' coordinates.
    private var links: [(bounds: CGRect, link: CADisplayLink)] = []
    private var running: CADisplayLink?
    /// While there's no display link to be had.
    private var timer: Timer?

    init(post: @escaping (_ x: Int32, _ y: Int32) -> Void) {
        self.post = post
    }

    var isGliding: Bool { x.isMoving || y.isMoving }

    /// Adds a notch's distance, in points, gliding over `length` seconds, on
    /// the display at `location`.
    func add(x dx: Double, y dy: Double, length: Double, at location: CGPoint, now: Double = CACurrentMediaTime()) {
        if dx != 0 { x.add(dx, at: now, length: length) }
        if dy != 0 { y.add(dy, at: now, length: length) }
        guard isGliding, running == nil, timer == nil else { return }
        if let link = links.first(where: { $0.bounds.contains(location) })?.link ?? links.first?.link {
            running = link
            link.isPaused = false
        } else {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.frame(at: CACurrentMediaTime()) }
            RunLoop.current.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// The step for the frame shown at `time`: where the curves are then,
    /// less what's gone already.
    func frame(at time: Double) {
        let dx = x.step(at: time)
        let dy = y.step(at: time)
        if dx != 0 || dy != 0 { post(dx, dy) }
        if !isGliding { pause() }
    }

    /// Drops whatever is still to go, as a turn of the tap or the tool does.
    func cancel() {
        x = Axis()
        y = Axis()
        pause()
    }

    private func pause() {
        running?.isPaused = true
        running = nil
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Displays

    /// On the main thread: a paused link for each display, handed to the
    /// tap's run loop by `install`. Again whenever the displays change.
    static func makeLinks(target: LinkTarget) -> [(bounds: CGRect, link: CADisplayLink)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let link = screen.displayLink(target: target, selector: #selector(LinkTarget.frame(_:)))
            link.isPaused = true
            return (CGDisplayBounds(id), link)
        }
    }

    /// On the tap's thread: the links that drive the glide from now on.
    func install(_ new: [(bounds: CGRect, link: CADisplayLink)]) {
        cancel()
        for old in links { old.link.invalidate() }
        links = new
        for item in links { item.link.add(to: .current, forMode: .common) }
    }

    /// The display links' target, which they hold: it holds the glide weakly.
    final class LinkTarget: NSObject {
        weak var glide: Glide?
        @objc func frame(_ link: CADisplayLink) { glide?.frame(at: link.targetTimestamp) }
    }

    // MARK: - One axis

    /// A cubic from 0 to `distance` over `length` seconds, starting at
    /// `slope` (its speed times the length) and ending at rest. A slope of
    /// twice the distance is a plain ease-out, three times one that starts
    /// faster: within those it never overshoots or turns back.
    struct Axis {
        private var start = 0.0
        private var length = 1.0
        private var distance = 0.0
        private var slope = 0.0
        /// How far along the curve the steps so far have gone.
        private var done = 0.0
        /// What's gone but not yet sent, less than a point: kept across
        /// glides, so none of the distance is lost to whole points.
        private var carry = 0.0

        var isMoving: Bool { distance != 0 }

        /// A glide from rest starts at this many times the distance over its
        /// length: 2 is a plain ease-out, 3 a quicker start with a longer
        /// tail. Measured with `--test-glide` on a 120 Hz display, 2.5 starts
        /// as quickly as the glide before 0.28.0 and ends with no frames of
        /// a point or less, with the rest sent `finish` points from the end.
        static let startSlope = 2.5
        static let finish = 1.5

        private func progress(at time: Double) -> Double {
            min(max((time - start) / length, 0), 1)
        }

        func position(at time: Double) -> Double {
            let s = progress(at: time)
            return slope * (s * s * s - 2 * s * s + s) + distance * (3 * s * s - 2 * s * s * s)
        }

        /// In points a second.
        func velocity(at time: Double) -> Double {
            let s = progress(at: time)
            guard s < 1 else { return 0 }
            return (slope * (3 * s * s - 4 * s + 1) + distance * (6 * s - 6 * s * s)) / length
        }

        mutating func add(_ points: Double, at time: Double, length: Double) {
            var left = 0.0
            var speed = 0.0
            if isMoving {
                left = distance - position(at: time)
                speed = velocity(at: time)
            }
            // The other way: from rest, at once.
            if left * points < 0 || speed * points < 0 {
                left = 0
                speed = 0
                carry = 0
            }
            start = time
            self.length = length
            distance = left + points
            done = 0
            let size = abs(distance)
            slope = (distance < 0 ? -1 : 1) * min(max(abs(speed) * length, Self.startSlope * size), 3 * size)
        }

        mutating func step(at time: Double) -> Int32 {
            guard isMoving else { return 0 }
            let now = position(at: time)
            carry += now - done
            done = now
            // Within a point of the end, the rest goes now: apps take whole
            // points, and the last of a curve came as one every few frames.
            if progress(at: time) >= 1 || abs(distance - now) < Self.finish {
                carry += distance - now
                distance = 0
                // The last fraction, to the nearest point, rather than waiting on the next glide.
                let last = carry.rounded()
                carry -= last
                return Int32(last)
            }
            let whole = carry.rounded(.towardZero)
            carry -= whole
            return Int32(whole)
        }
    }
}
