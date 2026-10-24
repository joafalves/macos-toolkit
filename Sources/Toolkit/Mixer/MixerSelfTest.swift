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
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
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
                var name: CFString = "" as CFString
                _ = property(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, 0, &name)
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
                             worst < 1 ? "ok  " : "DIFF", name as String, range.mMinimum, range.mMaximum, worst,
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
                lines.append("microphone recording: saved \(saved), \(tracks.count) audio track(s), "
                    + "loudest \(String(format: "%.4f", tracks.first.map { loudest(in: asset, track: $0) } ?? 0)) (0 is silence: blocked)")
            } catch {
                lines.append("microphone recording: FAILED \(error.localizedDescription)")
            }
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The loudest sample in an audio track: a microphone that's blocked still
    /// gives a track, of silence.
    private static func loudest(in asset: AVAsset, track: AVAssetTrack) -> Float {
        guard let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
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
