import Foundation
import Synchronization

/// A ten band graphic equalizer, a band an octave from 32 Hz to 16 kHz, with
/// a preamp, as the Music app's: a band raises or lowers the volume at its
/// frequency, and the preamp the volume of everything. A slider's value is
/// what the sound gets at its band's frequency: the filters are set to make
/// it so (`EqualizerCurve`). Nothing is turned down unless the preamp is.
struct EqualizerConfig: Codable, Equatable {
    static let frequencies: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    /// Each band boosts or cuts by up to this many decibels.
    static let range = 12.0

    var enabled = false
    var gains = [Double](repeating: 0, count: frequencies.count)
    /// In dB, over the same range as the bands: taken down to leave room for
    /// boosts loud enough to make the limiter work.
    var preamp = 0.0

    /// The bands do nothing.
    var isFlat: Bool { gains.allSatisfy { $0 == 0 } }
    /// Nothing to do, so the sound is left alone.
    var isActive: Bool { enabled && (!isFlat || preamp != 0) }

    /// The preset these gains match, if any.
    var presetName: String {
        EqualizerPreset.all.first { $0.gains == gains }?.name ?? String(localized: "Custom")
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let saved = ((try? c.decodeIfPresent([Double].self, forKey: .gains)) ?? []).map { min(Self.range, max(-Self.range, $0)) }
        preamp = min(Self.range, max(-Self.range, try c.decodeIfPresent(Double.self, forKey: .preamp) ?? 0))
        if saved.count == Self.frequencies.count {
            // A preset picked before its values changed is still that preset.
            let key = EqualizerPreset.earlier.first { $0.value == saved }?.key
            gains = EqualizerPreset.all.first { $0.key == key }?.gains ?? saved
        } else if saved.count == EqualizerCurve.legacyFrequencies.count {
            gains = EqualizerCurve.fromFiveBands(saved)
        }
    }
}

/// How the equalizer is edited. The sound is the same ten band curve either
/// way: Simple's three sliders are handles on regions of it, so a preset, or
/// a switch between the two, sounds the same in both.
enum EqualizerMode: String, Codable {
    case simple, bands
}

/// Simple's handles, the classic tone controls. Each moves a region of the
/// ten bands, its middle fully and its edges less, so it shapes the curve
/// rather than steps it; neighbouring regions overlap a little, as tone
/// controls do.
enum EqualizerRegion: Int, CaseIterable, Identifiable {
    case bass, mid, treble

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .bass: return String(localized: "Bass")
        case .mid: return String(localized: "Mid")
        case .treble: return String(localized: "Treble")
        }
    }

    var help: String {
        switch self {
        case .bass: return String(localized: "The lows, up to about 250 Hz. Double-click for 0 dB.")
        case .mid: return String(localized: "The middle, from about 250 Hz to 4 kHz, where voices are. Double-click for 0 dB.")
        case .treble: return String(localized: "The highs, from about 2 kHz up. Double-click for 0 dB.")
        }
    }

    /// How much each band (32 Hz to 16 kHz) moves with the handle.
    var weights: [Double] {
        switch self {
        case .bass: return [1, 1, 0.8, 0.4, 0.1, 0, 0, 0, 0, 0]
        case .mid: return [0, 0, 0, 0.3, 0.8, 1, 0.8, 0.3, 0, 0]
        case .treble: return [0, 0, 0, 0, 0, 0, 0.2, 0.7, 1, 1]
        }
    }

    /// Where the handle sits: how much of its region's shape the curve has
    /// (the least-squares amount). From flat, Bass at +6 is its full bands at
    /// +6 and its edges less; on a curve with more in it, a summary.
    func level(_ gains: [Double]) -> Double {
        zip(gains, weights).reduce(0) { $0 + $1.0 * $1.1 } / weights.reduce(0) { $0 + $1 * $1 }
    }

    /// The bands with the handle at `target`: each moved by its weight, the
    /// full ones by as much as the handle, so the handle lands on the target.
    func setting(_ gains: [Double], to target: Double) -> [Double] {
        let step = target - level(gains)
        return zip(gains, weights).map { EqualizerCurve.clamped($0 + step * $1, to: 0.1) }
    }

    /// Whether three handles, moved from flat, can draw these bands: the
    /// closest they come (least squares) is within 1 dB of every band. If
    /// not, Simple shows a summary of the curve, and says so.
    static func fit(_ gains: [Double]) -> Bool {
        let regions = allCases.map(\.weights)
        let normal = regions.map { a in regions.map { b in zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } } }
        let projected = regions.map { a in zip(a, gains).reduce(0) { $0 + $1.0 * $1.1 } }
        guard let handles = EqualizerCurve.solve(normal, projected) else { return false }
        return gains.indices.allSatisfy { band in
            abs(gains[band] - zip(handles, regions).reduce(0) { $0 + $1.0 * $1.1[band] }) <= 1
        }
    }
}

