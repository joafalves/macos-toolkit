import AVFoundation
import ScreenCaptureKit

/// Records a display, an area or a window to an H.264 MP4. Frames only arrive
/// when something on screen changes, so a still screen costs almost nothing in
/// CPU or file size.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Options {
        var nativeResolution = false
        var frameRate = 30
        var showCursor = true
        var showClicks = false
        var systemAudio = false
        var microphone = false
        var microphoneID = ""
    }

    let url: URL
    /// Called on the main queue if the stream ends by itself (the window
    /// closed, the display went away, permission was taken back).
    var onInterrupted: ((Error?) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var mic: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "dev.jalves.macos-toolkit.recorder")

    // Touched on `queue` only.
    private var started = false
    private var paused = false
    private var pausedAt: CMTime?
    /// Time spent paused, taken off every timestamp after it.
    private var offset = CMTime.zero
    private var finished = false
    /// The last timestamp written per output. Buffers captured just before a
    /// pause can arrive after it, and must not go back in time.
    private var last: [SCStreamOutputType: CMTime] = [:]

    init(url: URL) {
        self.url = url
    }

    func start(_ target: CaptureTarget, options: Options, excluding: Set<CGWindowID>) async throws {
        let content = try await CaptureContent.current()
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var points: CGSize
        let scale: CGFloat

        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.notFound }
            filter = SCContentFilter(display: display, excludingWindows: CaptureContent.windows(excluding, in: content))
            points = display.frame.size
            scale = CaptureContent.scale(of: id)
        case .area(let rect):
            guard let display = CaptureContent.display(for: rect, in: content) else { throw CaptureError.notFound }
            let area = rect.intersection(display.frame).integral
            guard !area.isEmpty else { throw CaptureError.notFound }
            filter = SCContentFilter(display: display, excludingWindows: CaptureContent.windows(excluding, in: content))
            config.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            points = area.size
            scale = CaptureContent.scale(of: display.displayID)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.notFound }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.ignoreShadowsSingleWindow = true
            points = filter.contentRect.size
            scale = CGFloat(filter.pointPixelScale)
        }

        // H.264 wants even dimensions.
        let factor = options.nativeResolution ? scale : 1
        let width = Int(points.width * factor) & ~1
        let height = Int(points.height * factor) & ~1
        guard width >= 16, height >= 16 else { throw CaptureError.notFound }
        points = CGSize(width: width, height: height)

        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = options.showCursor
        config.showMouseClicks = options.showClicks
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.captureMicrophone = options.microphone
        if options.microphone, !options.microphoneID.isEmpty { config.microphoneCaptureDeviceID = options.microphoneID }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitRate(width: width, height: height, fps: options.frameRate),
                AVVideoExpectedSourceFrameRateKey: options.frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        self.video = video

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        if options.systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audio = input
        }
        if options.microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            mic = input
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.failed }
        self.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if options.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream
    }

    /// Sized for screen content, which is mostly flat and sharp: enough that
    /// text survives scrolling, without the 20+ Mbit/s a camera would use.
    static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        let perFrame = Double(width * height) * 0.1
        let rate = perFrame * pow(Double(fps), 0.7)
        return Int(min(max(rate, 800_000), 16_000_000))
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            guard paused != self.paused else { return }
            self.paused = paused
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if paused {
                pausedAt = now
            } else if let pausedAt {
                offset = CMTimeAdd(offset, CMTimeSubtract(now, pausedAt))
                self.pausedAt = nil
            }
        }
    }

    /// Ends the file. Returns false when nothing was recorded, and the file is
    /// removed then.
    func stop() async -> Bool {
        try? await stream?.stopCapture()
        stream = nil
        let writer: AVAssetWriter? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                finished = true
                continuation.resume(returning: started ? self.writer : nil)
            }
        }
        guard let writer else {
            self.writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return false
        }
        video?.markAsFinished()
        audio?.markAsFinished()
        mic?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            NSLog("Toolkit: recording failed: \(writer.error?.localizedDescription ?? "unknown")")
            return false
        }
        if audio != nil, mic != nil { await Self.mixDown(url) }
        return true
    }

    // MARK: - Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, !paused, buffer.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            // Frames where nothing changed come without pixels.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
            else { return }
            guard let shifted = shift(buffer, type) else { return }
            if !started {
                writer.startSession(atSourceTime: shifted.presentationTimeStamp)
                started = true
            }
            if video?.isReadyForMoreMediaData == true { video?.append(shifted) }
        case .audio:
            append(buffer, type, to: audio)
        case .microphone:
            append(buffer, type, to: mic)
        @unknown default:
            break
        }
    }

    private func append(_ buffer: CMSampleBuffer, _ type: SCStreamOutputType, to input: AVAssetWriterInput?) {
        // Sound before the first frame would start the file on a black screen.
        guard started, let input, input.isReadyForMoreMediaData, let shifted = shift(buffer, type) else { return }
        input.append(shifted)
    }

    /// The buffer with the time spent paused taken off, or nil if that would
    /// put it before what was already written.
    private func shift(_ buffer: CMSampleBuffer, _ type: SCStreamOutputType) -> CMSampleBuffer? {
        let time = CMTimeSubtract(buffer.presentationTimeStamp, offset)
        if let previous = last[type], time <= previous { return nil }
        last[type] = time
        guard offset != .zero else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset) }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onInterrupted?(error) }
    }

    // MARK: - Mixdown

    /// System sound and the microphone are written as two tracks, and most
    /// players (browsers, Slack, GitHub) only play the first. This copies the
    /// video as it is and mixes the two into one track.
    static func mixDown(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".mix-\(UUID().uuidString).mp4")
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let videoTrack = videoTracks.first, audioTracks.count > 1 else { return }

            let reader = try AVAssetReader(asset: asset)
            let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(videoOut)
            reader.add(audioOut)

            let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
            let format = try await videoTrack.load(.formatDescriptions).first
            let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            writer.add(videoIn)
            writer.add(audioIn)
            guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? CaptureError.failed }
            writer.startSession(atSourceTime: .zero)

            let group = DispatchGroup()
            for (input, output, label) in [(videoIn, videoOut as AVAssetReaderOutput, "video"), (audioIn, audioOut, "audio")] {
                group.enter()
                let pump = DispatchQueue(label: "dev.jalves.macos-toolkit.mix.\(label)")
                input.requestMediaDataWhenReady(on: pump) {
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        input.append(sample)
                    }
                }
            }
            await withCheckedContinuation { continuation in group.notify(queue: .global()) { continuation.resume() } }
            await writer.finishWriting()
            guard reader.status == .completed, writer.status == .completed else { throw writer.error ?? CaptureError.failed }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            NSLog("Toolkit: audio mixdown failed, keeping two tracks: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
