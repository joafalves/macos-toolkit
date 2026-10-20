import AVFoundation
import AppKit

extension CaptureController {
    /// Runs the capture code without the overlay: the main display, an area,
    /// the frontmost window in each style, and a three-second recording.
    static func selfTest(into folder: URL, app: String? = nil) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = "screen recording permission: \(CGPreflightScreenCaptureAccess()), accessibility: \(AXIsProcessTrusted())\n"
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            var config = CaptureConfig()
            func shoot(_ name: String, _ target: CaptureTarget) async {
                do {
                    let (image, scale) = try await Screenshotter.capture(target, config: config, excluding: [])
                    let data = Screenshotter.encode(image, as: .png, scale: scale)!
                    try data.write(to: folder.appendingPathComponent("\(name).png"))
                    report += "\(name): \(image.width)×\(image.height) @\(scale)x, \(data.count / 1024) KB\n"
                } catch {
                    report += "\(name): FAILED \(error.localizedDescription)\n"
                }
            }
            let main = CGMainDisplayID()
            await shoot("display", .display(main))
            await shoot("area", .area(CGRect(x: 100, y: 100, width: 400, height: 300)))
            let own = ProcessInfo.processInfo.processIdentifier
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            func area(_ info: [String: Any]) -> CGFloat {
                (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }.map { $0.width * $0.height } ?? 0
            }
            let front = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != own }
                .filter { app == nil || ($0[kCGWindowOwnerName as String] as? String) == app }
                .max { area($0) < area($1) }
            if let id = front?[kCGWindowNumber as String] as? CGWindowID {
                report += "window: \(front?[kCGWindowOwnerName as String] ?? "?")\n"
                for style in WindowStyle.allCases {
                    config.windowStyle = style
                    for backdrop in style == .nice ? [Backdrop.wallpaper, .color] : [.wallpaper] {
                        config.backdrop = backdrop
                        await shoot("window-\(style.rawValue)\(style == .nice ? "-\(backdrop.rawValue)" : "")", .window(id))
                    }
                }
            }
            // Paused for the middle second of three, with system audio: about 2 s.
            do {
                let url = folder.appendingPathComponent("rec-paused-audio.mp4")
                try? FileManager.default.removeItem(at: url)
                let recorder = Recorder(url: url)
                try await recorder.start(.display(main), options: .init(frameRate: 15, systemAudio: true), excluding: [])
                try await Task.sleep(nanoseconds: 1_000_000_000)
                recorder.setPaused(true)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                recorder.setPaused(false)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let ok = await recorder.stop()
                let asset = AVURLAsset(url: url)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
                report += "rec-paused-audio: saved=\(ok) \(String(format: "%.1f", duration)) s, \(audio) audio track(s)\n"
            } catch {
                report += "rec-paused-audio: FAILED \(error.localizedDescription)\n"
            }
            for (name, quality) in RecordingQuality.allCases.map({ ("rec-\($0.rawValue)", $0) }) {
                let url = folder.appendingPathComponent("\(name).mp4")
                try? FileManager.default.removeItem(at: url)
                let recorder = Recorder(url: url)
                do {
                    try await recorder.start(.display(main), options: .init(quality: quality, frameRate: 30), excluding: [])
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let ok = await recorder.stop()
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    let asset = AVURLAsset(url: url)
                    let duration = (try? await asset.load(.duration).seconds) ?? 0
                    let track = try? await asset.loadTracks(withMediaType: .video).first
                    let dims = try? await track?.load(.naturalSize)
                    report += "\(name): saved=\(ok) \(size / 1024) KB, \(String(format: "%.1f", duration)) s, \(dims.map { "\(Int($0.width))×\(Int($0.height))" } ?? "?")\n"
                } catch {
                    report += "\(name): FAILED \(error.localizedDescription)\n"
                }
            }
            await mixTest()
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func mixTest() async {
            // Two seconds of grey video and two tone tracks, as a recording with
            // the microphone and system audio would have.
            let url = folder.appendingPathComponent("mix.mp4")
            try? FileManager.default.removeItem(at: url)
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]
                let a1 = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                let a2 = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                // Fed one after the other, so the writer mustn't wait to interleave them.
                [video, a1, a2].forEach { $0.expectsMediaDataInRealTime = true; writer.add($0) }
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                for frame in 0..<20 {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
                    while !video.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                    adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
                }
                for (input, hz) in [(a1, 440.0), (a2, 660.0)] {
                    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
                    for chunk in 0..<20 {
                        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
                        pcm.frameLength = 4800
                        for i in 0..<4800 {
                            let v = Float(sin(2 * .pi * hz * Double(chunk * 4800 + i) / 48000) * 0.3)
                            pcm.floatChannelData![0][i] = v
                            pcm.floatChannelData![1][i] = v
                        }
                        var description: CMAudioFormatDescription?
                        CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
                        var sample: CMSampleBuffer?
                        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: CMTimeValue(chunk * 4800), timescale: 48000), decodeTimeStamp: .invalid)
                        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 4800, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
                        CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList)
                        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                        input.append(sample!)
                    }
                }
                [video, a1, a2].forEach { $0.markAsFinished() }
                await writer.finishWriting()
                let before = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
                await Recorder.mixDown(url)
                let asset = AVURLAsset(url: url)
                let after = try await asset.loadTracks(withMediaType: .audio).count
                let videos = try await asset.loadTracks(withMediaType: .video).count
                let duration = try await asset.load(.duration).seconds
                report += "mixdown: audio tracks \(before) -> \(after), video tracks \(videos), \(String(format: "%.1f", duration)) s\n"
            } catch {
                report += "mixdown: FAILED \(error.localizedDescription)\n"
            }
        }
        try? report.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}

