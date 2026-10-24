#if TOOLKIT_DEV
import AppKit
import AVFoundation
import CoreAudio
import Synchronization

/// `--test-mixer-engine <report>`: the mixer run for real on a quiet 440 Hz
/// tone played by a helper, a copy of this app under a bundle ID of its own.
/// What the mixer plays is recorded and checked for clicks while the helper
/// starts, pauses, has its volume changed and the equalizer turned on and
/// off; then whether the output and the Mac are let go once it stops. Runs
/// beside the installed app, leaving its taps and the volume keys alone.
/// Run the app bundle with `open -n`, so the taps have the app's permission.
enum MixerEngineTest {
    static let helperID = "dev.jalves.macos-toolkit.tone"

    static func run(into path: String) {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); NSLog("Toolkit engine test: \(line)") }
        defer { try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        _ = NSApplication.shared

        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        guard let uid = output.readString(kAudioDevicePropertyDeviceUID) else { return say("no output") }
        say("output \(output.readString(kAudioObjectPropertyName) ?? "?"), permission \(AudioPermission.status)")
        guard let helper = makeHelper(), let tone = writeTone(seconds: 4) else { return say("no helper or tone") }
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        func running() -> String {
            "output running \(output.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 9)"
        }

        /// The helper plays `schedule` (seconds playing, paused, playing...);
        /// `steps` happen at their times, from the helper's start.
        func scenario(_ title: String, mode: String, schedule: [Double], steps: [(Double, String, (MixerController, MixerApp) -> Void)]) {
            say("\n== \(title) ==")
            let mixer = MixerController.testInstance(apps: [helperID])
            mixer.start()
            wait(0.5)
            guard let monitor = MonitorTap(deviceUID: uid) else { return say("monitor FAILED") }
            wait(0.3)
            say("  before: \(mixer.engineState); \(assertions()); \(running())")
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--play-tone", tone.path, mode, schedule.map { String($0) }.joined(separator: ",")]
            try? process.run()
            let start = Date()
            monitor.event("helper starts")
            let app = MixerApp(pid: process.processIdentifier, bundleID: helperID, name: "Tone", icon: nil, isPlaying: true)
            for (at, name, step) in steps {
                wait(at - Date().timeIntervalSince(start))
                step(mixer, app)
                monitor.event(name)
                say(String(format: "  %.1f s %@: %@", Date().timeIntervalSince(start), name, mixer.engineState))
            }
            let end = schedule.reduce(0, +) + 0.5
            wait(end - Date().timeIntervalSince(start))
            for line in monitor.report() { say("  " + line) }
            monitor.close()
            // Two seconds of silence, then the check, every two seconds at most.
            wait(5)
            say("  5 s after the tone: \(assertions()); \(running()); \(mixer.engineState)")
            process.terminate()
            mixer.stop()
            wait(1)
        }

        scenario("a player that stops between tones", mode: "player", schedule: [2, 4, 4], steps: [
            (1, "playing, through the master", { _, _ in }),
            (4, "paused", { _, _ in }),
            (7, "volume 50%", { mixer, app in mixer.setVolume(0.5, of: app) }),
            (8, "equalizer on", { mixer, _ in mixer.applyPreset(.loudness) }),
            (9, "equalizer off", { mixer, _ in mixer.setEqualizerEnabled(false) }),
            (9.5, "volume 100%", { mixer, app in mixer.setVolume(1, of: app) }),
        ])
        scenario("a player that keeps its output running between tones", mode: "engine", schedule: [2, 4, 3], steps: [
            (1, "playing, through the master", { _, _ in }),
            (4, "silent, output running", { _, _ in }),
            (7, "volume 50%", { mixer, app in mixer.setVolume(0.5, of: app) }),
            (8, "volume 100%", { mixer, app in mixer.setVolume(1, of: app) }),
        ])
        scenario("a volume changed before the app was ever quiet (moves at once)", mode: "player", schedule: [4], steps: [
            (1.5, "volume 50%", { mixer, app in mixer.setVolume(0.5, of: app) }),
            (3, "volume 100%", { mixer, app in mixer.setVolume(1, of: app) }),
        ])
        say("\nall stopped: \(assertions()); \(running())")
    }

    // MARK: - The helper

    /// A copy of this executable in an app of its own, so it has a bundle ID
    /// of its own, as another app would.
    private static func makeHelper() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-tone-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("Tone.app/Contents")
        let binary = contents.appendingPathComponent("MacOS/Toolkit")
        let plist: [String: Any] = ["CFBundleIdentifier": helperID, "CFBundleExecutable": "Toolkit", "CFBundleName": "Tone",
                                    "CFBundlePackageType": "APPL", "LSUIElement": true]
        do {
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: executable, to: binary)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        } catch { return nil }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", contents.deletingLastPathComponent().path]
        sign.standardError = FileHandle.nullDevice
        try? sign.run()
        sign.waitUntilExit()
        return binary
    }

    /// `--play-tone <file> <player|engine> <seconds,...>`, in the helper: plays
    /// and pauses in turn. A player stops its output while paused, as most do;
    /// an engine keeps it running in silence.
    static func playTone(_ arguments: [String]) {
        guard arguments.count >= 3 else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        let url = URL(fileURLWithPath: arguments[0])
        let schedule = arguments[2].split(separator: ",").compactMap { Double($0) }
        if arguments[1] == "engine" {
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            guard let file = try? AVAudioFile(forReading: url) else { return }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            try? engine.start()
            node.play()
            for (index, seconds) in schedule.enumerated() {
                if index % 2 == 0 {
                    node.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(seconds * file.processingFormat.sampleRate), at: nil)
                }
                wait(seconds)
            }
            wait(0.3)
            engine.stop()
        } else {
            for (index, seconds) in schedule.enumerated() {
                // A file as long as the tone, so it ends where it should, at a zero crossing.
                guard index % 2 == 0 else {
                    wait(seconds)
                    continue
                }
                guard let file = writeTone(seconds: seconds), let player = try? AVAudioPlayer(contentsOf: file) else { return }
                player.play()
                wait(seconds + 0.05)
                player.stop()
            }
        }
    }

    // MARK: - Helpers

    private static func wait(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The summary of the sleep assertions, and those audio holds.
    static func assertions() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let audio = text.split(separator: "\n").filter { $0.contains("com.apple.audio") }.count
        return audio == 0 ? "no audio sleep assertion" : "\(audio) audio sleep assertion(s)"
    }

    /// A 440 Hz tone at -40 dBFS, starting and ending at a zero crossing.
    private static func writeTone(seconds: Double) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-tone-\(Int(seconds)).wav")
        let rate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let value = Float(MonitorTap.amplitude * sin(2 * Double.pi * 440 * Double(i) / rate))
            channels[0][i] = value
            channels[1][i] = value
        }
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings), (try? file.write(from: buffer)) != nil else { return nil }
        return url
    }
}

