import CoreAudio
import Foundation
import Synchronization

/// Plays one app's sound at its own volume. macOS has no setting for that, so
/// the app's output is captured with a process tap, which also silences the
/// original, and played again on the output device with the gain applied.
///
/// Without `controlsVolume` the tap only listens: the app plays as usual and
/// the tap measures how loud it is, to tell real sound from an app that keeps
/// its output running in silence (paused Safari, Discord, games).
final class AppTap {
    /// Our aggregate devices carry this in their UID, so leftovers from a
    /// crash can be found and removed.
    static let uidPrefix = "dev.jalves.macos-toolkit.mixer."
    static let tapName = "MacOS Toolkit Mixer"

    let objects: [AudioObjectID]
    let deviceUID: String
    let controlsVolume: Bool

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let shared = Shared()

    /// What the audio thread reads; a class so the render block can hold it.
    private final class Shared: Sendable {
        let gainBits = Atomic<UInt32>(0)
        let peakBits = Atomic<UInt32>(0)
    }

    /// The loudest sample since the last call, 0 to 1.
    func takePeak() -> Float {
        Float(bitPattern: shared.peakBits.exchange(0, ordering: .relaxed))
    }

    /// Linear gain, 0 to 1. Changes are ramped over one buffer so they don't click.
    var gain: Float {
        get { Float(bitPattern: shared.gainBits.load(ordering: .relaxed)) }
        set { shared.gainBits.store(max(0, min(1, newValue)).bitPattern, ordering: .relaxed) }
    }

    /// Nil when macOS refuses any step, for example without the permission.
    init?(objects: [AudioObjectID], deviceUID: String, gain: Float, controlsVolume: Bool = true) {
        self.objects = objects
        self.deviceUID = deviceUID
        self.controlsVolume = controlsVolume
        self.gain = gain
        guard start() else {
            stop()
            return nil
        }
    }

    deinit { stop() }

