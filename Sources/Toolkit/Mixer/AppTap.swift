import CoreAudio
import Foundation
import Synchronization

/// Plays one app's sound at its own volume. macOS has no setting for that, so
/// the app's output is captured with a process tap, which also silences the
/// original, and played again on the output device with the gain applied.
///
/// A tap takes `objects` and every process of `bundleIDs`; a global tap takes
/// everything but those. The mixer keeps one global tap for whatever has no
/// tap of its own, which gives outputs with no volume control of their own a
/// software volume and runs the equalizer on everything.
///
/// Its device only runs while something it takes has its output running, so
/// a tap made ahead costs nothing until then. Once running it never stops by
/// itself, which keeps the output and the Mac awake: `rearm` puts it back to
/// waiting once that sound has stopped.
///
/// Without `controlsVolume` the tap only listens: the app plays as usual and
/// the tap measures how loud it is.
///
/// Without `autoStart` the device runs from the start instead of waiting.
/// A process a waiting tap takes can't start its input until a tap runs, and
/// the tap waits for it to play: on macOS 26 a call app's preview, which only
/// opens the microphone, froze until the mixer was turned off.
final class AppTap {
    /// Our aggregate devices carry this in their UID, so leftovers from a
    /// crash can be found and removed.
    static let uidPrefix = "dev.jalves.macos-toolkit.mixer."
    static let tapName = "MacOS Toolkit Mixer"

    private(set) var objects: [AudioObjectID]
    /// Taken (or, global, left out) by bundle ID, which works before they have played anything.
    private(set) var bundleIDs: [String]
    let deviceUID: String
    private let stereo: (Int, Int)
    let controlsVolume: Bool
    let isGlobal: Bool
    let autoStart: Bool
    /// Applied to what this tap plays, when it is on.
    private let equalizer: EqualizerState?

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let shared = Shared()

    /// What the audio thread reads; a class so the render block can hold it.
    private final class Shared: Sendable {
        let gainBits = Atomic<UInt32>(0)
        let peakBits = Atomic<UInt32>(0)
        let callbacks = Atomic<UInt32>(0)
    }

    /// Goes up with every buffer while the device runs.
    var callbacks: UInt32 { shared.callbacks.load(ordering: .relaxed) }

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
    /// `stereo`: the output's channels for left and right, from 0, as it
    /// prefers them (Audio MIDI Setup's Configure Speakers).
    init?(objects: [AudioObjectID], deviceUID: String, gain: Float, controlsVolume: Bool = true, isGlobal: Bool = false,
          autoStart: Bool = true, bundleIDs: [String] = [], stereo: (Int, Int) = (0, 1), equalizer: EqualizerState? = nil) {
        self.stereo = stereo
        self.objects = objects
        self.bundleIDs = bundleIDs
        self.equalizer = equalizer
        self.deviceUID = deviceUID
        self.controlsVolume = controlsVolume
        self.isGlobal = isGlobal
        self.autoStart = autoStart
        self.gain = gain
        guard start() else {
            stop()
            return nil
        }
    }

    deinit { stop() }

    private func start() -> Bool {
        let description = isGlobal
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
            : CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = Self.tapName
        if !bundleIDs.isEmpty, #available(macOS 26.0, *) {
            description.bundleIDs = bundleIDs
        }
        description.uuid = UUID()
        description.isPrivate = true
        // Muted only while we read it, so the app is never left silent if we stop.
        description.muteBehavior = controlsVolume ? .mutedWhenTapped : .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { return log("create tap", status) }
        if isGlobal { logExclusions() }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.tapName,
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: autoStart,
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

    /// Changes what the tap takes while it runs, with no new device: an app
    /// moved this way between two running taps doesn't click, where a new
    /// tap made for it plays it twice for a moment. False when macOS refuses.
    func update(objects: [AudioObjectID], bundleIDs: [String]) -> Bool {
        guard objects != self.objects || bundleIDs != self.bundleIDs else { return true }
        guard let current = tapID.read(kAudioTapPropertyDescription, as: Unmanaged<CATapDescription>?.self) ?? nil else { return false }
        // Unretained, as in `removeLeftovers`.
        let description = current.takeUnretainedValue()
        description.processes = objects
        if #available(macOS 26.0, *) { description.bundleIDs = bundleIDs }
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var reference = description
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else { return log("change tap", status) }
        self.objects = objects
        self.bundleIDs = bundleIDs
        return true
    }

