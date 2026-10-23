import AVFoundation
import ScreenCaptureKit
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
    /// `--test-overlay`: what the selection overlay costs in memory while it's
    /// up, with an area picked, on every display.
    static func overlayTest(picture: String? = nil) {
        _ = NSApplication.shared
        let overlay = SelectionOverlay()
        let before = processFootprint()
        let main = NSScreen.screens[0].frame
        overlay.show(mode: .area, quick: false, area: NSRect(x: main.midX - 300, y: main.midY - 200, width: 600, height: 400))
        // As in use: the area moves a little, so every display draws again.
        for step in 0..<6 {
            overlay.selection = NSRect(x: main.midX - 300 + CGFloat(step * 10), y: main.midY - 200, width: 600, height: 400)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        let during = processFootprint()
        // A picture of the main display's overlay window alone, to look at.
        if let picture, let id = overlay.windowNumbers.first(where: { id in
            (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first
                .flatMap { $0[kCGWindowBounds as String] as? NSDictionary }
                .flatMap { CGRect(dictionaryRepresentation: $0) }?.origin == .zero
        }) {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                defer { done.signal() }
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let window = content.windows.first(where: { $0.windowID == id }) else { return }
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width) * 2
                config.height = Int(window.frame.height) * 2
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config),
                      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: picture) as CFURL, "public.png" as CFString, 1, nil)
                else { return }
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        overlay.hide()
        print(String(format: "overlay on %d display(s): %.1f MB while it's up", NSScreen.screens.count, Double(during - before) / 1_048_576))
    }

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