struct EqualizerPreset: Identifiable {
    /// In the app's language, so it's only for showing.
    let name: String
    /// Its English name, which never changes.
    let key: String
    let gains: [Double]
    var id: String { key }

    init(_ name: String.LocalizationValue, key: String, gains: [Double]) {
        self.name = String(localized: name)
        self.key = key
        self.gains = gains
    }

    // 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k and 16k Hz.
    static let loudness = EqualizerPreset("Loudness", key: "Loudness", gains: [6, 5, 3, 1, 0, 0, 0, 0.5, 2, 3])

    // The Music app's values, apart from Loudness, Small Speakers and Late Night.
    static let all: [EqualizerPreset] = [
        .init("Flat", key: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init("Bass Boost", key: "Bass Boost", gains: [5.5, 4.25, 3.5, 2.5, 1.25, 0, 0, 0, 0, 0]),
        .init("Bass Reducer", key: "Bass Reducer", gains: [-5.5, -4.25, -3.5, -2.5, -1.25, 0, 0, 0, 0, 0]),
        .init("Treble Boost", key: "Treble Boost", gains: [0, 0, 0, 0, 0, 1.25, 2.5, 3.5, 4.25, 5.5]),
        .init("Treble Reducer", key: "Treble Reducer", gains: [0, 0, 0, 0, 0, -1.25, -2.5, -3.5, -4.25, -5.5]),
        .init("Vocal", key: "Vocal", gains: [-1.5, -3, -3, 1.5, 3.75, 3.75, 3, 1.5, 0, -1.5]),
        // The ear hears less of the lows and highs at low volume. The Music
        // app's dips 5 dB at 4 kHz and is back up 5 dB at 8 kHz.
        loudness,
        .init("Rock", key: "Rock", gains: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        .init("Electronic", key: "Electronic", gains: [4.25, 3.8, 1.2, 0, -2.15, 2.25, 0.85, 1.25, 3.95, 4.8]),
        .init("Acoustic", key: "Acoustic", gains: [5, 4.9, 3.95, 1.05, 2.15, 1.75, 3.5, 4.1, 3.55, 2.15]),
        .init("Classical", key: "Classical", gains: [4.75, 3.75, 3, 2.5, -1.5, -1.5, 0, 2.25, 3.25, 3.75]),
        .init("Hip-Hop", key: "Hip-Hop", gains: [5, 4.25, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        .init("Pop", key: "Pop", gains: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        // Small speakers can't play the deepest bass: it's taken out, and the
        // upper bass they can play brought up to stand in for it. The Music
        // app's raises the deepest bass instead.
        .init("Small Speakers", key: "Small Speakers", gains: [-6, -3, 2, 3, 2, 0.5, 0, 1, 1, 0]),
        // Less bass and treble, voices up front, for listening quietly.
        .init("Late Night", key: "Late Night", gains: [-5, -4, -2.5, -1, 0.5, 2, 2, 1, -0.5, -2]),
    ]

    /// Presets as they were before 0.24, which now have the Music app's values.
    static let earlier: [String: [Double]] = [
        "Bass Boost": [5, 5, 4, 2.5, 1, 0, 0, 0, 0, 0],
        "Bass Reducer": [-5, -5, -4, -2.5, -1, 0, 0, 0, 0, 0],
        "Treble Boost": [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 5],
        "Treble Reducer": [0, 0, 0, 0, 0, -1, -2.5, -4, -5, -5],
        "Vocal": [-3, -2.5, -1.5, 0, 1.5, 3, 3.5, 3, 1.5, 0],
        "Rock": [4, 3.5, 2.5, 0.5, -1, -1.5, 0, 2, 3, 3],
        "Electronic": [5.5, 5, 2.5, 0, -1.5, -1, 0, 1, 3, 4],
        "Acoustic": [2.5, 2.5, 2, 1, 0, 0, 1, 2, 2.5, 1.5],
    ]
}


/// One biquad's coefficients, from Robert Bristow-Johnson's audio EQ cookbook.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    /// A peak of `gain` dB at `frequency`; Q 1 is about an octave and a half wide.
    static func peak(_ frequency: Double, gain: Double, q: Double = EqualizerCurve.q, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q), cosW = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cosW / a0, b2: (1 - alpha * a) / a0,
                      a1: -2 * cosW / a0, a2: (1 - alpha / a) / a0)
    }

    /// A shelf with a slope of 1, `gain` dB below (`low`) or above `frequency`,
    /// half of it at `frequency`. Only for reading equalizers saved before 0.21.
    static func shelf(_ frequency: Double, gain: Double, low: Bool, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosW = cos(w0), root = 2 * a.squareRoot() * sin(w0) / 2 * 2.0.squareRoot()
        let sign: Double = low ? 1 : -1
        let a0 = (a + 1) + sign * (a - 1) * cosW + root
        return Biquad(b0: a * ((a + 1) - sign * (a - 1) * cosW + root) / a0,
                      b1: sign * 2 * a * ((a - 1) - sign * (a + 1) * cosW) / a0,
                      b2: a * ((a + 1) - sign * (a - 1) * cosW - root) / a0,
                      a1: -sign * 2 * ((a - 1) + sign * (a + 1) * cosW) / a0,
                      a2: ((a + 1) + sign * (a - 1) * cosW - root) / a0)
    }

    /// How much it changes a tone at `frequency`, in dB.
    func decibels(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numerator = hypot(b0 + b1 * c1 + b2 * c2, b1 * s1 + b2 * s2)
        let denominator = hypot(1 + a1 * c1 + a2 * c2, a1 * s1 + a2 * s2)
        return 20 * log10(numerator / denominator)
    }
}

/// The shape behind the sliders, worked out on the main thread whenever they
/// change. Neighbouring bands overlap, so set as they read, ten +6 dB bands
/// would come to +11 dB; the filters are set so the sound gets each slider's
/// value at its band, as an accurate cascade graphic equalizer does (Liski
/// and Välimäki, "The Quest for the Best Graphic Equalizer", DAFx 2017).
enum EqualizerCurve {
    /// Wide enough that bands set alike join without dips between them.
    static let q = 1.0

    /// What the filters are set to, so the curve passes through each slider's
    /// value at its band's frequency.
    static func filterGains(for sliders: [Double], sampleRate: Double) -> [Double] {
        guard sliders.contains(where: { $0 != 0 }) else { return sliders }
        let centres = EqualizerConfig.frequencies
        var gains = sliders
        // Each filter's effect is nearly proportional to its gain, so a few
        // linear steps find the gains that land on the sliders.
        for _ in 0..<5 {
            let error = zip(sliders, centres.map { response(gains, at: $0, sampleRate: sampleRate) }).map { $0 - $1 }
            if error.allSatisfy({ abs($0) < 0.005 }) { break }
            let slopes = centres.map { centre in
                centres.indices.map { band in
                    let gain = abs(gains[band]) > 0.1 ? gains[band] : 1
                    return Biquad.peak(centres[band], gain: gain, sampleRate: sampleRate).decibels(at: centre, sampleRate: sampleRate) / gain
                }
            }
            guard let step = solve(slopes, error) else { break }
            gains = zip(gains, step).map { min(24, max(-24, $0 + $1)) }
        }
        return gains
    }

    /// A band dragged with ⌥: the bands beside it follow, less the further
    /// they are, on a bell curve over the distance in bands (the next one 61%
    /// as far, the one after 14%, the rest barely), each from where it was
    /// when the drag began.
    static func linked(_ start: [Double], band: Int, to target: Double) -> [Double] {
        let delta = target - start[band]
        return start.indices.map { index in
            if index == band { return target }
            let distance = Double(index - band)
            return clamped(start[index] + delta * exp(-distance * distance / 2), to: 0.1)
        }
    }

    /// Within ±12 dB, in steps of `step`.
    static func clamped(_ gain: Double, to step: Double) -> Double {
        min(EqualizerConfig.range, max(-EqualizerConfig.range, (gain / step).rounded() * step))
    }

    /// The sound's change at `frequency`, in dB, with the filters at `gains`.
    static func response(_ gains: [Double], at frequency: Double, sampleRate: Double) -> Double {
        zip(EqualizerConfig.frequencies, gains).reduce(0) { sum, band in
            band.1 == 0 ? sum : sum + Biquad.peak(band.0, gain: band.1, sampleRate: sampleRate).decibels(at: frequency, sampleRate: sampleRate)
        }
    }

    /// The curve's highest point, in dB, between 20 Hz and 20 kHz, read every
    /// 24th of an octave. Turned down by this, the equalizer can't take a
    /// tone at full scale over it.
    static func highest(_ gains: [Double], sampleRate: Double) -> Double {
        let top = min(20_000, sampleRate * 0.45)
        var frequency = 20.0, highest = 0.0
        while frequency <= top {
            highest = max(highest, response(gains, at: frequency, sampleRate: sampleRate))
            frequency *= pow(2, 1.0 / 24)
        }
        return highest
    }

    /// Gaussian elimination with partial pivoting; nil when it can't be solved.
    static func solve(_ matrix: [[Double]], _ values: [Double]) -> [Double]? {
        let n = values.count
        var rows = matrix.enumerated().map { $0.element + [values[$0.offset]] }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }),
                  abs(rows[pivot][column]) > 1e-9 else { return nil }
            rows.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = rows[row][column] / rows[column][column]
                rows[row] = zip(rows[row], rows[column]).map { $0 - factor * $1 }
            }
        }
        return (0..<n).map { rows[$0][n] / rows[$0][$0] }
    }

    // MARK: - Equalizers saved before 0.21

    /// Five bands then: shelves at 60 Hz and 12 kHz, peaks two octaves apart between.
    static let legacyFrequencies: [Double] = [60, 250, 1000, 4000, 12000]
    private static let legacyPresets: [String: [Double]] = [
        "Flat": [0, 0, 0, 0, 0], "Bass Boost": [6, 3, 0, 0, 0], "Bass Reducer": [-6, -3, 0, 0, 0],
        "Treble Boost": [0, 0, 0, 3, 6], "Vocal": [-2, -1, 3, 4, 1], "Loudness": [5, 1, -1, 2, 5],
        "Rock": [4, 2, -1, 2, 4], "Electronic": [5, 2, 0, 1, 4], "Acoustic": [3, 1, 1, 2, 2],
        "Small Speakers": [4, 3, 0, 1, -1], "Late Night": [-4, -1, 2, 2, -2],
    ]

    /// A preset becomes the same preset; anything else the sliders that
    /// sound like it did, read off the old curve at the new bands.
    static func fromFiveBands(_ old: [Double]) -> [Double] {
        if let key = legacyPresets.first(where: { $0.value == old })?.key,
           let preset = EqualizerPreset.all.first(where: { $0.key == key }) {
            return preset.gains
        }
        let rate = 48_000.0
        let filters = old.enumerated().map { band, gain -> Biquad in
            let frequency = legacyFrequencies[band]
            if band == 0 || band == old.count - 1 { return .shelf(frequency, gain: gain, low: band == 0, sampleRate: rate) }
            return .peak(frequency, gain: gain, q: 0.8, sampleRate: rate)
        }
        return EqualizerConfig.frequencies.map { frequency in
            let value = filters.reduce(0) { $0 + $1.decibels(at: frequency, sampleRate: rate) }
            return min(EqualizerConfig.range, max(-EqualizerConfig.range, (value * 2).rounded() / 2))
        }
    }
}

