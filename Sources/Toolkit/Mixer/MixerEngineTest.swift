#if TOOLKIT_DEV
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import os
import ScreenCaptureKit
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

    // MARK: - The driver

    /// `--test-driver <report>`: the audio driver, end to end, with it installed.
    /// It links, its device shows, and it becomes the default output for a
    /// moment; a helper plays a tone to it, and this plays what comes through
    /// on the real output. Then what that costs, whether anything records (no
    /// privacy dot), a microphone start with it all in place, and that the
    /// device goes with the link. The default output is put back at the end;
    /// if this crashes, the driver hides its device and macOS moves it back.
    static func runDriver(into path: String) {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); Log.mixer.notice("driver test: \(line, privacy: .public)") }
        defer { try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        _ = NSApplication.shared
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        func perSecond(_ seconds: Double) -> String {
            let start = cpu()
            wait(seconds)
            return String(format: "%.1f ms a second", (cpu() - start) / seconds)
        }
        func hosts() -> [String] {
            let ps = Process(), pipe = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-Ao", "pid,user,pcpu,rss,command"]
            ps.standardOutput = pipe
            try? ps.run()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return text.split(separator: "\n").filter { $0.contains("coreaudiod") || $0.contains("Core Audio Driver") }.map { String($0.prefix(130)) }
        }

        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        let system = AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self) ?? .unknown
        let rate = output.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        say("real output \(output.readString(kAudioObjectPropertyName) ?? "none"), \(rate) Hz, buffer \(output.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0)")
        guard let plugIn = DriverLink.plugIn else { return say("the driver isn't loaded") }
        say("plug-in object \(plugIn)")
        for line in hosts() { say("  \(line)") }

        let start = Date()
        let link: DriverLink
        do { link = try DriverLink() } catch { return say("link FAILED: \(error)") }
        say(String(format: "linked in %.0f ms", Date().timeIntervalSince(start) * 1000))
        var found = DriverLink.device
        while found == nil, Date().timeIntervalSince(start) < 5 {
            wait(0.02)
            found = DriverLink.device
        }
        guard let device = found else {
            link.close()
            return say("the device never showed")
        }
        say(String(format: "device %d shown in %.0f ms: %@, alive %d", device, Date().timeIntervalSince(start) * 1000,
                   device.readString(kAudioObjectPropertyName) ?? "?", device.read(kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) ?? 9))
        device.write(kAudioDevicePropertyNominalSampleRate, rate)
        wait(0.3)
        say("device's rate \(device.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0), buffer \(device.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0)")

        // The real output runs only while something plays to the device.
        let running = AudioListener(device, kAudioDevicePropertyDeviceIsRunningSomewhere) {
            let now = device.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 0
            say("  device running: \(now)")
            if now != 0 { link.start(on: output) } else { link.stop() }
        }
        guard let helper = makeHelper(), let tone = writeTone(seconds: 8) else { return say("no helper or tone") }
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        func flags() -> String {
            let me = AudioProcesses.clients().first { $0.pid == getpid() }
            return "real output running \(output.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 9), this process recording \(me?.isRecording.description ?? "no audio object")"
        }

        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, device)
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, device)
        wait(0.5)
        let isDefault = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) == device
        say("the default output now: \(isDefault); \(flags())")

        say("\n== silence ==")
        say("  CPU \(perSecond(3)); \(flags())")

        say("\n== a tone from a helper, through the driver ==")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--play-tone", tone.path, "player", "8"]
        try? process.run()
        wait(1)
        say("  1 s: \(link.state), peak \(link.recentPeak); \(flags())")
        say("  CPU while playing \(perSecond(4))")
        say("  5 s: \(link.state), peak \(link.recentPeak); \(flags())")
        // Its own volume: halved in the mix, and its level still as it plays.
        let full = link.recentPeak
        link.setGains([process.processIdentifier: 0.5])
        wait(0.5)
        let peaks = link.takePeaks()
        say(String(format: "  at half: peak %.4f (%.4f at full), its level %.4f", link.recentPeak, full, peaks[process.processIdentifier] ?? -1))
        link.setGains([process.processIdentifier: 0])
        wait(0.5)
        say(String(format: "  muted: peak %.4f, its level %.4f", link.recentPeak, link.takePeaks()[process.processIdentifier] ?? -1))
        link.setGains([:])
        wait(0.2)
        say(String(format: "  back: peak %.4f", link.recentPeak))
        let scope = kAudioObjectPropertyScopeOutput
        device.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, Float32(0.5))
        wait(0.1)
        say("  the device's volume, set to 0.5, reads \(device.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, as: Float32.self) ?? -1); latency \(device.read(kAudioDevicePropertyLatency, scope: scope, as: UInt32.self) ?? 0) frames")
        for line in hosts() { say("  \(line)") }
        process.terminate()
        wait(2)
        say("  after it: \(link.state); \(flags())")
        say("  CPU in silence again \(perSecond(3))")

        say("\n== the microphone, with the driver in place ==")
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-mic-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: report) }
        let mic = Process()
        mic.executableURL = helper
        mic.arguments = ["--open-mic", report.path, "2"]
        try? mic.run()
        let micStart = Date()
        while mic.isRunning, Date().timeIntervalSince(micStart) < 20 { wait(0.1) }
        let text = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") { say("  helper: \(line)") }
        if mic.isRunning {
            say("  helper still running after 20 s")
            mic.terminate()
        }

        say("\n== and back ==")
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, output)
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, system)
        wait(0.3)
        _ = running
        link.close()
        let closed = Date()
        while DriverLink.device != nil, Date().timeIntervalSince(closed) < 5 { wait(0.05) }
        say(String(format: "device %@ %.1f s after closing; the default output is %@", DriverLink.device == nil ? "gone" : "still there", Date().timeIntervalSince(closed),
                   AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)?.readString(kAudioObjectPropertyName) ?? "none"))
    }

    /// `--test-driver-eq <report>`: the same equalizer through taps and through
    /// the driver, measured. A helper plays a tone at each band; a tap on this
    /// process records what it sends to the real output, in each way, flat and
    /// with a preset. Both should lift each band by what the sliders say.
    static func runDriverEqualizer(into path: String) {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); Log.mixer.notice("eq test: \(line, privacy: .public)") }
        defer { try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        _ = NSApplication.shared
        let frequencies: [Double] = [64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let stepSeconds = 0.5
        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        let system = AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self) ?? .unknown
        guard let uid = output.readString(kAudioDevicePropertyDeviceUID), let helper = makeHelper(),
              let steps = writeSteps(frequencies, seconds: stepSeconds) else { return say("no output, helper or tones") }
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let rate = output.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        say("real output \(output.readString(kAudioObjectPropertyName) ?? "?"), \(rate) Hz; playing now: \(AudioProcesses.clients().filter(\.isPlaying).compactMap(\.bundleID))")

        func playAndMeasure(_ prepare: (pid_t) -> Void) -> [Double]? {
            guard let monitor = MonitorTap(deviceUID: uid) else { return nil }
            wait(0.3)
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--play-file", steps.path]
            try? process.run()
            prepare(process.processIdentifier)
            // To its end: it took a varying while to start, and cut off the last tone.
            let began = Date()
            while process.isRunning, Date().timeIntervalSince(began) < stepSeconds * Double(frequencies.count) + 8 { wait(0.05) }
            process.terminate()
            wait(0.2)
            let levels = frequencies.map { monitor.level(atFrequency: $0) }
            monitor.close()
            wait(0.5)
            return levels
        }

        // Taps, as the mixer makes them.
        let mixer = MixerController.testInstance(apps: [helperID])
        mixer.start()
        wait(0.5)
        guard let tapsFlat = playAndMeasure({ _ in }) else { return say("no monitor (taps)") }
        mixer.applyPreset(.loudness)
        wait(0.3)
        guard let tapsPreset = playAndMeasure({ _ in }) else { return say("no monitor (taps)") }
        let chosen = mixer.equalizer
        mixer.stop()
        wait(1)

        // The driver, with that equalizer, as the mixer sets it.
        let state = EqualizerState()
        state.set(on: false, gains: EqualizerCurve.filterGains(for: chosen.gains, sampleRate: rate), preamp: chosen.preamp)
        let link: DriverLink
        do { link = try DriverLink(equalizer: state) } catch { return say("link FAILED: \(error)") }
        defer { link.close() }
        var found = DriverLink.device
        let start = Date()
        while found == nil, Date().timeIntervalSince(start) < 5 {
            wait(0.02)
            found = DriverLink.device
        }
        guard let device = found else { return say("the device never showed") }
        device.write(kAudioDevicePropertyNominalSampleRate, rate)
        wait(0.3)
        let running = AudioListener(device, kAudioDevicePropertyDeviceIsRunningSomewhere) {
            let now = device.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 0
            if now != 0 { link.start(on: output) } else { link.stop() }
        }
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, device)
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, device)
        defer {
            AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, output)
            AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, system)
        }
        wait(0.5)
        // Everything but the tones silenced, so the measure is of them alone.
        let others = { (helper: pid_t) in
            var gains: [pid_t: Float] = [:]
            for client in AudioProcesses.clients() where client.pid != helper { gains[client.pid] = 0 }
            link.setGains(gains)
        }
        guard let driverFlat = playAndMeasure(others) else { return say("no monitor (driver)") }
        say("driver, flat: \(link.state)")
        state.set(on: true, gains: EqualizerCurve.filterGains(for: chosen.gains, sampleRate: rate), preamp: chosen.preamp)
        wait(0.3)
        guard let driverPreset = playAndMeasure(others) else { return say("no monitor (driver)") }
        say("driver, preset: \(link.state)")
        _ = running

        say("\nloudness preset, preamp \(chosen.preamp) dB; lift in dB, preset against flat in the same path")
        say("   Hz   slider    taps  driver   apart   flat: taps against driver")
        func db(_ a: Double, _ b: Double) -> Double { b > 0 && a > 0 ? 20 * log10(a / b) : .nan }
        for (index, frequency) in frequencies.enumerated() {
            let band = EqualizerConfig.frequencies.firstIndex { abs(log2($0 / frequency)) < 0.2 }
            let slider = band.map { chosen.gains[$0] } ?? .nan
            let taps = db(tapsPreset[index], tapsFlat[index]), driver = db(driverPreset[index], driverFlat[index])
            say(String(format: "%6.0f  %6.2f  %6.2f  %6.2f  %6.2f   %6.2f", frequency, slider + chosen.preamp, taps, driver, abs(taps - driver), db(tapsFlat[index], driverFlat[index])))
        }
    }

    /// `--test-driver-sounds <report>`: short sounds through the driver, each
    /// from silence with the real output stopped: how much of each is heard. And
    /// what a screen recording's system audio gets, leaving this process out as
    /// recordings do and not, since on the driver this process plays everything.
    static func runDriverSounds(into path: String) {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); Log.mixer.notice("sounds test: \(line, privacy: .public)") }
        defer { try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        _ = NSApplication.shared
        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        let system = AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self) ?? .unknown
        let rate = output.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        let link: DriverLink
        do { link = try DriverLink() } catch { return say("link FAILED: \(error)") }
        defer { link.close() }
        var found = DriverLink.device
        let start = Date()
        while found == nil, Date().timeIntervalSince(start) < 5 {
            wait(0.02)
            found = DriverLink.device
        }
        guard let device = found, let helper = makeHelper() else { return say("no device or helper") }
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        device.write(kAudioDevicePropertyNominalSampleRate, rate)
        wait(0.3)
        let running = AudioListener(device, kAudioDevicePropertyDeviceIsRunningSomewhere) {
            let now = device.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 0
            if now != 0 { link.start(on: output) } else { link.stop() }
        }
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, device)
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, device)
        defer {
            AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, output)
            AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, system)
        }
        wait(0.5)
        say("real output \(output.readString(kAudioObjectPropertyName) ?? "?"); other apps playing: \(AudioProcesses.clients().filter(\.isPlaying).compactMap(\.bundleID))")

        for seconds in [0.1, 0.1, 0.25, 1.0] {
            wait(1.5)
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--play-tone", "-", "player", String(seconds)]
            try? process.run()
            let began = Date()
            while process.isRunning, Date().timeIntervalSince(began) < 8 { wait(0.05) }
            wait(1)
            say(String(format: "a sound of %.2f s (%d frames): %@", seconds, Int(seconds * rate), link.state))
        }

        for excluded in [true, false] {
            let peak = captureSystemAudio(excludingThisProcess: excluded) {
                let process = Process()
                process.executableURL = helper
                process.arguments = ["--play-tone", "-", "player", "3"]
                try? process.run()
            }
            say(String(format: "a recording's system audio, %@ this process: loudest %.5f (the tone is 0.01)", excluded ? "leaving out" : "with", peak))
            wait(1)
        }
        _ = running
    }

    /// The loudest sample a stream of the display's audio gets while `play` plays,
    /// configured as `Recorder` does, or -1 if it can't run.
    private static func captureSystemAudio(excludingThisProcess excluded: Bool, while play: () -> Void) -> Float {
        final class Peak: NSObject, SCStreamOutput, @unchecked Sendable {
            let value = Mutex<Float>(0)
            func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
                guard type == .audio else { return }
                try? sample.withAudioBufferList { list, _ in
                    for buffer in list {
                        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let loudest = (0..<count).reduce(Float(0)) { max($0, abs(data[$1])) }
                        value.withLock { $0 = max($0, loudest) }
                    }
                }
            }
        }
        let peak = Peak()
        let ready = Mutex<SCStream?>(nil)
        let failed = Mutex(false)
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = excluded
                config.width = 16
                config.height = 16
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
                try stream.addStreamOutput(peak, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
                try await stream.startCapture()
                ready.withLock { $0 = stream }
            } catch {
                Log.mixer.error("sounds test: capture: \(String(describing: error), privacy: .public)")
                failed.withLock { $0 = true }
            }
        }
        let began = Date()
        while ready.withLock({ $0 == nil }), !failed.withLock({ $0 }), Date().timeIntervalSince(began) < 5 { wait(0.05) }
        guard let stream = ready.withLock({ $0 }) else { return -1 }
        play()
        wait(5)
        Task { try? await stream.stopCapture() }
        wait(0.5)
        return peak.value.withLock { $0 }
    }

    /// `--test-driver-long <report> <seconds>`: a quiet tone through the driver
    /// for a long while: what stays queued, how the two clocks settle, any gaps.
    static func runDriverLong(into path: String, seconds: Double) {
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            Log.mixer.notice("driver test: \(line, privacy: .public)")
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path + ".partial", atomically: true, encoding: .utf8)
        }
        defer {
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: path + ".partial")
        }
        _ = NSApplication.shared
        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        let system = AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self) ?? .unknown
        let rate = output.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        let link: DriverLink
        do { link = try DriverLink() } catch { return say("link FAILED: \(error)") }
        defer { link.close() }
        var found = DriverLink.device
        let start = Date()
        while found == nil, Date().timeIntervalSince(start) < 5 {
            wait(0.02)
            found = DriverLink.device
        }
        guard let device = found else { return say("the device never showed") }
        device.write(kAudioDevicePropertyNominalSampleRate, rate)
        wait(0.3)
        let running = AudioListener(device, kAudioDevicePropertyDeviceIsRunningSomewhere) {
            let now = device.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 0
            if now != 0 { link.start(on: output) } else { link.stop() }
        }
        guard let helper = makeHelper() else { return say("no helper") }
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, device)
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, device)
        defer {
            AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, output)
            AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, system)
        }
        wait(0.5)
        say("real output \(output.readString(kAudioObjectPropertyName) ?? "none"), \(rate) Hz, buffers \(output.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0) and \(device.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0)")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--play-tone", "-", "player", String(seconds + 2)]
        try? process.run()
        defer { process.terminate() }
        let began = Date()
        var joined = 0
        while Date().timeIntervalSince(began) < seconds {
            wait(10)
            say(String(format: "%3.0f s: %@, peak %.3f", Date().timeIntervalSince(began), link.state, link.recentPeak))
            // Every 30 s another app plays a moment, as a notification does:
            // joining the device mustn't disturb what's already playing.
            joined += 1
            if joined % 3 == 0 {
                let other = Process()
                other.executableURL = helper
                other.arguments = ["--play-tone", "-", "player", "2"]
                try? other.run()
            }
        }
        _ = running
    }

    /// `--test-driver-crash <report>`: a copy of this app, linked and the default
    /// output while a helper plays, is killed, and then one is frozen: how soon
    /// the device goes, and whether sound moves back to the real output.
    static func runDriverCrash(into path: String) {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); Log.mixer.notice("driver test: \(line, privacy: .public)") }
        defer { try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        _ = NSApplication.shared
        guard let executable = Bundle.main.executableURL, let helper = makeHelper() else { return say("no executable or helper") }
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        let system = AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self) ?? .unknown
        func name(_ device: AudioObjectID?) -> String { device?.readString(kAudioObjectPropertyName) ?? "none" }
        func currentDefault() -> AudioObjectID? { AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) }
        say("real output \(name(output))")

        func scenario(_ title: String, signal: Int32, limit: Double) {
            say("\n== \(title) ==")
            let holder = Process()
            holder.executableURL = executable
            holder.arguments = ["--driver-hold"]
            try? holder.run()
            let started = Date()
            var device = DriverLink.device
            while (device == nil || currentDefault() != device), Date().timeIntervalSince(started) < 8 {
                wait(0.05)
                device = DriverLink.device
            }
            guard let device, currentDefault() == device else {
                holder.terminate()
                return say("  never became the default output")
            }
            let tone = Process()
            tone.executableURL = helper
            tone.arguments = ["--play-tone", "-", "player", String(limit + 6)]
            try? tone.run()
            wait(3)
            say("  before: default \(name(currentDefault())), device running \(device.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 9), real output running \(output.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 9)")
            kill(holder.processIdentifier, signal)
            let hit = Date()
            while DriverLink.device != nil, Date().timeIntervalSince(hit) < limit { wait(0.02) }
            say(String(format: "  device %@ after %.2f s", DriverLink.device == nil ? "gone" : "STILL THERE", Date().timeIntervalSince(hit)))
            let moved = Date()
            while currentDefault() == device, Date().timeIntervalSince(moved) < 3 { wait(0.02) }
            say(String(format: "  default output %@ after %.2f s more", name(currentDefault()), Date().timeIntervalSince(moved)))
            wait(1.5)
            say("  a moment on: real output running \(output.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 9) (the tone still playing)")
            kill(holder.processIdentifier, SIGKILL)
            tone.terminate()
            AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, output)
            AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, system)
            wait(1.5)
        }
        scenario("the toolkit killed", signal: SIGKILL, limit: 5)
        scenario("the toolkit frozen", signal: SIGSTOP, limit: 20)
        say("\nafter: default \(name(currentDefault())), device \(DriverLink.device == nil ? "gone" : "there")")
    }

    /// `--driver-hold`, in the copy that test kills: linked and the default
    /// output, playing what comes through, until it's stopped.
    static func holdDriver() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? .unknown
        guard let link = try? DriverLink() else { return }
        var found = DriverLink.device
        let start = Date()
        while found == nil, Date().timeIntervalSince(start) < 5 {
            wait(0.02)
            found = DriverLink.device
        }
        guard let device = found else { return }
        device.write(kAudioDevicePropertyNominalSampleRate, output.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000)
        wait(0.2)
        let running = AudioListener(device, kAudioDevicePropertyDeviceIsRunningSomewhere) {
            let now = device.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 0
            if now != 0 { link.start(on: output) } else { link.stop() }
        }
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, device)
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, device)
        wait(120)
        _ = running
    }

    // MARK: - The microphone

    /// `--test-mixer-mic <report>`: the helper opens the microphone alone, as
    /// a call app's preview does, with and without the mixer. A process its
    /// taps cover can't start its input until a tap runs, and a tap made to
    /// start by itself waits for that process to play: on macOS 26 a meeting
    /// app's preview froze until the mixer was turned off. Where that happens,
    /// the waiting tap should go first, a running one follow, and a waiting one
    /// come back after. That path is forced here; this Mac may not need it.
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
        attempt("the microphone alone, the taps left as they are where inputs aren't held up", mixer: true)
        MixerController.forceInputsHeldUp = true
        defer { MixerController.forceInputsHeldUp = false }
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
    /// A tone at each frequency in turn, the same level for each.
    private static func writeSteps(_ frequencies: [Double], seconds: Double) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-steps-\(UUID().uuidString).caf")
        let rate = 48_000.0
        let perStep = Int(rate * seconds)
        // Silence first and last: whatever records this takes a moment to start,
        // and sound through a new tap's device is lost until it has.
        let lead = Int(rate * 1)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(perStep * frequencies.count + 2 * lead)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { channels[channel].initialize(repeating: 0, count: Int(buffer.frameLength)) }
        for (step, frequency) in frequencies.enumerated() {
            for i in 0..<perStep {
                // Faded at each end, so no step clicks into other frequencies.
                let fade = min(1, min(Double(i), Double(perStep - i)) / 480)
                let value = Float(0.03 * fade * sin(2 * Double.pi * frequency * Double(i) / rate))
                channels[0][lead + step * perStep + i] = value
                channels[1][lead + step * perStep + i] = value
            }
        }
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings), (try? file.write(from: buffer)) != nil else { return nil }
        return url
    }

    /// `--play-file <file>`, in the helper.
    static func playFile(_ path: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        player.play()
        wait(player.duration + 0.2)
    }

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

    /// How much of this frequency there is in all that's been recorded (Goertzel):
    /// comparable between recordings of the same sound, wherever in them it falls.
    func level(atFrequency frequency: Double) -> Double {
        let total = count.value.load(ordering: .acquiring)
        let coefficient = 2 * cos(2 * Double.pi * frequency / rate)
        var previous = 0.0, older = 0.0
        for index in 0..<total {
            let value = Double(samples[index]) + coefficient * previous - older
            older = previous
            previous = value
        }
        return sqrt(max(0, previous * previous + older * older - coefficient * previous * older))
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
