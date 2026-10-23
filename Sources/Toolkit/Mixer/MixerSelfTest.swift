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
}