/// What the audio threads read: the filters' gains and the preamp in
/// hundredths of a dB, four to a word, and whether it's on. Written only on
/// the main thread; a sequence number tells a reader it caught a write half
/// done, which it then skips until the next buffer.
final class EqualizerState: Sendable {
    private let sequence = Atomic<UInt64>(0)
    private let low = Atomic<UInt64>(0)
    private let middle = Atomic<UInt64>(0)
    private let high = Atomic<UInt64>(0)

    /// Index of the preamp and the on flag in the packed values, after the bands.
    static let preampSlot = EqualizerConfig.frequencies.count
    static let onSlot = preampSlot + 1

    func set(on: Bool, gains: [Double], preamp: Double) {
        var values = gains.map { Int16(clamping: Int(($0 * 100).rounded())) }
        values.append(Int16(clamping: Int((preamp * 100).rounded())))
        values.append(on ? 1 : 0)
        var packed: [UInt64] = [0, 0, 0]
        for (index, value) in values.enumerated() {
            packed[index / 4] |= UInt64(UInt16(bitPattern: value)) << (16 * UInt64(index % 4))
        }
        let next = sequence.load(ordering: .relaxed) &+ 1
        sequence.store(next, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        low.store(packed[0], ordering: .relaxed)
        middle.store(packed[1], ordering: .relaxed)
        high.store(packed[2], ordering: .relaxed)
        sequence.store(next &+ 1, ordering: .releasing)
    }

    /// The three words, or nil while a write is under way.
    func load() -> (UInt64, UInt64, UInt64)? {
        let before = sequence.load(ordering: .acquiring)
        guard before % 2 == 0 else { return nil }
        let values = (low.load(ordering: .relaxed), middle.load(ordering: .relaxed), high.load(ordering: .relaxed))
        atomicMemoryFence(ordering: .acquiring)
        return sequence.load(ordering: .relaxed) == before ? values : nil
    }

    @inline(__always)
    static func value(_ words: (UInt64, UInt64, UInt64), _ slot: Int) -> Double {
        let word = slot < 4 ? words.0 : slot < 8 ? words.1 : words.2
        return Double(Int16(bitPattern: UInt16(truncatingIfNeeded: word >> (16 * UInt64(slot % 4))))) / 100
    }
}

/// The equalizer one tap runs on its own audio thread: the filters, the
/// preamp, the limiter, and the fade between the plain sound and the
/// equalized one. The filters run in double precision: the lowest bands sit
/// so close to 0 Hz that single precision would add noise and shift them.
/// Changes glide over about 30 ms, the preamp a step every sample and the
/// filters every 16, so dragging a band or picking a preset doesn't click.
///
/// Everything through it is held back by the limiter's look-ahead, 1.5 ms,
/// equalized or not, so a tap's delay never changes and two taps always line
/// up, which is what lets an app move between them without a click.
/// No allocation, no locks.
final class EqualizerFilters {
    /// A literal: it's a constant, where a global worked out from another can
    /// wait on a lock the first time it's read, which the audio thread mustn't.
    private static let bands = 10
    private let sampleRate: Double
    /// b0, b1, b2, a1, a2 for each band.
    private let coefficients = UnsafeMutablePointer<Double>.allocate(capacity: EqualizerFilters.bands * 5)
    /// z1, z2 for each band and channel.
    private let memory = UnsafeMutablePointer<Double>.allocate(capacity: EqualizerFilters.bands * 4)
    /// The gain each filter has now, and the one it's gliding to.
    private let current = UnsafeMutablePointer<Double>.allocate(capacity: EqualizerFilters.bands)
    private let target = UnsafeMutablePointer<Double>.allocate(capacity: EqualizerFilters.bands)
    /// The bands' frequencies, copied for the same reason.
    private let frequencies = UnsafeMutablePointer<Double>.allocate(capacity: EqualizerFilters.bands)
    private var seen: (UInt64, UInt64, UInt64) = (0, 0, 0)
    private var preamp = 1.0, targetPreamp = 1.0
    private var gliding = false
    private var countdown = 0
    private static let block = 16
    /// The share of what's left to go, per sample and per block of filters.
    private let sampleShare: Double
    private let blockShare: Double
    private(set) var isOn = false
    /// How much of the equalized sound is heard, 0 to 1. It moves toward on
    /// or off over 20 ms, so the switch never cuts between two sounds.
    private var mix: Float = 0
    private let fade: Float
    let limiter: PeakLimiter
    /// The plain sound, held back as long as the limiter holds the equalized one.
    private let dry: DelayLine

