import AppKit
import AVFoundation
import CoreAudio
import Foundation

extension MixerController {
    /// The volume keys' steps in each size, with ⇧⌥, and saved software
    /// volumes from before 0.19 read onto the even scale: each should sound
    /// as it did.
    static func volumeTest() {
        func walk(_ size: Double, from start: Double, _ key: VolumeKey, presses: Int) -> String {
            var volume = start, muted = false, out: [String] = []
            for _ in 0..<presses {
                volume = step(volume, muted: &muted, key: key, size: size)
                out.append(String(format: "%.4g", volume * 100))
            }
            return out.joined(separator: " ")
        }
        let fresh = MixerConfig(), empty = try? JSONDecoder().decode(MixerConfig.self, from: Data("{}".utf8))
        let defaultsOK = fresh.keyStep == .standard && fresh.fineStep == 1 && empty?.keyStep == .standard && empty?.fineStep == 1
        print("\(defaultsOK ? "ok  " : "DIFF") defaults: each press \(fresh.keyStep.rawValue), ⇧⌥ \(fresh.fineStep); from a file without them: \(empty?.keyStep.rawValue ?? "?"), \(empty?.fineStep ?? -1)")
        for step in VolumeKeyStep.allCases {
            let size = 1 / Double(step.presses)
            var volume = 0.0, muted = false, presses = 0
            while volume < 1 { volume = Self.step(volume, muted: &muted, key: .up, size: size); presses += 1 }
            print("\(step.rawValue): \(presses) presses from 0 to 100%, first up: \(walk(size, from: 0, .up, presses: 4))")
        }
        let standard = 1.0 / 16
        print("standard from 37% (slider): up \(walk(standard, from: 0.37, .up, presses: 2)), down \(walk(standard, from: 0.37, .down, presses: 2))")
        print("standard from 50%, Float: down \(walk(standard, from: Double(Float(0.5)), .down, presses: 2))")
        print("⇧⌥ at 1 from 35: up \(walk(0.01, from: 0.35, .up, presses: 3)); from 37.5 (a Standard step): up \(walk(0.01, from: 0.375, .up, presses: 2))")
        print("⇧⌥ at 2 from 100: down \(walk(0.02, from: 1, .down, presses: 2)); at 5 from 98: up \(walk(0.05, from: 0.98, .up, presses: 2))")
        print("muted, then up: unmutes first")
        var muted = true
        let kept = step(0.5, muted: &muted, key: .up, size: standard)
        print("  volume \(kept), muted \(muted)")

        print("software gain on the even scale (dB):")
        for level in [1.0 / 16, 0.25, 0.5, 0.75, 1] {
            var setting = SoftwareVolume()
            setting.volume = level
            print(String(format: "  %5.1f%% -> %6.1f dB", level * 100, 20 * log10(Double(setting.gain))))
        }
        builtInCurveCheck()
        print("saved before 0.19 (gain = volume²), read now:")
        for old in [0.0, 0.01, 0.1, 0.25, 0.5, 0.8, 1] {
            let json = Data(#"{"volume": \#(old), "muted": false}"#.utf8)
            guard let setting = try? JSONDecoder().decode(SoftwareVolume.self, from: json) else { print("  \(old): FAILED"); continue }
            let before = old <= 0 ? -Double.infinity : 40 * log10(old)
            let after = setting.gain <= 0 ? -Double.infinity : 20 * log10(Double(setting.gain))
            // Quieter than the even scale's lowest step: that step.
            let verdict = abs(before - after) < 0.01 || (old <= 0 && setting.volume <= 0) ? "same"
                : before < -SoftwareVolume.range && setting.volume == 0.01 ? "the scale's lowest" : "DIFFERENT"
            print(String(format: "  %4.0f%% (%6.1f dB) -> %5.1f%% (%6.1f dB) %@", old * 100, before, setting.volume * 100, after, verdict))
        }
        var setting = SoftwareVolume()
        setting.volume = 0.8
        let round = (try? JSONEncoder().encode(setting)).flatMap { try? JSONDecoder().decode(SoftwareVolume.self, from: $0) }
        print("saved and read again: \(round?.volume ?? -1) (expect 0.8), file: \(String(decoding: (try? JSONEncoder().encode(setting)) ?? Data(), as: UTF8.self))")
    }

    /// The software volume's curve against the one this Mac's own output
    /// reports, which is what macOS steps through on its speakers. A macOS
    /// that changes it shows here.
    private static func builtInCurveCheck() {
        func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                         _ element: UInt32, _ value: inout T) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
            var size = UInt32(MemoryLayout<T>.size)
            return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) } == noErr
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        let output = kAudioObjectPropertyScopeOutput
        for device in devices {
            var transport: UInt32 = 0
            guard property(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0, &transport),
                  transport == kAudioDeviceTransportTypeBuiltIn
            else { continue }
            for element: UInt32 in [0, 1] {
                var range = AudioValueRange()
                guard property(device, kAudioDevicePropertyVolumeRangeDecibels, output, element, &range) else { continue }
                let name = device.readString(kAudioObjectPropertyName) ?? ""
                var worst = 0.0, at = 0
                for step in 1...16 {
                    var db = Float32(step) / 16
                    guard property(device, kAudioDevicePropertyVolumeScalarToDecibels, output, element, &db) else { continue }
                    var setting = SoftwareVolume()
                    setting.volume = Double(step) / 16
                    let ours = 20 * log10(Double(setting.gain))
                    let off = abs(Double(db) - Double(range.mMaximum) - ours)
                    if off > worst { (worst, at) = (off, step) }
                }
                print(String(format: "%@ the software volume against %@ (%.1f to %.1f dB): at most %.2f dB apart%@",
                             worst < 1 ? "ok  " : "DIFF", name, range.mMinimum, range.mMaximum, worst,
                             worst < 1 ? "" : " (at \(at)/16)"))
                return
            }
        }
        print("     no built-in output with a volume of its own here, so nothing to compare with")
    }
}

