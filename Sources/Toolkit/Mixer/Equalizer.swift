import Foundation
import Synchronization

/// A five band equalizer: a low shelf, three peaks and a high shelf.
struct EqualizerConfig: Codable, Equatable {
    static let frequencies: [Double] = [60, 250, 1000, 4000, 12000]
    static let labels = ["60", "250", "1k", "4k", "12k"]
    /// Each band boosts or cuts by up to this many decibels.
    static let range = 12.0

    var enabled = false
    var gains: [Double] = [0, 0, 0, 0, 0]

    /// Nothing to do, so the sound is left alone.
    var isFlat: Bool { gains.allSatisfy { $0 == 0 } }
    var isActive: Bool { enabled && !isFlat }

    /// The preset these gains match, if any.
    var presetName: String {
        EqualizerPreset.all.first { $0.gains == gains }?.name ?? String(localized: "Custom")
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let saved = (try? c.decodeIfPresent([Double].self, forKey: .gains)) ?? []
        gains = saved.count == Self.frequencies.count ? saved.map { min(Self.range, max(-Self.range, $0)) } : [0, 0, 0, 0, 0]
    }
}

struct EqualizerPreset: Identifiable {
    /// In the app's language, so it's only for showing.
    let name: String
    let gains: [Double]
    var id: [Double] { gains }

    init(_ name: String.LocalizationValue, gains: [Double]) {
        self.name = String(localized: name)
        self.gains = gains
    }

    static let loudness = EqualizerPreset("Loudness", gains: [5, 1, -1, 2, 5])

    static let all: [EqualizerPreset] = [
        .init("Flat", gains: [0, 0, 0, 0, 0]),
        .init("Bass Boost", gains: [6, 3, 0, 0, 0]),
        .init("Bass Reducer", gains: [-6, -3, 0, 0, 0]),
        .init("Treble Boost", gains: [0, 0, 0, 3, 6]),
        .init("Vocal", gains: [-2, -1, 3, 4, 1]),
        loudness,
        .init("Rock", gains: [4, 2, -1, 2, 4]),
        .init("Electronic", gains: [5, 2, 0, 1, 4]),
        .init("Acoustic", gains: [3, 1, 1, 2, 2]),
        .init("Small Speakers", gains: [4, 3, 0, 1, -1]),
        .init("Late Night", gains: [-4, -1, 2, 2, -2]),
    ]
}

/// The equalizer settings the audio thread reads. All bands and the on switch
/// are packed into one atomic word, so a change is always seen whole.
final class EqualizerState: Sendable {
    /// Gains in half decibels, one signed byte per band, plus an on bit.
    private let packed = Atomic<UInt64>(0)

    func set(_ config: EqualizerConfig) {
        var word: UInt64 = config.isActive ? 1 << 63 : 0
        for (band, gain) in config.gains.enumerated() {
            let halfDB = Int8(clamping: Int((gain * 2).rounded()))
            word |= UInt64(UInt8(bitPattern: halfDB)) << (8 * UInt64(band))
        }
        packed.store(word, ordering: .relaxed)
    }

    func load() -> UInt64 { packed.load(ordering: .relaxed) }

    static func isOn(_ word: UInt64) -> Bool { word & (1 << 63) != 0 }

    static func gain(_ word: UInt64, band: Int) -> Double {
        Double(Int8(bitPattern: UInt8(truncatingIfNeeded: word >> (8 * UInt64(band))))) / 2
    }
}

/// The filters one tap runs on its own audio thread: coefficients and the
/// filter memory for two channels. Recomputed only when the settings change.
final class EqualizerFilters {
    private static let bands = EqualizerConfig.frequencies.count
    private let sampleRate: Double
    /// b0, b1, b2, a1, a2 for each band.
    private let coefficients = UnsafeMutablePointer<Float>.allocate(capacity: bands * 5)
    /// z1, z2 for each band and channel.
    private let memory = UnsafeMutablePointer<Float>.allocate(capacity: bands * 2 * 2)
    private var active = [Bool](repeating: false, count: bands)
    private var seen: UInt64 = 0
    private(set) var isOn = false
    /// Turns the whole signal down by part of the largest boost, so boosts
    /// rarely clip; `limit` catches the rest.
    private(set) var preamp: Float = 1

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
        coefficients.initialize(repeating: 0, count: Self.bands * 5)
        memory.initialize(repeating: 0, count: Self.bands * 4)
    }

    deinit {
        coefficients.deallocate()
        memory.deallocate()
    }

    /// Called at the start of every buffer; cheap unless something changed.
    func update(_ word: UInt64) {
        guard word != seen else { return }
        seen = word
        isOn = EqualizerState.isOn(word)
        guard isOn else { return }
        var largestBoost = 0.0
        for band in 0..<Self.bands {
            let gain = EqualizerState.gain(word, band: band)
            largestBoost = max(largestBoost, gain)
            // Bands at 0 are skipped rather than run as a filter that does nothing.
            active[band] = gain != 0
            if gain != 0 { design(band: band, gain: gain) }
        }
        preamp = Float(pow(10, -largestBoost * 0.5 / 20))
    }

    @inline(__always)
    func process(_ input: Float, channel: Int) -> Float {
        var x = input
        for band in 0..<Self.bands where active[band] {
            let c = coefficients + band * 5
            let z = memory + (band * 2 + channel) * 2
            let y = c[0] * x + z[0]
            z[0] = c[1] * x - c[3] * y + z[1]
            z[1] = c[2] * x - c[4] * y
            x = y
        }
        return x
    }

    /// A soft knee above 0.8, so a boost that still clips rounds off instead of cracking.
    @inline(__always)
    static func limit(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > 0.8 else { return x }
        let over = (magnitude - 0.8) / 0.2
        return (0.8 + 0.2 * Float(tanh(Double(over)))) * (x < 0 ? -1 : 1)
    }

    /// Robert Bristow-Johnson's audio EQ cookbook: a low shelf for the first
    /// band, a high shelf for the last, peaks in between.
    private func design(band: Int, gain: Double) {
        let frequency = min(EqualizerConfig.frequencies[band], sampleRate * 0.45)
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        var b0, b1, b2, a0, a1, a2: Double
        if band == 0 || band == Self.bands - 1 {
            let alpha = sinW / 2 * 2.0.squareRoot()
            let root = 2 * a.squareRoot() * alpha
            if band == 0 {
                b0 = a * ((a + 1) - (a - 1) * cosW + root)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
                b2 = a * ((a + 1) - (a - 1) * cosW - root)
                a0 = (a + 1) + (a - 1) * cosW + root
                a1 = -2 * ((a - 1) + (a + 1) * cosW)
                a2 = (a + 1) + (a - 1) * cosW - root
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosW + root)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
                b2 = a * ((a + 1) + (a - 1) * cosW - root)
                a0 = (a + 1) - (a - 1) * cosW + root
                a1 = 2 * ((a - 1) - (a + 1) * cosW)
                a2 = (a + 1) - (a - 1) * cosW - root
            }
        } else {
            // Bands two octaves apart, so a fairly wide peak.
            let alpha = sinW / (2 * 0.8)
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a
        }
        let c = coefficients + band * 5
        c[0] = Float(b0 / a0)
        c[1] = Float(b1 / a0)
        c[2] = Float(b2 / a0)
        c[3] = Float(a1 / a0)
        c[4] = Float(a2 / a0)
    }
}