    init(sampleRate: Double, ceiling: Double = PeakLimiter.ceiling) {
        precondition(EqualizerConfig.frequencies.count == Self.bands)
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
        limiter = PeakLimiter(sampleRate: self.sampleRate, ceiling: ceiling)
        dry = DelayLine(limiter.delay)
        fade = Float(1 / (self.sampleRate * 0.02))
        sampleShare = 1 - exp(-1 / (self.sampleRate * 0.03))
        blockShare = 1 - exp(-Double(Self.block) / (self.sampleRate * 0.03))
        for band in 0..<Self.bands {
            (coefficients + band * 5).initialize(from: [1, 0, 0, 0, 0], count: 5)
        }
        memory.initialize(repeating: 0, count: Self.bands * 4)
        current.initialize(repeating: 0, count: Self.bands)
        target.initialize(repeating: 0, count: Self.bands)
        frequencies.initialize(from: EqualizerConfig.frequencies, count: Self.bands)
    }

    deinit {
        coefficients.deallocate()
        memory.deallocate()
        current.deallocate()
        target.deallocate()
        frequencies.deallocate()
    }

    /// Called at the start of every buffer with what `EqualizerState` holds.
    func update(_ words: (UInt64, UInt64, UInt64)?) {
        guard let words, words != seen else { return }
        seen = words
        isOn = EqualizerState.value(words, EqualizerState.onSlot) != 0
        for band in 0..<Self.bands { target[band] = EqualizerState.value(words, band) }
        targetPreamp = pow(10, EqualizerState.value(words, EqualizerState.preampSlot) / 20)
        gliding = true
        // Not heard yet: no glide, straight to it, from silence.
        if mix == 0 {
            preamp = targetPreamp
            glideBands(1)
            memory.update(repeating: 0, count: Self.bands * 4)
            limiter.reset()
        }
    }