    /// Stopped and started again, the device waits for sound as a new one
    /// does, and lets the output and the Mac sleep. Only once what it takes
    /// has stopped: during the moment it's stopped, an app would play unmuted.
    func rearm() {
        guard let procID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceStart(aggregateID, procID)
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

    /// What the global tap really leaves out, as macOS has it.
    private func logExclusions() {
        guard let description = tapID.read(kAudioTapPropertyDescription, as: Unmanaged<CATapDescription>?.self) ?? nil else { return }
        let tap = description.takeUnretainedValue()
        var bundles = ""
        if #available(macOS 26.0, *) { bundles = "\(tap.bundleIDs)" }
        NSLog("Toolkit: mixer global tap excludes processes \(tap.processes) bundles \(bundles), exclusive \(tap.isExclusive)")
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
        let equalizer = self.equalizer
        let filters = EqualizerFilters(sampleRate: format.mSampleRate)
        let stereo = self.stereo
        var current = gain

        return { _, inputList, _, outputList, _ in
            shared.callbacks.add(1, ordering: .relaxed)
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
            let outputs = UnsafeMutableAudioBufferListPointer(outputList)
            let target = Float(bitPattern: shared.gainBits.load(ordering: .relaxed))

            // The tap's stream comes after the output device's own inputs.
            let first = inputs.count - tapBuffers
            guard first >= 0, let data = inputs[first].mData else {
                for output in outputs { if let out = output.mData { memset(out, 0, Int(output.mDataByteSize)) } }
                return
            }
            var frames = Int(inputs[first].mDataByteSize) / MemoryLayout<Float>.size / (interleaved ? channels : 1)

            // Measured before the gain, so a turned down app still counts as playing.
            var peak: Float = 0
            for index in first..<inputs.count {
                guard let samples = inputs[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(inputs[index].mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(samples[i])) }
            }
            if peak > Float(bitPattern: shared.peakBits.load(ordering: .relaxed)) {
                shared.peakBits.store(peak.bitPattern, ordering: .relaxed)
            }
            for output in outputs { if let out = output.mData { memset(out, 0, Int(output.mDataByteSize)) } }
            guard controlsVolume else { return }

            @inline(__always) func sample(_ frame: Int, _ channel: Int) -> Float {
                if interleaved { return data.assumingMemoryBound(to: Float.self)[frame * channels + channel] }
                guard let plane = inputs[first + channel].mData else { return 0 }
                return plane.assumingMemoryBound(to: Float.self)[frame]
            }

            var totalOutputs = 0
            for output in outputs where output.mNumberChannels > 0 {
                totalOutputs += Int(output.mNumberChannels)
                frames = min(frames, Int(output.mDataByteSize) / MemoryLayout<Float>.size / Int(output.mNumberChannels))
            }
            // The first two when the preferred pair isn't there.
            let (leftChannel, rightChannel) = max(stereo.0, stereo.1) < totalOutputs ? stereo : (0, 1)
            if let equalizer { filters.update(equalizer.load()) }
            let eq = equalizer != nil
            let step = frames > 0 ? (target - current) / Float(frames) : 0

            for frame in 0..<frames {
                let g = current + step * Float(frame)
                // The tap is a stereo mix: left and right.
                var left = sample(frame, 0) * g
                var right = (channels > 1 ? sample(frame, 1) : sample(frame, 0)) * g
                // Equalized or not, through the same 1.5 ms, so every tap's delay is the same.
                if eq { filters.process(&left, &right) }
                // Left and right go to the output's stereo pair, other speakers stay silent.
                var base = 0
                for output in outputs {
                    let outChannels = Int(output.mNumberChannels)
                    guard let out = output.mData?.assumingMemoryBound(to: Float.self), outChannels > 0 else { continue }
                    for c in 0..<outChannels {
                        let channel = base + c
                        let value: Float = totalOutputs == 1 ? (left + right) / 2 : channel == leftChannel ? left : channel == rightChannel ? right : 0
                        out[frame * outChannels + c] = value
                    }
                    base += outChannels
                }
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