/// Records what this process plays, as it goes to the output: a tap on our
/// own process that only listens, keeping the left channel.
private final class MonitorTap {
    static let amplitude = 0.01

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let capacity = 48_000 * 30
    private let samples: UnsafeMutablePointer<Float>
    private final class Count: Sendable { let value = Atomic<Int>(0) }
    private let count = Count()
    private var events: [(String, Int)] = []
    private var rate = 48_000.0
    /// Samples go where their time puts them, from here: the tap's device
    /// stops in silence, and packed together they'd lose the gaps.
    private let started = mach_absolute_time()
    private static let ticks: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init?(deviceUID: String) {
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        guard let own = AudioProcesses.processObject(of: getpid()) else { return nil }
        let description = CATapDescription(stereoMixdownOfProcesses: [own])
        description.name = AppTap.tapName
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: AppTap.tapName,
            kAudioAggregateDeviceUIDKey: AppTap.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { close(); return nil }
        if let format = tapID.read(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) { rate = format.mSampleRate }
        let (store, count, capacity, started, rate) = (samples, count, capacity, started, rate)
        let block: AudioDeviceIOBlock = { _, inputList, inputTime, outputList, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
            for output in UnsafeMutableAudioBufferListPointer(outputList) {
                if let out = output.mData { memset(out, 0, Int(output.mDataByteSize)) }
            }
            guard let last = inputs.last, let data = last.mData?.assumingMemoryBound(to: Float.self) else { return }
            let host = inputTime.pointee.mHostTime
            guard host > started else { return }
            var at = Int((Double(host - started) * Self.ticks * rate).rounded())
            for frame in 0..<Int(last.mDataByteSize) / 8 where at < capacity {
                store[at] = data[frame * 2]
                at += 1
            }
            if at > count.value.load(ordering: .relaxed) { count.value.store(at, ordering: .releasing) }
        }
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block) == noErr,
              AudioDeviceStart(aggregateID, procID) == noErr else { close(); return nil }
    }

    deinit {
        close()
        samples.deallocate()
    }

    func close() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != .unknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = .unknown }
        if tapID != .unknown { AudioHardwareDestroyProcessTap(tapID); tapID = .unknown }
    }

    func event(_ name: String) { events.append((name, Int((Double(mach_absolute_time() - started) * Self.ticks * rate).rounded()))) }

    /// Each stretch of tone with its length and loudness (1 is the tone at
    /// 100%, 2 a moment played twice); every jump a clean tone can't make,
    /// more than 30 times what it allows (a tone's own start and end come to
    /// about 15); and the level in 10 ms steps around each event.
    func report() -> [String] {
        let total = count.value.load(ordering: .acquiring)
        let omega = 2 * Double.pi * 440 / rate
        let allowed = Self.amplitude * omega * omega
        let block = Int(rate / 100)
        func level(_ from: Int) -> Double {
            var sum = 0.0
            for j in from..<min(total, from + block) { sum += Double(samples[j]) * Double(samples[j]) }
            return (sum / Double(block)).squareRoot() / (Self.amplitude / 2.0.squareRoot())
        }
        var lines: [String] = []
        var runStart: Int?, loudest = 0.0
        var i = 0
        while i + block <= total {
            let value = level(i)
            if value > 0.1 {
                if runStart == nil { (runStart, loudest) = (i, 0) }
                loudest = max(loudest, value)
            } else if let from = runStart {
                lines.append(String(format: "tone at %.2f s for %.2f s, loudest %.2f", Double(from) / rate, Double(i - from) / rate, loudest))
                runStart = nil
            }
            i += block
        }
        if let from = runStart { lines.append(String(format: "tone at %.2f s, still on at the end, loudest %.2f", Double(from) / rate, loudest)) }
        var jumps: [String] = []
        for k in 1..<max(1, total - 1) {
            let jump = abs(Double(samples[k + 1]) - 2 * Double(samples[k]) + Double(samples[k - 1]))
            if jump > allowed * 30 { jumps.append(String(format: "%.3f s (%.0fx)", Double(k) / rate, jump / allowed)) }
        }
        lines.append("jumps over 30x: \(jumps.isEmpty ? "none" : "\(jumps.count): " + jumps.prefix(8).joined(separator: ", "))")
        for (name, at) in events where at > 0 {
            var levels: [String] = []
            var from = max(0, at - block * 5)
            while from + block <= min(total, at + block * 25) {
                levels.append(String(format: "%.2f", level(from)))
                from += block
            }
            lines.append("\(name), level per 10 ms from -50 ms: \(levels.joined(separator: " "))")
        }
        return lines
    }
}
#endif