    @inline(__always)
    private func advance() {
        guard gliding else { return }
        preamp += (targetPreamp - preamp) * sampleShare
        countdown -= 1
        if countdown <= 0 {
            countdown = Self.block
            glideBands(blockShare)
        }
    }

    private func glideBands(_ share: Double) {
        var moving = false
        for band in 0..<Self.bands where current[band] != target[band] {
            let gap = target[band] - current[band]
            current[band] = abs(gap) < 0.005 ? target[band] : current[band] + gap * share
            moving = moving || current[band] != target[band]
            let filter = Biquad.peak(frequencies[band], gain: current[band], q: EqualizerCurve.q, sampleRate: sampleRate)
            let c = coefficients + band * 5
            (c[0], c[1], c[2], c[3], c[4]) = (filter.b0, filter.b1, filter.b2, filter.a1, filter.a2)
        }
        if abs(targetPreamp - preamp) < 0.00001 { preamp = targetPreamp } else { moving = true }
        gliding = moving
    }

    /// One stereo sample in, the sample that comes out: the plain sound,
    /// the equalized one, or a fade between them, 1.5 ms later.
    @inline(__always)
    func process(_ left: inout Float, _ right: inout Float) {
        var (plainLeft, plainRight) = (left, right)
        dry.pass(&plainLeft, &plainRight)
        guard isOn || mix > 0 else {
            (left, right) = (plainLeft, plainRight)
            return
        }
        var l = Double(left), r = Double(right)
        equalize(&l, &r)
        var (equalizedLeft, equalizedRight) = (Float(l), Float(r))
        limiter.process(&equalizedLeft, &equalizedRight)
        let wet = nextMix()
        left = plainLeft + (equalizedLeft - plainLeft) * wet
        right = plainRight + (equalizedRight - plainRight) * wet
    }