extension CaptureController {
    /// Shows the real toolbar panel in each mode and reports whether it still
    /// fits its content.
    static func toolbarTest() {
        _ = NSApplication.shared
        let capture = CaptureController.preview()
        let toolbar = CaptureToolbar(capture: capture)
        toolbar.show(on: NSScreen.main!)
        for mode in [CaptureMode.area, .window, .screen, .area] {
            capture.config.mode = mode
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let panel = NSApp.windows.first { $0 is CapturePanel && $0.isVisible }
            let host = panel?.contentView?.subviews.first
            print("\(mode): panel \(panel.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "none"), content wants \(host.map { "\(Int($0.fittingSize.width))×\(Int($0.fittingSize.height))" } ?? "?")")
        }
        if let panel = NSApp.windows.first(where: { $0 is CapturePanel && $0.isVisible }) {
            let top = NSWindow.windowNumber(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY), belowWindowWithWindowNumber: 0)
            print("window under the toolbar's centre is the toolbar: \(top == panel.windowNumber)")
        }
        toolbar.hide()
    }
}

extension CaptureController {
    /// Puts the window highlight over the second window from the front and
    /// checks the window server has it directly above that window.
    static func highlightTest() {
        _ = NSApplication.shared
        func normalWindows() -> [[String: Any]] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        }
        let own = ProcessInfo.processInfo.processIdentifier
        let others = normalWindows().filter { ($0[kCGWindowOwnerPID as String] as? pid_t) != own }
        guard others.count > 1, let id = others[1][kCGWindowNumber as String] as? CGWindowID,
              let bounds = others[1][kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { return print("needs two windows on screen") }
        let highlight = WindowHighlight()
        highlight.show(Candidate(id: id, frame: Coordinates.toAppKit(rect), layer: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let order = normalWindows().map { ($0[kCGWindowNumber as String] as? CGWindowID ?? 0, $0[kCGWindowOwnerPID as String] as? pid_t ?? 0) }
        let mine = order.firstIndex { $0.1 == own }
        let target = order.firstIndex { $0.0 == id }
        print("highlight at \(mine.map(String.init) ?? "-"), target at \(target.map(String.init) ?? "-"), directly above: \(mine != nil && target != nil && mine! + 1 == target!)")
        highlight.show(nil)
    }
}

extension CaptureController {
    /// The recording path the menu bar and toolbar use: start an area
    /// recording, check the stop button, then discard it.
    static func recordingTest() {
        _ = NSApplication.shared
        let capture = CaptureController()
        let screen = NSScreen.main!
        let area = CGRect(x: screen.cgFrame.minX + 40, y: screen.cgFrame.minY + 80, width: 320, height: 200)
        capture.startRecording(.area(area), screen: screen)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        print("recording: \(capture.isRecording), elapsed: \(Int(capture.recording?.elapsed ?? 0)) s, size: \(capture.recording?.bytes ?? 0) bytes")
        capture.discardRecording()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        print("after discard: recording \(capture.isRecording)")
    }
}

@_silgen_name("CGSIsSymbolicHotKeyEnabled") private func CGSIsSymbolicHotKeyEnabled(_ id: Int32) -> Bool

extension CaptureController {
    /// Config migration, cleared shortcuts, and which of macOS's screenshot
    /// shortcuts are switched off for a few sets of bindings. Ends on the
    /// default bindings, which is what the running app has.
    static func shortcutTest() {
        _ = NSApplication.shared
        let legacy = try! JSONDecoder().decode(CaptureConfig.self, from: Data(#"{"replaceShortcuts": false}"#.utf8))
        print("legacy replaceShortcuts false -> enabled \(legacy.enabled), area \(legacy.areaShortcut.display)")
        var config = CaptureConfig()
        config.screenShortcut = .none
        let round = try! JSONDecoder().decode(CaptureConfig.self, from: JSONEncoder().encode(config))
        print("cleared screen shortcut after a save: \(round.screenShortcut.display), area still \(round.areaShortcut.display)")

        func states() -> String {
            ([28, 29, 30, 31, 184] as [Int32]).map { "\($0):\(CGSIsSymbolicHotKeyEnabled($0) ? "on" : "off")" }.joined(separator: " ")
        }
        let keys = CaptureKeys()
        var custom = CaptureConfig().bindings
        custom.area = Shortcut(keyCode: 1, flags: [.option, .shift], key: "S")
        keys.start(custom)
        print("area on ⌥⇧S, macOS:  \(states())  (expect 30 and 31 on)")
        custom.screen = nil
        keys.start(custom)
        print("display cleared too:  \(states())  (expect 28-31 on)")
        keys.start(CaptureConfig().bindings)
        print("defaults:             \(states())  (expect all off)")
    }
}

extension SwitcherController {
    /// Takes previews of every normal window, as the grid would, and reports
    /// how long they took. Nothing is kept.
    static func previewTest() {
        _ = NSApplication.shared
        let own = ProcessInfo.processInfo.processIdentifier
        let ids = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != own }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        for width in [520, 1240] {
            let previews = SwitcherPreviews()
            var times: [Double] = []
            // As the switcher does: the list asked for at ⌘Tab, pictures 150 ms later.
            previews.prepare()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let start = Date()
            previews.onUpdate = { _, _ in times.append(Date().timeIntervalSince(start)) }
            previews.refresh(ids, width: width)
            while times.count < ids.count, Date().timeIntervalSince(start) < 5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let ms = { (t: Double) in Int(t * 1000) }
            print("\(width) px: \(times.count) of \(ids.count) windows; first \(times.first.map(ms) ?? -1) ms, half \(times.count > 1 ? ms(times[times.count / 2]) : -1) ms, all \(times.last.map(ms) ?? -1) ms")
        }
    }
}
