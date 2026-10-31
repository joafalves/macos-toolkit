import CoreAudio
import DriverShared
import Foundation
import os
import Synchronization

/// The toolkit's end of the audio driver (`Driver/ToolkitAudio.c`): opens the
/// memory the driver shares, keeps its device alive with a heartbeat, and
/// plays what it writes there on a real output. Apps play to the driver's
/// device, and nothing here records, so macOS shows no privacy dot.
///
/// The two clocks are the same clock: the driver's follows the rate written
/// here, taken from the real output, and nudged to keep each frame at the time
/// macOS gave the app for it, plus the latency the device reports. So nothing is
/// resampled, the delay stays put, and a picture timed by that stays with its sound.
final class DriverLink {
    /// The driver's plug-in object, if it's installed and loaded.
    static var plugIn: AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateBundleIDToPlugIn,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bundleID = DRIVER_PLUGIN_BUNDLE_ID as CFString
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &bundleID) {
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &object)
        }
        return status == noErr && object != .unknown ? object : nil
    }

    /// The device apps play to, while the driver shows it.
    static var device: AudioObjectID? {
        AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, as: AudioObjectID.self)
            .first { $0.readString(kAudioDevicePropertyDeviceUID) == DRIVER_DEVICE_UID }
    }

    /// Why a link couldn't be made, in words for the log.
    enum Failure: Error, CustomStringConvertible {
        case notInstalled, refused, noMemory(Int32), wrongVersion

        var description: String {
            switch self {
            case .notInstalled: return "the driver isn't installed"
            case .refused: return "the driver refused this process"
            case .noMemory(let error): return "the shared memory didn't open: \(String(cString: strerror(error)))"
            case .wrongVersion: return "the driver is a different version"
            }
        }
    }

    /// What the audio thread keeps: plain values behind a pointer, so it
    /// never touches a reference count.
    struct Reader {
        var position: UInt64 = 0
        /// Playing, as opposed to waiting for enough to play without a gap.
        var playing = false
        /// Frames to spare between a write and the read that needs it: this
        /// long after each write, the output's cycle comes round. Grows when
        /// that wasn't enough.
        var slack = 0.0
        /// The latest write the driver made.
        var write = DriverSharedWrite()
        /// How many frames behind its time what's playing is, or if negative
        /// ahead of it, averaged over a second or so.
        var late = 0.0
        var correction = 0.0
        /// The real output's speed against the host's clock, from its time stamps.
        var deviceRate = 1.0
        // For the log, and the test.
        var sampleRate = 48000.0
        var appliedGain: Float = 1
        /// Ran out of sound, which is a gap only if more comes: the end of a
        /// sound looks the same until then.
        var ranOut = false
        /// The last cycle played had sound in it. Running out after silence loses
        /// nothing: macOS pauses for up to 165 ms as a client starts (measured),
        /// and what comes after that is the sound itself, not a burst to skip.
        var lastCycleHadSound = false
        /// Frames played since this output started, for what a gap in the first
        /// moments says: nothing, as apps are still moving to the device.
        var playedFrames = 0.0
        /// Frames with sound in them sent to the output, for the test.
        var soundFrames = 0
        var underruns = 0
        var skips = 0
        var lastLevel: Int64 = 0
        var cycleFrames: UInt32 = 0
        #if TOOLKIT_DEV
        /// For `--test-driver-sync`: when a loud sample after a while without
        /// one reached the output.
        var markerHost: UInt64 = 0
        var quietFrames = 100_000
        #endif
    }

    /// The least time to spare after a write: the driver's and the output's
    /// threads both wake a little late at times.
    private static let slackSeconds = 0.003
    /// The limiter's, in what the device tells apps.
    private static let lookAheadSeconds = 0.0015
    /// How much faster or slower per second off target: gone in about 10 s,
    /// at a rate no one can hear.
    private static let gain = 0.1
    /// Well inside what the driver accepts, and what a real clock could be off.
    private static let furthest = 0.0005
    /// Off by more than a few ms, as a sound's start can leave it: still inside what
    /// the driver accepts, and unheard, as nothing is resampled. 8 ms a second.
    private static let fastest = 0.008
    /// A write this long is a player's, timing a picture by it (`inOutputTime`).
    /// Being on time matters more than the very start of its sound.
    private static let longWrite = 0.02
    /// How late a sound's start may play, to not lose it while the output starts.
    /// Long enough for speakers; a Bluetooth output takes longer, and only the
    /// last of what came before it's up gets played.
    private static let mostToCatchUp = 0.3

    /// What the audio thread reads of the main volume; a class so the block can hold it.
    private final class MainGain: Sendable {
        let bits = Atomic<UInt32>(Float(1).bitPattern)
    }

    private let shared: UnsafeMutablePointer<DriverSharedHeader>
    private let mainGain = MainGain()
    private let equalizer: EqualizerState?
    /// The slot in the driver's table of each process with a volume of its own.
    private var slots: [pid_t: UInt32] = [:]
    private let reader = UnsafeMutablePointer<Reader>.allocate(capacity: 1)
    /// Interleaved frames for one cycle of the real output.
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * Int(DRIVER_CHANNELS))
    private var heartbeat: DispatchSourceTimer?
    /// App Nap holds timers back, and a late heartbeat would make the driver
    /// hide its device and macOS move all sound off it. Doesn't keep the Mac awake.
    private var activity: NSObjectProtocol?
    private var loggedGaps = (0, 0)
    /// Starts and stops the real output, and holds these.
    private let outputQueue = DispatchQueue(label: "dev.jalves.macos-toolkit.driver-output", qos: .userInitiated)
    private var wanted: AudioObjectID?
    private var output: AudioObjectID?
    private var ioProc: AudioDeviceIOProcID?
    private var stoppedWhilePlaying = false

    /// `equalizer`: applied, with its limiter, to everything played on the real output.
    init(equalizer: EqualizerState? = nil) throws {
        self.equalizer = equalizer
        guard let plugIn = Self.plugIn else { throw Failure.notInstalled }
        guard let name = plugIn.readString(DRIVER_LINK_SELECTOR) else { throw Failure.refused }
        // Open as soon as it's given: the driver takes the name away after.
        var error: Int32 = 0
        guard let memory = driver_shared_open(name, &error) else { throw Failure.noMemory(error) }
        shared = memory
        guard driver_shared_is_valid(shared) else {
            munmap(memory, driver_shared_size())
            throw Failure.wrongVersion
        }
        reader.initialize(to: Reader())
        reader.pointee.position = driver_shared_write_head(shared)
        beat()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [shared] in driver_shared_set_heartbeat(shared, mach_absolute_time()) }
        timer.resume()
        heartbeat = timer
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "The audio driver's heartbeat")
        Log.mixer.notice("driver: linked")
    }

    private func beat() {
        driver_shared_set_heartbeat(shared, mach_absolute_time())
    }

    /// Tells the driver it's over, which hides its device within a second. Waits
    /// for the real output to be let go. The memory stays mapped and the reader
    /// allocated: the audio thread may have only just left, and this happens at
    /// most a few times in a run.
    func close() {
        outputQueue.sync {
            wanted = nil
            stopOutput()
        }
        heartbeat?.cancel()
        heartbeat = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        driver_shared_set_closing(shared, true)
    }

    /// Plays what the driver writes on `device`, from now on, at the driver's
    /// sample rate, which the caller keeps the same as the device's. Off the
    /// main thread, like `stop`: a Bluetooth output can take a second to start.
    func start(on device: AudioObjectID) {
        outputQueue.async { [self] in
            wanted = device
            start(on: device, tries: 5)
        }
    }

    /// Nothing else would ask again, and meanwhile apps are playing to the
    /// device with nothing to hear them. For a moment only: then it's not coming.
    private func start(on device: AudioObjectID, tries: Int) {
        guard wanted == device, !startOutput(on: device), tries > 0 else { return }
        outputQueue.asyncAfter(deadline: .now() + 3) { [self] in start(on: device, tries: tries - 1) }
    }

    /// Lets go of the real output, so it and the Mac can sleep.
    func stop() {
        outputQueue.async { [self] in
            wanted = nil
            stopOutput()
        }
    }

    private func startOutput(on device: AudioObjectID) -> Bool {
        // Macs say the device is running again as each app joins: restarting
        // the output for that would be a gap in everything playing.
        if output == device, ioProc != nil { return true }
        stopOutput()
        guard let channels = Self.stereo(of: device) else {
            Log.mixer.error("driver: output \(device, privacy: .public) has no channels to play on")
            return false
        }
        let sampleRate = device.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        // From where it was read to, if the device had stopped by then: what's
        // been written since is the start of a sound, which came while this
        // output was starting up. Otherwise, from now: an output changed under
        // music shouldn't play on late by what the change took.
        let from = stoppedWhilePlaying ? driver_shared_write_head(shared) : reader.pointee.position
        reader.pointee = Reader()
        reader.pointee.position = from
        reader.pointee.slack = Self.slackSeconds * sampleRate
        reader.pointee.sampleRate = sampleRate
        // Not from full: the first buffer is already at the volume it should be.
        reader.pointee.appliedGain = gain
        let shared = shared, reader = reader, scratch = scratch, mainGain = mainGain, equalizer = equalizer
        let filters = EqualizerFilters(sampleRate: sampleRate)
        driver_shared_set_latency(shared, Self.latency(of: device, sampleRate: sampleRate))
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let framesPerTick = sampleRate * Double(timebase.numer) / (Double(timebase.denom) * 1e9)
        let clockGain = Self.gain, furthest = Self.furthest, fastest = Self.fastest
        let oneMillisecond = sampleRate / 1000
        let longWrite = UInt32(Self.longWrite * sampleRate)
        // What's held back behind the time macOS gave, and what makes it enough:
        // the last of what a cycle reads has to have been written as that cycle
        // wakes, a cycle and the output's safety offset before it's due. All of it
        // is in the latency the device reports, with the limiter's look-ahead.
        let safety = Double(device.read(kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, as: UInt32.self) ?? 0)
        let held = Double(device.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 512) + safety

        let block: AudioDeviceIOBlock = { _, _, _, outData, outTime in
            let list = UnsafeMutableAudioBufferListPointer(outData)
            // Whatever is left in them otherwise repeats, as a buzz, when there's
            // nothing to play.
            for buffer in list { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            guard list.count > channels.left.buffer, list.count > channels.right.buffer,
                  let leftData = list[channels.left.buffer].mData, let rightData = list[channels.right.buffer].mData else { return }
            let leftStride = Int(list[channels.left.buffer].mNumberChannels)
            let rightStride = Int(list[channels.right.buffer].mNumberChannels)
            // The output can change shape before anyone is told: a headset going
            // to one channel as its microphone opens.
            guard channels.left.offset < leftStride, channels.right.offset < rightStride else { return }
            let frames = min(Int(list[channels.left.buffer].mDataByteSize) / (leftStride * MemoryLayout<Float>.size),
                             Int(list[channels.right.buffer].mDataByteSize) / (rightStride * MemoryLayout<Float>.size), 16384)
            guard frames > 0 else { return }
            // The scalar is ticks per frame against the nominal: above 1, the
            // output is running slow. The driver's rate is frames per tick.
            if outTime.pointee.mFlags.contains(.rateScalarValid), outTime.pointee.mRateScalar > 0 {
                reader.pointee.deviceRate = 1 / outTime.pointee.mRateScalar
            }

            _ = driver_shared_latest_write(shared, &reader.pointee.write)
            let write = reader.pointee.write
            guard write.outputHost != 0 else { return }
            let head = write.head
            let needed = Int64(frames)
            var level = Int64(bitPattern: head &- reader.pointee.position)
            reader.pointee.lastLevel = level
            reader.pointee.cycleFrames = UInt32(frames)

            // The frame due now, on the time line the apps were given: this cycle
            // reaches the output at its time stamp, and the device reports what it
            // holds back. The last write says where that time line is.
            let host = outTime.pointee.mFlags.contains(.hostTimeValid) ? outTime.pointee.mHostTime : mach_absolute_time()
            let sinceDue = Double(Int64(bitPattern: host &- write.outputHost)) * framesPerTick
            let due = Int64(bitPattern: head &- UInt64(write.frames)) + Int64(sinceDue - held - reader.pointee.slack)
            var late = due - Int64(bitPattern: reader.pointee.position)

            // Stalled behind what the ring still holds, while playing: from now.
            if reader.pointee.playing, level > Int64(DRIVER_RING_FRAMES) / 2 {
                reader.pointee.position = head
                reader.pointee.playing = false
                reader.pointee.skips += 1
                level = 0
                late = due - Int64(bitPattern: head)
            }
            if !reader.pointee.playing {
                let running = driver_shared_io_running(shared)
                guard level >= needed else { return }
                // Not yet its time, within half a cycle, as a cycle is as fine as this
                // gets. With the device stopped nothing more is coming, so it plays.
                guard !running || late >= -needed / 2 else { return }
                if running, late > 0 {
                    if reader.pointee.ranOut || write.nominalFrames >= longWrite {
                        // A gap, which is lost anyway, or a player: what's past its
                        // time goes, so the sound and its picture stay together.
                        let on = min(late, level - needed)
                        reader.pointee.position &+= UInt64(on)
                    } else {
                        // Everything that came while it wasn't playing, or a short
                        // sound would be over before it's heard: up to what's fair to
                        // be late by, and with no silence an app opened with.
                        let most = min(Int64(sampleRate * Self.mostToCatchUp), Int64(DRIVER_RING_FRAMES) / 2)
                        let keep = max(needed, min(level, most))
                        let silent = Int64(driver_shared_leading_silence(shared, head &- UInt64(keep), UInt32(keep - needed)))
                        let from = Int64(bitPattern: head) - keep + silent
                        reader.pointee.position = UInt64(bitPattern: min(from, max(due, Int64(bitPattern: reader.pointee.position))))
                    }
                    level = Int64(bitPattern: head &- reader.pointee.position)
                    late = due - Int64(bitPattern: reader.pointee.position)
                }
                // More came: that was a gap. Next time keep more to spare, unless
                // it's the first moments of a new output.
                if reader.pointee.ranOut {
                    reader.pointee.ranOut = false
                    reader.pointee.underruns += 1
                    if reader.pointee.playedFrames > sampleRate * 2 {
                        reader.pointee.slack = min(reader.pointee.slack + oneMillisecond, oneMillisecond * 20)
                    }
                }
                reader.pointee.playing = true
                reader.pointee.late = Double(late)
            } else if level < needed {
                // A gap only if the device is still running: otherwise the sound's over.
                reader.pointee.playing = false
                reader.pointee.ranOut = driver_shared_io_running(shared) && reader.pointee.lastCycleHadSound
                return
            } else if reader.pointee.late < -Double(frames),
                      driver_shared_leading_silence(shared, reader.pointee.position, UInt32(frames)) == UInt32(frames) {
                // Ahead of its time, in a moment of silence, which no one hears grow.
                reader.pointee.late += Double(frames)
                return
            }

            driver_shared_read(shared, reader.pointee.position, scratch, UInt32(frames))
            reader.pointee.position &+= UInt64(frames)
            reader.pointee.playedFrames += Double(frames)
            let left = leftData.assumingMemoryBound(to: Float.self) + channels.left.offset
            let right = rightData.assumingMemoryBound(to: Float.self) + channels.right.offset
            if let equalizer { filters.update(equalizer.load()) }
            let applied = reader.pointee.appliedGain
            let wanted = Float(bitPattern: mainGain.bits.load(ordering: .relaxed))
            let step = (wanted - applied) / Float(frames)
            var hadSound = false
            for frame in 0..<frames {
                let g = applied + step * Float(frame)
                #if TOOLKIT_DEV
                if abs(scratch[frame * 2]) > 0.05 {
                    if reader.pointee.quietFrames > 4800 {
                        reader.pointee.markerHost = host + UInt64(Double(frame) / framesPerTick)
                    }
                    reader.pointee.quietFrames = 0
                } else {
                    reader.pointee.quietFrames += 1
                }
                #endif
                if abs(scratch[frame * 2]) > 0.00001 {
                    reader.pointee.soundFrames += 1
                    hadSound = true
                }
                var l = scratch[frame * 2] * g
                var r = scratch[frame * 2 + 1] * g
                if equalizer != nil { filters.process(&l, &r) }
                if channels.left == channels.right {
                    left[frame * leftStride] = (l + r) * 0.5
                } else {
                    left[frame * leftStride] = l
                    right[frame * rightStride] = r
                }
            }
            reader.pointee.appliedGain = wanted
            reader.pointee.lastCycleHadSound = hadSound

            // Averaged over a second or so. Behind its time, the driver's clock slows
            // until it isn't: nothing is resampled, so that's only how fast apps are
            // asked for sound, and it isn't heard. At once in a moment of silence.
            reader.pointee.late += (Double(late) - reader.pointee.late) * min(1, Double(frames) / sampleRate)
            let off = reader.pointee.late / sampleRate
            let limit = abs(off) > 0.005 ? fastest : furthest
            reader.pointee.correction = max(-limit, min(limit, -off * clockGain))
            if off > Double(frames) / sampleRate, level - needed >= needed,
               driver_shared_leading_silence(shared, reader.pointee.position, UInt32(frames)) == UInt32(frames) {
                reader.pointee.position &+= UInt64(frames)
                reader.pointee.late -= Double(frames)
            }
            driver_shared_set_rate(shared, reader.pointee.deviceRate * (1 + reader.pointee.correction))
        }

        var id: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&id, device, nil, block)
        guard status == noErr, let id else {
            Log.mixer.error("driver: output's IO proc: \(status, privacy: .public)")
            return false
        }
        // An output that has only just appeared can take a moment to agree.
        for attempt in 0..<10 {
            status = AudioDeviceStart(device, id)
            if status == noErr { break }
            if attempt < 9 { usleep(100_000) }
        }
        guard status == noErr else {
            Log.mixer.error("driver: output start: \(status, privacy: .public)")
            AudioDeviceDestroyIOProcID(device, id)
            return false
        }
        output = device
        ioProc = id
        Log.mixer.notice("driver: playing on \(device.readString(kAudioDevicePropertyDeviceUID) ?? "?", privacy: .public), \(sampleRate, privacy: .public) Hz, channels \(channels.left.offset, privacy: .public)/\(channels.right.offset, privacy: .public)")
        return true
    }

    private func stopOutput() {
        guard let output, let ioProc else { return }
        AudioDeviceStop(output, ioProc)
        AudioDeviceDestroyIOProcID(output, ioProc)
        self.output = nil
        self.ioProc = nil
        stoppedWhilePlaying = driver_shared_io_running(shared)
        // Back to the host's clock, while nothing follows the output.
        driver_shared_set_rate(shared, 1)
        Log.mixer.notice("driver: output let go, \(self.reader.pointee.underruns, privacy: .public) gaps, \(self.reader.pointee.skips, privacy: .public) skips")
    }

    /// Off the audio thread, on the mixer's slow timer: a gap goes in the log
    /// as it happens, with what was queued then.
    func logNewGaps() {
        let now = (reader.pointee.underruns, reader.pointee.skips)
        guard now != loggedGaps else { return }
        loggedGaps = now
        Log.mixer.notice("driver: a gap in the sound: \(self.state, privacy: .public)")
    }

    /// The main volume, where the real output has none of its own. Glided.
    var gain: Float {
        get { Float(bitPattern: mainGain.bits.load(ordering: .relaxed)) }
        set { mainGain.bits.store(max(0, min(1, newValue)).bitPattern, ordering: .relaxed) }
    }

    /// Each process's volume, for those that aren't at full. The driver glides to them.
    func setGains(_ gains: [pid_t: Float]) {
        for (pid, slot) in slots where gains[pid] == nil {
            driver_shared_set_gain(shared, slot, 0, 1)
            slots[pid] = nil
        }
        for (pid, gain) in gains {
            let slot = slots[pid] ?? (0..<DRIVER_SLOTS).first { !slots.values.contains($0) }
            guard let slot else {
                Log.mixer.error("driver: no room for the volume of pid \(pid, privacy: .public)")
                continue
            }
            slots[pid] = slot
            driver_shared_set_gain(shared, slot, pid, gain)
        }
    }

    /// The loudest each client has been since the last call, by process,
    /// before its volume: a turned down app still counts as playing.
    func takePeaks() -> [pid_t: Float] {
        var peaks: [pid_t: Float] = [:]
        for slot in 0..<DRIVER_SLOTS {
            let pid = driver_shared_client(shared, slot)
            guard pid != 0 else { continue }
            peaks[pid] = Swift.max(peaks[pid] ?? 0, driver_shared_take_peak(shared, slot))
        }
        return peaks
    }

    /// What the device tells apps, for their pictures to keep with their
    /// sound: what's held back behind their time (a cycle of the real output, its
    /// safety offset and the slack), the limiter's look-ahead and the output's own.
    private static func latency(of device: AudioObjectID, sampleRate: Float64) -> UInt32 {
        let scope = kAudioObjectPropertyScopeOutput
        let stream = device.readArray(kAudioDevicePropertyStreams, scope: scope, as: AudioStreamID.self).first
        let own = (device.read(kAudioDevicePropertyLatency, scope: scope, as: UInt32.self) ?? 0)
            + (device.read(kAudioDevicePropertySafetyOffset, scope: scope, as: UInt32.self) ?? 0)
            + (device.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0)
            + (stream?.read(kAudioStreamPropertyLatency, as: UInt32.self) ?? 0)
        return own + UInt32((slackSeconds + lookAheadSeconds) * sampleRate)
    }

    /// For the log and the test, read off the audio thread: a moment stale.
    var state: String {
        let reader = reader.pointee
        func ms(_ frames: Double) -> String { String(format: "%.1f", frames / reader.sampleRate * 1000) }
        return "\(reader.soundFrames) frames of sound, queued \(ms(Double(reader.lastLevel))) ms, \(ms(reader.late)) ms behind its time, cycles of \(reader.write.nominalFrames), "
            + "\(reader.underruns) gaps, \(reader.skips) skips, rate \(String(format: "%.6f", driver_shared_rate(shared)))"
    }

    #if TOOLKIT_DEV
    /// For `--test-driver-sync`.
    var markerHost: UInt64 { reader.pointee.markerHost }
    #endif

    /// The loudest sample in the last 512 frames written, for the test: proof
    /// that sound really comes through the shared memory.
    var recentPeak: Float {
        let frames = UnsafeMutablePointer<Float>.allocate(capacity: 512 * Int(DRIVER_CHANNELS))
        defer { frames.deallocate() }
        driver_shared_read(shared, driver_shared_write_head(shared) &- 512, frames, 512)
        return (0..<512 * Int(DRIVER_CHANNELS)).reduce(0) { max($0, abs(frames[$1])) }
    }

    // MARK: - The output's stereo pair

    struct Channel: Equatable {
        let buffer: Int
        let offset: Int
    }

    /// Where the device's preferred left and right channels are in the
    /// buffers of its IO proc. One channel: the same for both, which plays them mixed.
    private static func stereo(of device: AudioObjectID) -> (left: Channel, right: Channel)? {
        let streams = readStreamConfiguration(of: device)
        let total = streams.reduce(0, +)
        guard total > 0 else { return nil }
        let preferred = device.readArray(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput, as: UInt32.self)
        let wanted = preferred.count == 2 ? preferred.map { Int($0) - 1 } : [0, 1]
        func channel(_ index: Int) -> Channel {
            var left = min(max(index, 0), total - 1)
            for (buffer, count) in streams.enumerated() {
                if left < count { return Channel(buffer: buffer, offset: left) }
                left -= count
            }
            return Channel(buffer: 0, offset: 0)
        }
        return (channel(wanted[0]), channel(wanted[1]))
    }

    /// The channels of each buffer the device's IO proc gets.
    static func readStreamConfiguration(of device: AudioObjectID) -> [Int] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }
}