    /// The bands and the preamp alone, with no limiter and no delay.
    @inline(__always)
    func equalize(_ l: inout Double, _ r: inout Double) {
        advance()
        l *= preamp
        r *= preamp
        for band in 0..<Self.bands where current[band] != 0 {
            let c = coefficients + band * 5
            let z = memory + band * 4
            let yl = c[0] * l + z[0]
            z[0] = c[1] * l - c[3] * yl + z[1]
            z[1] = c[2] * l - c[4] * yl
            l = yl
            let yr = c[0] * r + z[2]
            z[2] = c[1] * r - c[3] * yr + z[3]
            z[3] = c[2] * r - c[4] * yr
            r = yr
        }
    }

    /// The share of the equalized sound for the next sample.
    @inline(__always)
    private func nextMix() -> Float {
        if isOn {
            mix = min(1, mix + fade)
        } else if mix > 0 {
            mix = max(0, mix - fade)
            // Faded out: the next fade in starts from silence, not from old sound.
            if mix == 0 {
                memory.update(repeating: 0, count: Self.bands * 4)
                limiter.reset()
            }
        }
        return mix
    }
}

/// A stereo delay of a fixed number of samples.
final class DelayLine {
    private let length: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var index = 0

    init(_ samples: Int) {
        length = max(1, samples)
        left = .allocate(capacity: length)
        right = .allocate(capacity: length)
        reset()
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func reset() {
        left.update(repeating: 0, count: length)
        right.update(repeating: 0, count: length)
    }

    /// Puts a sample in and takes out the one from `length` samples ago.
    @inline(__always)
    func pass(_ l: inout Float, _ r: inout Float) {
        swap(&l, &left[index])
        swap(&r, &right[index])
        index = index + 1 == length ? 0 : index + 1
    }
}

/// The last stage after the equalizer: keeps the sound below full scale,
/// where it would otherwise clip, without a click. It sees each peak 1.5 ms
/// ahead and turns down smoothly before it, by no more than the peak needs,
/// then comes back over about 60 ms, as a mastering limiter does. Boosts can
/// take loud music over, and even cuts can: filtering mastered music, whose
/// peaks were shaved flat, builds them up again. Turning down on the sample
/// itself, as a clipper does, crackles; measured on real music, this moves
/// at most 0.05 dB from one sample to the next, where that moved up to 2.2.
/// Lowering the preamp keeps it from having to work.
///
/// Each sample's gain is the lowest any sample in the next 1.5 ms needs (a
/// running minimum), averaged over 1.5 ms so it ramps rather than steps; the
/// average of a window that a peak's need holds down entirely can't be
/// above it, so the peak always fits. Both channels share one gain, so the
/// stereo image doesn't move.
final class PeakLimiter {
    /// -0.18 dB, a little under full scale.
    static let ceiling = 0.98
    /// How long each sample is held back.
    let delay: Int
    private let window: Int
    private let ceiling: Double
    private let recovery: Double
    private let line: DelayLine
    /// The running minimum: needs, with the sample they came at, oldest first.
    private let needs: UnsafeMutablePointer<Double>
    private let times: UnsafeMutablePointer<Int>
    private var first = 0, count = 0
    /// The last `window` minimums and their sum, for the average.
    private let minimums: UnsafeMutablePointer<Double>
    private var sum = 0.0
    private var time = 0
    private(set) var gain = 1.0

