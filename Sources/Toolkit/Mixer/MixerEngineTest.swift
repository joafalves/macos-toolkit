#if TOOLKIT_DEV
import AppKit
import AVFoundation
import CoreAudio
import os
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
        func say(_ line: String) { lines.append(line); Log.mixer.notice("engine test: \(line, privacy: .public)") }
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

    // MARK: - The microphone

    /// `--test-mixer-mic <report>`: the helper opens the microphone alone, as
    /// a call app's preview does, with and without the mixer. A process its
    /// taps cover can't start its input until a tap runs, and a tap made to
    /// start by itself waits for that process to play: on macOS 26 a meeting
    /// app's preview froze until the mixer was turned off. The taps should
    /// run while the input does, and wait again after.
    static func runMic(into path: String) {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); Log.mixer.notice("mic test: \(line, privacy: .public)") }
        defer { try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        _ = NSApplication.shared

        let input = AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self) ?? .unknown
        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        say("input \(input.readString(kAudioObjectPropertyName) ?? "none"), output \(output.readString(kAudioObjectPropertyName) ?? "none"), permission \(AudioPermission.status)")
        guard let helper = makeHelper() else { return say("no helper") }
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        /// `stopMixerAt`: if the input hasn't started by then, the mixer is
        /// stopped, to see whether that lets it go.
        /// `playFirst`: the helper plays a moment of tone and waits before
        /// opening the microphone, so it has a tap of its own by then.
        func attempt(_ title: String, mixer useMixer: Bool, playFirst: Bool = false, stopMixerAt: Double = 8) {
            say("\n== \(title) ==")
            var mixer: MixerController?
            if useMixer {
                mixer = MixerController.testInstance(apps: [helperID])
                mixer?.start()
                wait(1)
                say("  before: \(mixer?.engineState ?? "")")
            }
            let report = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-mic-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: report) }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--open-mic", report.path, "2"] + (playFirst ? ["play-first"] : [])
            try? process.run()
            let start = Date()
            var state = ""
            var stopped = false
            var reported = false
            var startedAt: Double?
            let limit = playFirst ? 23.0 : 15.0
            while Date().timeIntervalSince(start) < limit {
                wait(0.1)
                let elapsed = Date().timeIntervalSince(start)
                let text = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
                let object = AudioProcesses.processObject(of: process.processIdentifier)
                let now = object.map { object in
                    ["running", "input", "output"].enumerated().map { index, name in
                        let selector = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput][index]
                        return "\(name) \(object.read(selector, as: UInt32.self) ?? 9)"
                    }.joined(separator: ", ")
                } ?? "no audio object"
                if now != state {
                    say(String(format: "  %.1f s: helper %@", elapsed, now))
                    state = now
                }
                if text.contains("buffers") || !process.isRunning { break }
                if let current = mixer, text.contains("started") {
                    startedAt = startedAt ?? elapsed
                    if !reported, let startedAt, elapsed - startedAt >= 1 {
                        say(String(format: "  %.1f s: input started a second ago, %@", elapsed, current.engineState))
                        reported = true
                    }
                }
                if let current = mixer, !stopped, elapsed >= stopMixerAt + (playFirst ? 8 : 0), !text.contains("started") {
                    say(String(format: "  %.1f s: input not started, mixer stopped (%@)", elapsed, current.engineState))
                    current.stop()
                    stopped = true
                }
            }
            // It may still be letting the microphone go.
            let exitBy = Date().addingTimeInterval(3)
            while process.isRunning, Date() < exitBy { wait(0.1) }
            let text = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") { say("  helper: \(line)") }
            if process.isRunning {
                say(String(format: "  helper still running after %.0f s", Date().timeIntervalSince(start)))
                process.terminate()
            }
            if let mixer, !stopped {
                wait(4)
                say("  4 s after: \(mixer.engineState)")
            }
            mixer?.stop()
            wait(1)
        }

        attempt("the microphone alone, no mixer", mixer: false)
        attempt("the microphone alone while the mixer's taps wait", mixer: true)
        attempt("the microphone after a moment of sound, with the app's own tap waiting", mixer: true, playFirst: true)
        attempt("the microphone alone, no mixer, again", mixer: false)

        // What this process spends with a tap running for an app's microphone, in silence, against waiting.
        say("\n== a tap running in silence ==")
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func perSecond(_ seconds: Double) -> Double {
            let start = cpu()
            wait(seconds)
            return (cpu() - start) / seconds * 1000
        }
        let mixer = MixerController.testInstance(apps: [helperID])
        mixer.start()
        wait(1)
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-mic-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: report) }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--open-mic", report.path, "9"]
        try? process.run()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !((try? String(contentsOf: report, encoding: .utf8)) ?? "").contains("started") { wait(0.1) }
        wait(1.5)
        let running = perSecond(5)
        say("  while the helper records: \(mixer.engineState)")
        process.waitUntilExit()
        wait(4)
        let waiting = perSecond(5)
        say("  after: \(mixer.engineState)")
        say(String(format: "  CPU: %.2f ms a second with the tap running, %.2f ms waiting", running, waiting))
        mixer.stop()
    }

    private final class Count: Sendable { let value = Atomic<Int>(0) }
    private static let micBuffers = Count()

    /// `--open-mic <report> <seconds>`, in the helper: the default input,
    /// and no output, through the unit call apps use, timing its start.
    static func openMic(_ arguments: [String]) {
        guard arguments.count >= 2, let seconds = Double(arguments[1]) else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        var lines: [String] = []
        if arguments.count > 2, arguments[2] == "play-first", let tone = writeTone(seconds: 1),
           let player = try? AVAudioPlayer(contentsOf: tone) {
            player.play()
            wait(1.05)
            player.stop()
            // The player keeps its output up for a few seconds, then the
            // mixer puts the tap back to waiting two seconds into a silence.
            wait(7)
        }
        func note(_ line: String) {
            lines.append(line)
            try? (lines.joined(separator: "\n") + "\n").write(toFile: arguments[0], atomically: true, encoding: .utf8)
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var made: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description), AudioComponentInstanceNew(component, &made) == noErr,
              let unit = made else { return note("no input unit") }
        defer { AudioComponentInstanceDispose(unit) }
        let size = UInt32(MemoryLayout<UInt32>.size)
        var on: UInt32 = 1, off: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, size)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, size)
        var device = AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self) ?? .unknown
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, size)
        var callback = AURenderCallbackStruct(inputProc: { _, _, _, _, _, _ in
            MixerEngineTest.micBuffers.value.add(1, ordering: .relaxed)
            return noErr
        }, inputProcRefCon: nil)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(unit) == noErr else { return note("input unit refused") }
        note("starting \(device.readString(kAudioObjectPropertyName) ?? "?")")
        let start = Date()
        let status = AudioOutputUnitStart(unit)
        note(String(format: "started in %.2f s, status %d", Date().timeIntervalSince(start), status))
        wait(seconds)
        note("buffers in \(Int(seconds)) s: \(micBuffers.value.load(ordering: .relaxed))")
        AudioOutputUnitStop(unit)
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
