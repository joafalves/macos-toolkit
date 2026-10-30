import CoreAudio
import DriverShared
import Foundation
import os

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

    private let shared: UnsafeMutablePointer<DriverSharedHeader>
    private let reader = UnsafeMutablePointer<Reader>.allocate(capacity: 1)
    /// Interleaved frames for one cycle of the real output.
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * Int(DRIVER_CHANNELS))
    private var heartbeat: DispatchSourceTimer?
    private var output: AudioObjectID?
    private var ioProc: AudioDeviceIOProcID?

    init() throws {
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
        beat()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [shared] in driver_shared_set_heartbeat(shared, mach_absolute_time()) }
        timer.resume()
        heartbeat = timer
        Log.mixer.notice("driver: linked")
    }

    deinit {
        close()
        // Never unmapped or freed: the audio thread may have only just left,
        // and this happens at most a few times in a run.
    }

    private func beat() {
        driver_shared_set_heartbeat(shared, mach_absolute_time())
    }

    /// Tells the driver it's over, which hides its device within a second.
    func close() {
        stop()
        heartbeat?.cancel()
        heartbeat = nil
        driver_shared_set_closing(shared, true)
    }

    /// Plays what the driver writes on `device`, from now on, at the driver's
    /// sample rate, which the caller keeps the same as the device's.
    @discardableResult
    func start(on device: AudioObjectID) -> Bool {
        // Macs say the device is running again as each app joins: restarting
        // the output for that would be a gap in everything playing.
        if output == device, ioProc != nil { return true }
        stop()
        guard let channels = Self.stereo(of: device) else {
            Log.mixer.error("driver: output \(device, privacy: .public) has no channels to play on")
            return false
        }
        let sampleRate = device.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        reader.pointee = Reader()
        reader.pointee.position = driver_shared_write_head(shared)
        reader.pointee.slack = Self.slackSeconds * sampleRate
        let shared = shared, reader = reader, scratch = scratch
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let framesPerTick = sampleRate * Double(timebase.numer) / (Double(timebase.denom) * 1e9)
        let gain = Self.gain, furthest = Self.furthest
        let oneMillisecond = sampleRate / 1000

        let block: AudioDeviceIOBlock = { _, _, _, outData, outTime in
            let list = UnsafeMutableAudioBufferListPointer(outData)
            guard list.count > channels.left.buffer, list.count > channels.right.buffer,
                  let leftData = list[channels.left.buffer].mData, let rightData = list[channels.right.buffer].mData else { return }
            let leftStride = Int(list[channels.left.buffer].mNumberChannels)
            let rightStride = Int(list[channels.right.buffer].mNumberChannels)
            let bytes = Int(list[channels.left.buffer].mDataByteSize)
            let frames = min(bytes / (leftStride * MemoryLayout<Float>.size), 16384)
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

            // Stalled behind what the ring still holds: start again from now.
            if level > Int64(DRIVER_RING_FRAMES) / 2 {
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
                guard written > 0, level >= needed else { return }
                // A write that's only just come could as well have come after
                // this read: one more in hand, until the clock has moved away.
                let inHand = needed + (locks && sinceWrite >= reader.pointee.slack ? 0 : written)
                guard level >= inHand else { return }
                reader.pointee.position = head &- UInt64(inHand)
                reader.pointee.playing = true
                reader.pointee.ahead = Double(inHand) + sinceWrite
                level = inHand
            } else if level < needed {
                // A gap. Next time keep more to spare, up to a whole write.
                reader.pointee.playing = false
                reader.pointee.underruns += 1
                reader.pointee.slack = min(reader.pointee.slack + oneMillisecond, max(Double(written), oneMillisecond))
                return
            }

            driver_shared_read(shared, reader.pointee.position, scratch, UInt32(frames))
            reader.pointee.position &+= UInt64(frames)
            let left = leftData.assumingMemoryBound(to: Float.self) + channels.left.offset
            let right = rightData.assumingMemoryBound(to: Float.self) + channels.right.offset
            if channels.left == channels.right {
                for frame in 0..<frames { left[frame * leftStride] = (scratch[frame * 2] + scratch[frame * 2 + 1]) * 0.5 }
            } else {
                for frame in 0..<frames {
                    left[frame * leftStride] = scratch[frame * 2]
                    right[frame * rightStride] = scratch[frame * 2 + 1]
                }
            }

            // Averaged over a second or so, against where the reads should land.
            // Too far ahead: the driver's clock slows until it isn't.
            if sinceWrite <= Double(written) * 2 {
                let ahead = Double(level) + sinceWrite
                reader.pointee.ahead += (ahead - reader.pointee.ahead) * min(1, Double(frames) / sampleRate)
                let off = (reader.pointee.ahead - target) / sampleRate
                reader.pointee.correction = max(-furthest, min(furthest, -off * gain))
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
        status = AudioDeviceStart(device, id)
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

    /// Lets go of the real output, so it and the Mac can sleep.
    func stop() {
        guard let output, let ioProc else { return }
        AudioDeviceStop(output, ioProc)
        AudioDeviceDestroyIOProcID(output, ioProc)
        self.output = nil
        self.ioProc = nil
        // Back to the host's clock, while nothing follows the output.
        driver_shared_set_rate(shared, 1)
        Log.mixer.notice("driver: output let go, \(self.reader.pointee.underruns, privacy: .public) gaps, \(self.reader.pointee.skips, privacy: .public) skips")
    }

    var isPlaying: Bool { ioProc != nil }

    /// For the log and the test, read off the audio thread: a moment stale.
    var state: String {
        let reader = reader.pointee
        let rate = output?.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        func ms(_ frames: Double) -> String { String(format: "%.1f", frames / rate * 1000) }
        return "queued \(ms(reader.ahead)) ms (\(ms(Double(reader.cycleFrames) + reader.slack)) wanted), reads \(ms(reader.sinceWriteLow))-\(ms(reader.sinceWriteHigh)) ms after a write, "
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