extension MixerController {
    /// `--test-audio-access <report>`: what the hardened runtime could block.
    /// A listening tap on everything (nothing is muted) and two seconds of
    /// a small area recorded with the microphone, which is then deleted. Run
    /// the app bundle with `open -n`, so the permissions are the app's own.
    static func accessTest(into path: String) {
        _ = NSApplication.shared
        var lines = ["microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = allowed), "
            + "screen recording: \(CGPreflightScreenCaptureAccess()), system audio: \(AudioPermission.status)"]
        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        if let uid = output.readString(kAudioDevicePropertyDeviceUID),
           let tap = AppTap(objects: [], deviceUID: uid, gain: 1, controlsVolume: false, isGlobal: true) {
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            lines.append("tap: started, loudest \(String(format: "%.3f", tap.takePeak())) (0 when nothing plays)")
        } else {
            lines.append("tap: FAILED (see the log for the step)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-access-\(UUID().uuidString).mp4")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { try? FileManager.default.removeItem(at: url); done.signal() }
            do {
                let recorder = Recorder(url: url)
                try await recorder.start(.area(CGRect(x: 0, y: 0, width: 64, height: 64)), options: .init(frameRate: 15, microphone: true), excluding: [])
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let saved = await recorder.stop()
                let asset = AVURLAsset(url: url)
                let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                let peak = tracks.first.flatMap { loudest(in: asset, track: $0) }
                lines.append("microphone recording: saved \(saved), \(tracks.count) audio track(s), "
                    + "loudest \(peak.map { String(format: "%.4f", $0) } ?? "unreadable") (0 is silence: blocked)")
            } catch {
                lines.append("microphone recording: FAILED \(error.localizedDescription)")
            }
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The loudest sample in an audio track: a microphone that's blocked still
    /// gives a track, of silence. Nil when the track can't be read as samples:
    /// adding an output the reader can't take throws, and that ended the app.
    private static func loudest(in asset: AVAsset, track: AVAssetTrack) -> Float? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.startReading()
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var data: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data) == noErr,
                  let data else { continue }
            data.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                for i in 0..<length / 4 { peak = max(peak, abs(floats[i])) }
            }
        }
        return peak
    }
}