extension CaptureController {
    /// Draws text and codes the way a display shows them and reads them back,
    /// printing what came out beside what went in.
    static func textTest() {
        _ = NSApplication.shared
        func draw(_ size: NSSize, _ body: (CGContext) -> Void) -> CGImage? {
            let scale: CGFloat = 2
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            body(ctx)
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
        func text(_ lines: [(String, CGFloat, CGFloat)], size: NSSize, font: NSFont = .systemFont(ofSize: 13)) -> CGImage? {
            draw(size) { _ in
                for (string, x, top) in lines {
                    (string as NSString).draw(at: NSPoint(x: x, y: size.height - top), withAttributes: [.font: font, .foregroundColor: NSColor.black])
                }
            }
        }
        func qr(_ payload: String, beside caption: String?) -> CGImage? {
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
            filter.setValue(Data(payload.utf8), forKey: "inputMessage")
            guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                  let image = CIContext().createCGImage(code, from: code.extent)
            else { return nil }
            return draw(NSSize(width: 420, height: 260)) { ctx in
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 20, y: 20, width: 220, height: 220))
                if let caption {
                    (caption as NSString).draw(at: NSPoint(x: 260, y: 130), withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
                }
            }
        }
        let cases: [(String, CGImage?, String)] = [
            ("one line", text([("The quick brown fox jumps over the lazy dog.", 12, 30)], size: NSSize(width: 360, height: 44)),
             "The quick brown fox jumps over the lazy dog."),
            ("paragraphs", text([("First paragraph, first line,", 12, 26), ("and its second line.", 12, 44),
                                 ("A second paragraph after a gap.", 12, 84)], size: NSSize(width: 320, height: 100)),
             "First paragraph, first line, and its second line.\n\nA second paragraph after a gap."),
            // As text wraps: each line stops where the next word wouldn't fit.
            ("wrapped prose", text([("The window can be snapped to a half of the display, and the", 12, 26),
                                    ("rest of it offers the other windows on the display.", 12, 44),
                                    ("Everything after that goes on, to the end.", 12, 62)], size: NSSize(width: 460, height: 76)),
             "The window can be snapped to a half of the display, and the rest of it offers the other windows on the display. Everything after that goes on, to the end."),
            ("sentence on a new line", text([("The first sentence ends right at the edge.", 12, 26), ("Another one follows below.", 12, 44)],
                                            size: NSSize(width: 340, height: 60)),
             "The first sentence ends right at the edge.\nAnother one follows below."),
            ("hyphen", text([("Recordings are written as soon as some-", 12, 26), ("thing on the screen changes.", 12, 44)], size: NSSize(width: 320, height: 60)),
             "Recordings are written as soon as something on the screen changes."),
            ("list", text([("• Open the toolbar with the shortcut", 12, 26), ("• then pick an area to capture", 12, 44),
                           ("- and press the button", 12, 62)], size: NSSize(width: 320, height: 76)),
             "• Open the toolbar with the shortcut\n• then pick an area to capture\n- and press the button"),
            ("address", text([("Rua das Flores, 12", 12, 26), ("Lisboa", 12, 44)], size: NSSize(width: 200, height: 60)),
             "Rua das Flores, 12\nLisboa"),
            ("short labels", text([("Name: report", 12, 26), ("Kind: document", 12, 44), ("Size: 2 MB", 12, 62)], size: NSSize(width: 200, height: 76)),
             "Name: report\nKind: document\nSize: 2 MB"),
            ("columns", text([("Name", 12, 26), ("Size", 220, 26), ("report.pdf", 12, 46), ("2.4 MB", 220, 46)], size: NSSize(width: 300, height: 60)),
             "Name\tSize\nreport.pdf\t2.4 MB"),
            // Every recognizer macOS has, Live Text's too, reads "possível"
            // at this size as "possivel".
            ("Portuguese", text([("Não foi possível abrir a aplicação.", 12, 30)], size: NSSize(width: 340, height: 44)),
             "Não foi possivel abrir a aplicação."),
            ("code", text([("let total = items.reduce(0, +)", 12, 26), ("print(\"Total: \\(total)\")", 12, 44)],
                          size: NSSize(width: 320, height: 60), font: .monospacedSystemFont(ofSize: 12, weight: .regular)),
             "let total = items.reduce(0, +)\nprint(\"Total: \\(total)\")"),
            ("QR code", qr("https://example.com/qr-test", beside: nil), "https://example.com/qr-test"),
            ("QR with a caption", qr("https://example.com/qr-test", beside: "Scan to open"), "https://example.com/qr-test"),
            ("nothing", draw(NSSize(width: 200, height: 100)) { _ in }, "(none)"),
        ]
        // The app's own path: a copy of it reads and quits, and our memory
        // stays where it was. Then one switched off as it reads.
        if let image = cases[2].1 {
            let mb = { Double(processFootprint()) / 1_048_576 }
            let before = mb()
            for i in 1...3 {
                let start = Date()
                let got = runAsync { await TextReader.read(image) }
                print("\(got == cases[2].2 ? "ok  " : "DIFF") through a helper, read \(i): \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            }
            print(String(format: "memory here: %.0f MB before, %.0f MB after", before, mb()))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { TextReader.cancel() }
            let start = Date()
            let stopped = runAsync { await TextReader.read(image) }
            print("\(stopped == nil ? "ok  " : "DIFF") stopped while reading: \(stopped == nil ? "nothing" : "text") after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
        for (name, image, expected) in cases {
            guard let image else { print("\(name): could not draw"); continue }
            let start = Date()
            let got = TextReader.readNow(image) ?? "(none)"
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("\(got == expected ? "ok  " : "DIFF") \(name) (\(image.width)×\(image.height), \(ms) ms)")
            if got != expected { print("     expected: \(expected.debugDescription)\n     got:      \(got.debugDescription)") }
        }
    }
}

/// Waits for an async call from synchronous test code.
private func runAsync<T>(_ body: @escaping () async -> T) -> T {
    let done = DispatchSemaphore(value: 0)
    let result = Locked<T?>(nil)
    Task.detached {
        result.value = await body()
        done.signal()
    }
    done.wait()
    return result.value!
}