    private func start() -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = Self.tapName
        description.uuid = UUID()
        description.isPrivate = true
        // Muted only while we read it, so the app is never left silent if we stop.
        description.muteBehavior = controlsVolume ? .mutedWhenTapped : .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { return log("create tap", status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.tapName,
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { return log("create aggregate device", status) }

        guard let format = tapID.read(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { return log("read tap format", -1) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, makeRenderBlock(format: format))
        guard status == noErr, let procID else { return log("create IO proc", status) }
        disableHardwareInputs(procID)

        // A new aggregate device can take a moment before it agrees to start.
        for attempt in 0..<10 {
            status = AudioDeviceStart(aggregateID, procID)
            if status == noErr {
                if controlsVolume { logDelay() }
                return true
            }
            if attempt < 9 { usleep(20_000) }
        }
        return log("start", status)
    }

    private func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    /// What the detour adds on top of the app's normal path: one buffer, plus
    /// the time the tap's input is held back for safety.
    private func logDelay() {
        let rate = aggregateID.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0
        let buffer = aggregateID.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0
        let input = kAudioObjectPropertyScopeInput
        let held = (aggregateID.read(kAudioDevicePropertySafetyOffset, scope: input, as: UInt32.self) ?? 0)
            + (aggregateID.read(kAudioDevicePropertyLatency, scope: input, as: UInt32.self) ?? 0)
        guard rate > 0 else { return }
        let ms = { (frames: UInt32) in String(format: "%.1f", Double(frames) / rate * 1000) }
        NSLog("Toolkit: mixer tap started on \(deviceUID): buffer \(buffer) frames (\(ms(buffer)) ms), input held \(ms(held)) ms at \(Int(rate)) Hz")
    }

    private func log(_ step: String, _ status: OSStatus) -> Bool {
        NSLog("Toolkit: mixer could not \(step) (\(status))")
        return false
    }

    /// The aggregate device also offers the output device's own inputs, such
    /// as the AirPods microphone. Opening those would drop AirPods into their
    /// low quality call mode, so only the tap's stream, the last input, stays on.
    private func disableHardwareInputs(_ procID: AudioDeviceIOProcID) {
        let streams = aggregateID.readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, as: AudioStreamID.self).count
        guard streams > 1 else { return }

        // AudioHardwareIOProcStreamUsage is { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }.
        let flagsOffset = MemoryLayout<UnsafeRawPointer>.size + MemoryLayout<UInt32>.size
        let size = flagsOffset + MemoryLayout<UInt32>.size * streams
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { usage.deallocate() }
        usage.storeBytes(of: unsafeBitCast(procID, to: UnsafeRawPointer.self), as: UnsafeRawPointer.self)
        usage.storeBytes(of: UInt32(streams), toByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
        for index in 0..<streams {
            let on: UInt32 = index == streams - 1 ? 1 : 0
            usage.storeBytes(of: on, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), usage)
        if status != noErr { _ = log("turn off the device's inputs", status) }
    }

    /// Runs on the audio thread: no locks, no allocation, no Objective-C.
    private func makeRenderBlock(format: AudioStreamBasicDescription) -> AudioDeviceIOBlock {
        let channels = max(1, Int(format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let tapBuffers = interleaved ? 1 : channels
        let shared = self.shared
        let controlsVolume = self.controlsVolume
        var current = gain

        return { _, inputList, _, outputList, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
            let outputs = UnsafeMutableAudioBufferListPointer(outputList)
            let target = Float(bitPattern: shared.gainBits.load(ordering: .relaxed))

            // The tap's stream comes after the output device's own inputs.
            let first = inputs.count - tapBuffers
            guard first >= 0, let data = inputs[first].mData else {
                for output in outputs { if let out = output.mData { memset(out, 0, Int(output.mDataByteSize)) } }
                return
            }
            let frames = Int(inputs[first].mDataByteSize) / MemoryLayout<Float>.size / (interleaved ? channels : 1)

            // Measured before the gain, so a turned down app still counts as playing.
            var peak: Float = 0
            for index in first..<inputs.count {
                guard let samples = inputs[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(inputs[index].mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(samples[i])) }
            }
            if peak > Float(bitPattern: shared.peakBits.load(ordering: .relaxed)) {
                shared.peakBits.store(peak.bitPattern, ordering: .relaxed)
            }
            guard controlsVolume else {
                for output in outputs { if let out = output.mData { memset(out, 0, Int(output.mDataByteSize)) } }
                return
            }

            @inline(__always) func sample(_ frame: Int, _ channel: Int) -> Float {
                if interleaved { return data.assumingMemoryBound(to: Float.self)[frame * channels + channel] }
                guard let plane = inputs[first + channel].mData else { return 0 }
                return plane.assumingMemoryBound(to: Float.self)[frame]
            }

            var totalOutputs = 0
            for output in outputs { totalOutputs += Int(output.mNumberChannels) }
            let step = frames > 0 ? (target - current) / Float(frames) : 0

            var base = 0
            for output in outputs {
                let outChannels = Int(output.mNumberChannels)
                guard let out = output.mData?.assumingMemoryBound(to: Float.self), outChannels > 0 else { continue }
                let outFrames = min(frames, Int(output.mDataByteSize) / MemoryLayout<Float>.size / outChannels)
                for frame in 0..<outFrames {
                    let g = current + step * Float(frame)
                    for c in 0..<outChannels {
                        let channel = base + c
                        let value: Float
                        if totalOutputs == 1 {
                            var sum: Float = 0
                            for ch in 0..<channels { sum += sample(frame, ch) }
                            value = sum / Float(channels)
                        } else {
                            // Left and right go to the first two outputs, other speakers stay silent.
                            value = channel < channels ? sample(frame, channel) : 0
                        }
                        out[frame * outChannels + c] = value * g
                    }
                }
                let written = outFrames * outChannels
                let capacity = Int(output.mDataByteSize) / MemoryLayout<Float>.size
                if written < capacity { (out + written).update(repeating: 0, count: capacity - written) }
                base += outChannels
            }
            current = target
        }
    }

    /// Removes aggregate devices and taps a crashed run of the toolkit left
    /// behind, which would otherwise keep their apps silent.
    static func removeLeftovers() {
        for device in AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, as: AudioObjectID.self) {
            if device.readString(kAudioDevicePropertyDeviceUID)?.hasPrefix(uidPrefix) == true {
                AudioHardwareDestroyAggregateDevice(device)
            }
        }
        for tap in AudioObjectID.system.readArray(kAudioHardwarePropertyTapList, as: AudioObjectID.self) {
            guard let unmanaged = tap.read(kAudioTapPropertyDescription, as: Unmanaged<CATapDescription>?.self) ?? nil else { continue }
            // Unretained on purpose: leaking one object at launch beats an over-release.
            if unmanaged.takeUnretainedValue().name == tapName {
                AudioHardwareDestroyProcessTap(tap)
            }
        }
    }
}