    init(sampleRate: Double, ceiling: Double = PeakLimiter.ceiling) {
        window = max(2, Int((sampleRate * 0.0015).rounded()))
        delay = window - 1
        self.ceiling = ceiling
        recovery = 1 - exp(-1 / (sampleRate * 0.06))
        line = DelayLine(delay)
        needs = .allocate(capacity: window)
        times = .allocate(capacity: window)
        minimums = .allocate(capacity: window)
        reset()
    }

    deinit {
        needs.deallocate()
        times.deallocate()
        minimums.deallocate()
    }

    func reset() {
        line.reset()
        minimums.update(repeating: 1, count: window)
        sum = Double(window)
        first = 0
        count = 0
        gain = 1
    }

    @inline(__always)
    func process(_ left: inout Float, _ right: inout Float) {
        let level = Double(max(abs(left), abs(right)))
        let need = level > ceiling ? ceiling / level : 1
        // The running minimum over the last `window` samples: the one that
        // fell out of the window goes first, so a full queue never wraps
        // over its oldest, lowest need.
        while count > 0, times[first] <= time - window {
            first = (first + 1) % window
            count -= 1
        }
        while count > 0, needs[(first + count - 1) % window] >= need { count -= 1 }
        needs[(first + count) % window] = need
        times[(first + count) % window] = time
        count += 1
        let minimum = needs[first]
        // Its average over the window, so the gain ramps down ahead of the peak.
        let slot = time % window
        sum += minimum - minimums[slot]
        minimums[slot] = minimum
        if slot == 0 {
            // Adding and taking away for hours would drift a little.
            sum = 0
            for index in 0..<window { sum += minimums[index] }
        }
        let smooth = min(1, sum / Double(window))
        gain = smooth < gain ? smooth : gain + (smooth - gain) * recovery
        time += 1
        line.pass(&left, &right)
        left = Float(Double(left) * gain)
        right = Float(Double(right) * gain)
    }
}
