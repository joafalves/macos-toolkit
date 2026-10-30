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
/// here, taken from the real output, and nudged to keep as little queued as
/// plays without a gap. So nothing is resampled and the delay stays put.
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
        /// What the driver writes each cycle. Not the last write: the host
        /// makes the odd one short when a new client joins.
        var writeSize: Int64 = 0
        var writeSizeRun = 0
        /// How far ahead the driver is at each read, counting the time since
        /// its last write, so it doesn't jump by a whole write as the level does.
        var ahead = 0.0
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
        var windowFrames: UInt32 = 0
        var windowLow = Double.infinity
        var windowHigh = 0.0
        var sinceWriteLow = 0.0
        var sinceWriteHigh = 0.0
    }

    /// The least time to spare after a write: the driver's and the output's
    /// threads both wake a little late at times.
    private static let slackSeconds = 0.003
    /// How much faster or slower per second off target: gone in about 10 s,
    /// at a rate no one can hear.
    private static let gain = 0.1
    /// Well inside what the driver accepts, and what a real clock could be off.
    private static let furthest = 0.0005
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
    /// Starts and stops the real output, and holds these two.
    private let outputQueue = DispatchQueue(label: "dev.jalves.macos-toolkit.driver-output", qos: .userInitiated)
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
        outputQueue.sync { stopOutput() }
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
        outputQueue.async { [self] in _ = startOutput(on: device) }
    }

    /// Lets go of the real output, so it and the Mac can sleep.
    func stop() {
        outputQueue.async { [self] in stopOutput() }
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
        let clockGain = Self.gain, furthest = Self.furthest
        let oneMillisecond = sampleRate / 1000

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

            // A write and its time, not one of each from either side of a write.
            var ticks = driver_shared_last_write_ticks(shared)
            var head = driver_shared_write_head(shared)
            let again = driver_shared_last_write_ticks(shared)
            if again != ticks {
                ticks = again
                head = driver_shared_write_head(shared)
            }
            let lastWrite = Int64(driver_shared_last_write_frames(shared))
            if lastWrite == reader.pointee.writeSize {
                reader.pointee.writeSizeRun = 0
            } else if lastWrite > 0 {
                reader.pointee.writeSizeRun += 1
                // A while of the same new size, or the first we've seen.
                if reader.pointee.writeSize == 0 || reader.pointee.writeSizeRun >= 16 {
                    reader.pointee.writeSize = lastWrite
                    reader.pointee.writeSizeRun = 0
                }
            }
            let written = reader.pointee.writeSize
            let now = mach_absolute_time()
            let sinceWrite = now > ticks ? Double(now - ticks) * framesPerTick : 0
            let needed = Int64(frames)
            var level = Int64(bitPattern: head &- reader.pointee.position)
            reader.pointee.lastLevel = level
            reader.pointee.cycleFrames = UInt32(frames)

            // Stalled behind what the ring still holds, while playing: from now.
            if reader.pointee.playing, level > Int64(DRIVER_RING_FRAMES) / 2 {
                reader.pointee.position = head
                reader.pointee.playing = false
                reader.pointee.skips += 1
                level = 0
            }
            // When the output reads as much as the driver writes (or a whole
            // number of writes), every read lands the same time after a write,
            // and the clock below holds it there: nothing more than one cycle
            // is queued. Otherwise a read can land just before the next write.
            let locks = written > 0 && needed % written == 0
            let target = Double(needed) + reader.pointee.slack + (locks ? 0 : Double(written))
            if !reader.pointee.playing {
                // One write more in hand than it will settle on: the first cycles
                // of a device wake less evenly, and the clock takes the extra away.
                let least = needed + written
                guard written > 0, level >= least else { return }
                // Everything that came while it wasn't playing, or a short sound
                // would be over before it's heard: up to what's fair to be late
                // by, and with no silence an app opened with. Not after a gap in
                // what was playing, which is lost anyway: the burst after a stall
                // would only leave everything late from then on.
                let most = reader.pointee.ranOut ? least : min(Int64(sampleRate * Self.mostToCatchUp), Int64(DRIVER_RING_FRAMES) / 2)
                let keep = max(least, min(level, most))
                let silent = Int64(driver_shared_leading_silence(shared, head &- UInt64(keep), UInt32(keep - least)))
                level = keep - silent
                // More came: that was a gap. Next time keep more to spare, up to a
                // whole write, unless it's the first moments of a new output.
                if reader.pointee.ranOut {
                    reader.pointee.ranOut = false
                    reader.pointee.underruns += 1
                    if reader.pointee.playedFrames > sampleRate * 2 {
                        reader.pointee.slack = min(reader.pointee.slack + oneMillisecond, max(Double(written), oneMillisecond))
                    }
                }
                reader.pointee.position = head &- UInt64(level)
                reader.pointee.playing = true
                reader.pointee.ahead = Double(level) + min(sinceWrite, Double(written))
            } else if level < needed {
                // A gap only if the device is still running: otherwise the sound's over.
                reader.pointee.playing = false
                reader.pointee.ranOut = driver_shared_io_running(shared) && reader.pointee.lastCycleHadSound
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

            // Averaged over a second or so, against where the reads should land.
            // Too far ahead: the driver's clock slows until it isn't.
            if sinceWrite <= Double(written) * 2 {
                let ahead = Double(level) + sinceWrite
                reader.pointee.ahead += (ahead - reader.pointee.ahead) * min(1, Double(frames) / sampleRate)
                let off = (reader.pointee.ahead - target) / sampleRate
                // Well behind, as after catching up on a sound's start: faster, and
                // at once in a moment of silence, which no one can hear go.
                let limit = abs(off) > 0.02 ? furthest * 4 : furthest
                reader.pointee.correction = max(-limit, min(limit, -off * clockGain))
                if off > Double(frames) / sampleRate, level - needed >= needed,
                   driver_shared_leading_silence(shared, reader.pointee.position, UInt32(frames)) == UInt32(frames) {
                    reader.pointee.position &+= UInt64(frames)
                    reader.pointee.ahead -= Double(frames)
                }
                reader.pointee.windowLow = min(reader.pointee.windowLow, sinceWrite)
                reader.pointee.windowHigh = max(reader.pointee.windowHigh, sinceWrite)
            }
            reader.pointee.windowFrames &+= UInt32(frames)
            if Double(reader.pointee.windowFrames) >= sampleRate {
                reader.pointee.sinceWriteLow = reader.pointee.windowLow
                reader.pointee.sinceWriteHigh = reader.pointee.windowHigh
                reader.pointee.windowLow = .infinity
                reader.pointee.windowHigh = 0
                reader.pointee.windowFrames = 0
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
    /// sound: the queue, the limiter's look-ahead and the real output's own.
    private static func latency(of device: AudioObjectID, sampleRate: Float64) -> UInt32 {
        let scope = kAudioObjectPropertyScopeOutput
        let stream = device.readArray(kAudioDevicePropertyStreams, scope: scope, as: AudioStreamID.self).first
        let own = (device.read(kAudioDevicePropertyLatency, scope: scope, as: UInt32.self) ?? 0)
            + (device.read(kAudioDevicePropertySafetyOffset, scope: scope, as: UInt32.self) ?? 0)
            + (device.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0)
            + (stream?.read(kAudioStreamPropertyLatency, as: UInt32.self) ?? 0)
        return own + UInt32((slackSeconds + 0.0015) * sampleRate)
    }

    /// For the log and the test, read off the audio thread: a moment stale.
    var state: String {
        let reader = reader.pointee
        func ms(_ frames: Double) -> String { String(format: "%.1f", frames / reader.sampleRate * 1000) }
        return "\(reader.soundFrames) frames of sound, queued \(ms(reader.ahead)) ms (\(ms(Double(reader.cycleFrames) + reader.slack)) wanted), reads \(ms(reader.sinceWriteLow))-\(ms(reader.sinceWriteHigh)) ms after a write, "
            + "level \(reader.lastLevel), \(reader.underruns) gaps, \(reader.skips) skips, rate \(String(format: "%.6f", driver_shared_rate(shared)))"
    }

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
    private static func readStreamConfiguration(of device: AudioObjectID) -> [Int] {
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