#if TOOLKIT_DEV
extension MixerController {
    /// `--test-equalizer`: the curve each preset gives against its sliders,
    /// the headroom left for it, tones measured through the filters the taps
    /// run, the limiter at full scale, a preset change mid-tone, and
    /// equalizers saved with five bands read into ten.
    static func equalizerTest() {
        let rate = 48_000.0
        let centres = EqualizerConfig.frequencies
        func between(_ gains: [Double]) -> (Double, Double) {
            let values = zip(centres, centres.dropFirst()).map { EqualizerCurve.response(gains, at: ($0 * $1).squareRoot(), sampleRate: rate) }
            return (values.min() ?? 0, values.max() ?? 0)
        }
        print("preset           off at bands  between bands   highest")
        var worst = 0.0
        let cases = EqualizerPreset.all.map { ($0.key, $0.gains) } + [
            ("all +6", [Double](repeating: 6, count: 10)), ("all +12", [Double](repeating: 12, count: 10)),
            ("1k +6 alone", [0, 0, 0, 0, 0, 6, 0, 0, 0, 0]), ("zigzag ±12", (0..<10).map { $0 % 2 == 0 ? 12 : -12 }),
        ]
        for (name, sliders) in cases {
            let gains = EqualizerCurve.filterGains(for: sliders, sampleRate: rate)
            let off = zip(sliders, centres).map { abs($0 - EqualizerCurve.response(gains, at: $1, sampleRate: rate)) }.max() ?? 0
            if !name.hasPrefix("zigzag") { worst = max(worst, off) }
            let (low, high) = between(gains)
            print(String(format: "%@ %6.2f dB    %5.1f..%5.1f dB   %+.1f dB", name.padding(toLength: 16, withPad: " ", startingAt: 0),
                         off, low, high, EqualizerCurve.highest(gains, sampleRate: rate)))
        }
        print("\(worst < 0.05 ? "ok  " : "DIFF") the curve meets every slider of the presets within \(String(format: "%.3f", worst)) dB")
        let start = Date()
        for _ in 0..<20 { _ = EqualizerCurve.highest(EqualizerCurve.filterGains(for: EqualizerPreset.loudness.gains, sampleRate: rate), sampleRate: rate) }
        print(String(format: "working out a curve: %.1f ms", Date().timeIntervalSince(start) / 20 * 1000))

        // Through the filters, as a tap runs them.
        let state = EqualizerState()
        /// The limiter's gain at each sample of the last run.
        var gains: [Double] = []
        /// The limiter's largest change from one sample to the next, in dB: a step there is a click.
        func fastest() -> Double {
            (1..<gains.count).map { abs(20 * log10(gains[$0] / gains[$0 - 1])) }.max() ?? 0
        }
        func run(_ sliders: [Double], _ input: (Int) -> (Float, Float), frames total: Int, change: (Int, [Double])? = nil, preamp: Double = 0) -> [Float] {
            func push(_ sliders: [Double]) {
                state.set(on: true, gains: EqualizerCurve.filterGains(for: sliders, sampleRate: rate), preamp: preamp)
            }
            push(sliders)
            let filters = EqualizerFilters(sampleRate: rate)
            gains = []
            var out: [Float] = []
            out.reserveCapacity(total)
            var frame = 0
            while frame < total {
                if let change, frame >= change.0, frame < change.0 + 512 { push(change.1) }
                filters.update(state.load())
                for i in frame..<min(total, frame + 512) {
                    var (l, r) = input(i)
                    filters.process(&l, &r)
                    out.append(l)
                    gains.append(filters.limiter.gain)
                }
                frame += 512
            }
            return out
        }
        func sine(_ frequency: Double, _ amplitude: Double) -> (Int) -> (Float, Float) {
            { i in let v = Float(amplitude * sin(2 * .pi * frequency * Double(i) / rate)); return (v, v) }
        }
        func rms(_ samples: ArraySlice<Float>) -> Double {
            (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
        }
        // Each band is its slider, plus the preamp, whatever it is; the preamp alone moves everything by itself.
        for (preset, preamp) in [(EqualizerPreset.loudness, 0.0), (EqualizerPreset.all[10], -4.5), (EqualizerPreset.all[0], -6.0)] {
            var off = 0.0
            for (band, centre) in centres.enumerated() {
                let out = run(preset.gains, sine(centre, 0.1), frames: 48_000, preamp: preamp)
                let measured = 20 * log10(rms(out[24_000...]) / (0.1 / 2.0.squareRoot()))
                off = max(off, abs(measured - (preset.gains[band] + preamp)))
            }
            print("\(off < 0.1 ? "ok  " : "DIFF") \(preset.key), preamp \(String(format: "%+.1f", preamp)) dB, through the filters: each band within \(String(format: "%.3f", off)) dB of its slider plus the preamp")
        }
        // Full scale in, everything boosted: nothing over the ceiling.
        var loudest: Float = 0
        for centre in centres {
            let out = run([Double](repeating: 12, count: 10), sine(centre, 1), frames: 24_000)
            // After the 20 ms fade in, which still mixes in the sound as it came.
            loudest = max(loudest, out[4800...].map(abs).max() ?? 0)
        }
        let chord = run([Double](repeating: 12, count: 10), { i in
            let v = Float(centres.reduce(0) { $0 + sin(2 * .pi * $1 * Double(i) / rate) } / 3)
            return (v, v)
        }, frames: 24_000)
        let chordPeak = chord[4800...].map(abs).max() ?? 0
        let chordGain = (gains.min() ?? 1, fastest())
        print("\(max(loudest, chordPeak) <= 0.98 ? "ok  " : "DIFF") all +12 at full scale: loudest \(String(format: "%.3f", loudest)) for tones, \(String(format: "%.3f", chordPeak)) for a chord of all ten, three times over full scale (ceiling 0.98)")
        // Down 18 dB on one sample, as a clipper or the limiter before did, is a click; ramped over
        // the 1.5 ms look-ahead it's well under a dB a sample.
        print("\(chordGain.1 < 1 ? "ok  " : "DIFF") the limiter on that chord: turns down \(String(format: "%.1f", -20 * log10(chordGain.0))) dB, never more than \(String(format: "%.2f", chordGain.1)) dB from one sample to the next")
        // A preset picked while a 64 Hz tone plays: the change glides, so the
        // wave never jumps much more than a clean one does.
        let out = run(EqualizerPreset.all[0].gains, sine(62.5, 0.2), frames: 48_000, change: (24_000, EqualizerPreset.all[1].gains))
        let jumps = (1..<(out.count - 1)).map { abs(Double(out[$0 + 1]) - 2 * Double(out[$0]) + Double(out[$0 - 1])) }
        let clean = jumps[12_000..<20_000].max() ?? 1, change = jumps[24_000..<30_000].max() ?? 0
        // A click is hundreds of times a clean tone's step; switched at once, this one was 1,700.
        print("\(change < clean * 10 ? "ok  " : "DIFF") Flat to Bass Boost mid-tone: the largest step in the wave is \(String(format: "%.1f", change / clean))x a clean tone's")

        // Simple's handles: each lands where it's set, from flat and on top of a
        // preset, and moves only its own region much.
        var landed = 0.0
        let rock = EqualizerPreset.all.first { $0.key == "Rock" }?.gains ?? []
        for start in [[Double](repeating: 0, count: 10), rock] {
            for region in EqualizerRegion.allCases {
                for target in [-6.0, 3.5, 9] {
                    landed = max(landed, abs(region.level(region.setting(start, to: target)) - target))
                }
            }
        }
        print("\(landed < 0.1 ? "ok  " : "DIFF") Simple's handles land within \(String(format: "%.2f", landed)) dB of where they're set, from flat and from Rock")
        let bass = EqualizerRegion.bass.setting([Double](repeating: 0, count: 10), to: 6)
        print("     Bass to +6 from flat: \(bass.map { String(format: "%.1f", $0) }.joined(separator: " "))")
        let peak: [Double] = [0, 12, 0, 0, 0, 0, 0, 0, 0, 0]
        print("\(!EqualizerRegion.fit(peak) && EqualizerRegion.fit(bass) ? "ok  " : "DIFF") +12 at 64 Hz alone shows Bass at \(String(format: "%+.1f", EqualizerRegion.bass.level(peak))) dB, more detail than Simple shows; Bass to +6 is what it shows")
        print("     presets Simple can show: \(EqualizerPreset.all.filter { EqualizerRegion.fit($0.gains) }.map(\.key).joined(separator: ", "))")
        // ⌥-drag: the band where it's dragged, its neighbours on a bell, nothing past ±12.
        let linked = EqualizerCurve.linked([Double](repeating: 0, count: 10), band: 4, to: 6)
        let edge = EqualizerCurve.linked([Double](repeating: 10, count: 10), band: 4, to: 12)
        let falls = linked[4] == 6 && linked[3] == linked[5] && linked[3] > linked[2] && linked[2] > linked[1] && edge.allSatisfy { $0 <= 12 }
        print("\(falls ? "ok  " : "DIFF") ⌥-drag 500 Hz to +6: \(linked.map { String(format: "%.1f", $0) }.joined(separator: " "))")

        // Saved with five bands.
        print("saved with five bands, read now:")
        for old in [[5.0, 1, -1, 2, 5], [4, 3, 0, 1, -1], [3, 0, 0, 0, 0], [0, 0, 6, 0, 0], [-3, 2, 0, -2, 4]] {
            let json = Data(#"{"enabled": true, "gains": \#(old)}"#.utf8)
            let config = try? JSONDecoder().decode(EqualizerConfig.self, from: json)
            let gains = config?.gains.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }.joined(separator: " ") ?? "FAILED"
            print("  \(old.map { String(Int($0)) }.joined(separator: " ")) -> \(gains) (\(config?.presetName ?? "?"))")
        }
    }
}
#endif

#if TOOLKIT_DEV
extension MixerController {
    /// `--measure-headroom <folder>`: how far each equalizer curve lifts the
    /// peaks of real music, against the headroom the curve's highest point
    /// keeps; and how the limiter would work with less. Each track is scaled
    /// to peak at full scale first, as masters do, so its own level doesn't
    /// count. Nothing is written.
    static func measureHeadroom(_ folder: String) {
        let urls = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        let curves: [(String, [Double])] = EqualizerPreset.all.dropFirst().map { ($0.key, $0.gains) } + [
            ("+12 from 2k", [0, 0, 0, 0, 0, 1, 12, 12, 12, 12]), ("+12 to 125", [12, 12, 12, 0, 0, 0, 0, 0, 0, 0]),
            ("1k +6", [0, 0, 0, 0, 0, 6, 0, 0, 0, 0]), ("all +6", [Double](repeating: 6, count: 10)),
        ]
        /// For each curve: per track, the peak's lift in dB.
        var lifts: [String: [Double]] = [:]
        /// The limiters tried, each with the headroom kept, against the curve's highest point.
        let trials: [(String, Double, Bool)] = [("look-ahead, 1 dB more", 1, true), ("look-ahead", 0, true),
                                                ("at once (before)", 0, false), ("look-ahead, 3 dB less", -3, true)]
        /// Per curve and trial, per track: share of the time turned down over 0.1 dB, the most, and the largest change from one sample to the next, in dB.
        var work: [String: [[(Double, Double, Double)]]] = [:]
        var seconds = 0.0
        for url in urls {
            guard let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else {
                print("skipped \(url.lastPathComponent)")
                continue
            }
            let frames = Int(buffer.frameLength), rate = file.processingFormat.sampleRate
            let right = buffer.format.channelCount > 1 ? 1 : 0
            seconds += Double(frames) / rate
            var inputPeak: Float = 0
            for i in 0..<frames { inputPeak = max(inputPeak, abs(data[0][i]), abs(data[right][i])) }
            guard inputPeak > 0 else { continue }
            let scale = 1 / inputPeak
            var outLeft = [Float](repeating: 0, count: frames), outRight = [Float](repeating: 0, count: frames)
            for (name, sliders) in curves {
                let gains = EqualizerCurve.filterGains(for: sliders, sampleRate: rate)
                let highest = max(0, EqualizerCurve.highest(gains, sampleRate: rate))
                // The filters alone: no preamp, no limiter.
                let state = EqualizerState()
                state.set(on: true, gains: gains, preamp: 0)
                let filters = EqualizerFilters(sampleRate: rate)
                filters.update(state.load())
                var peak: Float = 0
                for i in 0..<frames {
                    var (l, r) = (Double(data[0][i] * scale), Double(data[right][i] * scale))
                    filters.equalize(&l, &r)
                    (outLeft[i], outRight[i]) = (Float(l), Float(r))
                    peak = max(peak, abs(outLeft[i]), abs(outRight[i]))
                }
                lifts[name, default: []].append(20 * log10(Double(peak)))
                var results: [(Double, Double, Double)] = []
                for (_, extra, lookahead) in trials {
                    let preamp = Float(pow(10, -max(0, highest + extra) / 20))
                    let limiter = PeakLimiter(sampleRate: rate)
                    var instant = 1.0
                    let recovery = 1 - exp(-1 / (rate * 0.05))
                    var previous = 1.0
                    var limited = 0, deepest = 1.0, fastest = 0.0
                    for i in 0..<frames {
                        var (l, r) = (outLeft[i] * preamp, outRight[i] * preamp)
                        let gain: Double
                        if lookahead {
                            limiter.process(&l, &r)
                            gain = limiter.gain
                        } else {
                            // The limiter before: down at once on the sample itself.
                            let level = Double(max(abs(l), abs(r))) * instant
                            if level > 0.98 { instant *= 0.98 / level } else { instant += (1 - instant) * recovery }
                            gain = instant
                        }
                        if gain < 0.989 { limited += 1 }
                        deepest = min(deepest, gain)
                        fastest = max(fastest, abs(20 * log10(gain / previous)))
                        previous = gain
                    }
                    results.append((Double(limited) / Double(frames) * 100, -20 * log10(deepest), fastest))
                }
                work[name, default: []].append(results)
            }
            print("measured \(url.lastPathComponent) (\(Int(Double(frames) / rate)) s, peak \(String(format: "%.1f", 20 * log10(Double(inputPeak)))) dBFS)")
        }
        print(String(format: "\n%d tracks, %.0f minutes. Each scaled to peak at full scale, as masters do.", lifts.values.first?.count ?? 0, seconds / 60))
        print("keeps: headroom from the curve's highest point. lift: how far the curve takes the peak over full scale (median, worst).")
        print("For each limiter: share of the time it turns down more than 0.1 dB, the most it turns down, and its largest change from one sample to the next (a step is a click).\n")
        print("curve            keeps  lift med worst |" + trials.map { " \($0.0.padding(toLength: 24, withPad: " ", startingAt: 0))" }.joined(separator: "|"))
        for (name, sliders) in curves {
            let highest = max(0, EqualizerCurve.highest(EqualizerCurve.filterGains(for: sliders, sampleRate: 44_100), sampleRate: 44_100))
            let sorted = (lifts[name] ?? []).sorted()
            guard !sorted.isEmpty else { continue }
            var line = String(format: "%@ %5.1f  %5.1f %5.1f |", name.padding(toLength: 16, withPad: " ", startingAt: 0), highest, sorted[sorted.count / 2], sorted.last ?? 0)
            for index in trials.indices {
                let runs = (work[name] ?? []).map { $0[index] }
                let time = runs.map(\.0).reduce(0, +) / Double(max(1, runs.count))
                line += String(format: " %6.2f%% %4.1fdB %5.3fdB |", time, runs.map(\.1).max() ?? 0, runs.map(\.2).max() ?? 0)
            }
            print(line)
        }
    }
}
#endif
