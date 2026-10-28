import AppKit
import os
import Vision

/// The text in a capture, or what a QR code or barcode in it holds, read on
/// this Mac by Vision.
enum TextReader {
    /// The reading under way, so switching the setting off can end it.
    private static let running = Locked<Process?>(nil)

    /// Nil when there's nothing to copy, or the reading was stopped. Vision
    /// keeps its model in the process that used it, some 35 MB that never
    /// goes, so a copy of the app does the reading and quits (`serve`).
    static func read(_ image: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) { readElsewhere(image) }.value
    }

    /// Ends the reading under way, if any.
    static func cancel() {
        running.value?.terminate()
    }

    /// The first reading by a new build of the app waits some 25 seconds
    /// while macOS readies the recognition for it (`ANECompilerService`, a
    /// core at full use). Done here, once per build, in the background, so
    /// ⇧⌘2 doesn't wait. The build is the executable's date: an update or a
    /// rebuild changes it.
    static func prepare() {
        guard !preparing.value, let build = buildStamp, UserDefaults.standard.string(forKey: preparedKey) != build else { return }
        preparing.value = true
        Task.detached(priority: .utility) {
            defer { preparing.value = false }
            guard let image = sample() else { return }
            let start = Date()
            // Nil when it was stopped; a word is there to read otherwise.
            guard readElsewhere(image) != nil else { return }
            Log.capture.notice("text reader ready for this build in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            UserDefaults.standard.set(build, forKey: preparedKey)
        }
    }

    private static let preparing = Locked(false)
    private static let preparedKey = "textReaderPrepared"

    private static var buildStamp: String? {
        guard let url = Bundle.main.executableURL,
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return "\(url.path) \(date.timeIntervalSince1970)"
    }

    /// A word to read: an empty image may never reach the recognizer.
    private static func sample() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 240, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 64))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Ready", attributes: [
            .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black,
        ]))
        ctx.textPosition = CGPoint(x: 16, y: 18)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    private static func readElsewhere(_ image: CGImage) -> String? {
        guard let executable = Bundle.main.executableURL, let pixels = pixels(of: image) else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--read-text"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A helper that ends early would otherwise end us too, as we write.
        signal(SIGPIPE, SIG_IGN)
        do {
            try process.run()
        } catch {
            Log.capture.error("text reader did not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        running.value = process
        defer { running.update { if $0 === process { $0 = nil } } }
        // It reads all of this before it writes anything, so one after the
        // other can't get stuck.
        try? input.fileHandleForWriting.write(contentsOf: pixels)
        try? input.fileHandleForWriting.close()
        let result = (try? output.fileHandleForReading.readToEnd()) ?? nil
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0, let result, !result.isEmpty else { return nil }
        return String(decoding: result, as: UTF8.self)
    }

    /// Width and height, then the pixels as 8-bit BGRA, for `serve`.
    private static func pixels(of image: CGImage) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = Data(count: 8 + width * height * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            raw.storeBytes(of: UInt32(width).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(height).littleEndian, toByteOffset: 4, as: UInt32.self)
            guard let ctx = CGContext(data: raw.baseAddress! + 8, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: Self.bitmapInfo)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// The copy of the app started with `--read-text`: an image on standard
    /// input, its text on standard output, then it quits.
    static func serve() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard input.count >= 8 else { exit(1) }
        let width = Int(UInt32(littleEndian: input.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }))
        let height = Int(UInt32(littleEndian: input.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }))
        guard width > 0, height > 0, input.count == 8 + width * height * 4,
              let provider = CGDataProvider(data: input.subdata(in: 8..<input.count) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { exit(1) }
        if let text = readNow(image) { FileHandle.standardOutput.write(Data(text.utf8)) }
        exit(0)
    }

    static func readNow(_ image: CGImage) -> String? {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, codes])
        } catch {
            Log.capture.error("text recognition failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let lines: [Line] = (text.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), !best.isEmpty
            else { return nil }
            return Line(text: best, box: VNImageRectForNormalizedRect(observation.boundingBox, image.width, image.height))
        }
        let found = (codes.results ?? []).filter { $0.payloadStringValue?.isEmpty == false }
        // A code that fills much of the area is what it was taken for; a small
        // one beside a page of text is only part of it.
        let large = found.filter { $0.boundingBox.width * $0.boundingBox.height >= 0.2 }
        if let picked = lines.isEmpty ? found.nilIfEmpty : large.nilIfEmpty {
            var seen = Set<String>()
            return picked.compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }.joined(separator: "\n")
        }
        return lines.isEmpty ? nil : join(lines)
    }

    struct Line {
        let text: String
        /// In pixels, origin at the bottom left, as Vision has it.
        let box: CGRect
    }

    /// A line of the result: the pieces side by side on the screen.
    struct Row {
        let text: String
        let box: CGRect
        let pieces: Int
    }

    /// Top to bottom, as rows: pieces side by side are one line, with a tab
    /// where a wide gap splits them (columns, a table), and a blank line goes
    /// where the gap above is more than a line's height. Within a paragraph,
    /// a line that only wraps because it ran out of room joins the one before,
    /// so a sentence comes out whole however wide it was on the screen.
    static func join(_ lines: [Line]) -> String {
        let height = lines.map(\.box.height).sorted()[lines.count / 2]
        var grouped: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = grouped.last?.last, abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) / 2 {
                grouped[grouped.count - 1].append(line)
            } else {
                grouped.append([line])
            }
        }
        let rows = grouped.map { group -> Row in
            let pieces = group.sorted { $0.box.minX < $1.box.minX }
            var text = ""
            for (i, piece) in pieces.enumerated() {
                if i > 0 { text += piece.box.minX - pieces[i - 1].box.maxX > height * 1.5 ? "\t" : " " }
                text += piece.text
            }
            return Row(text: text, box: pieces.map(\.box).reduce(CGRect.null) { $0.union($1) }, pieces: pieces.count)
        }
        var paragraphs: [[Row]] = []
        for row in rows {
            if let above = paragraphs.last?.last, above.box.minY - row.box.maxY <= height {
                paragraphs[paragraphs.count - 1].append(row)
            } else {
                paragraphs.append([row])
            }
        }
        return paragraphs.map { paragraph in
            // How far its lines reach, and whether it's a column of prose,
            // where a wrapped line can start a sentence too.
            let right = paragraph.map(\.box.maxX).max() ?? 0
            let prose = paragraph.count >= 3 && (paragraph.map(\.box.width).max() ?? 0) >= height * 15
            var out = ""
            for (i, row) in paragraph.enumerated() {
                if i > 0 {
                    switch wrap(from: paragraph[i - 1], to: row, right: right, prose: prose, height: height) {
                    case .hyphen: out.removeLast()
                    case .space: out += " "
                    case .newLine: out += "\n"
                    }
                }
                out += row.text
            }
            return out
        }.joined(separator: "\n\n")
    }

    enum Wrap { case newLine, space, hyphen }

    /// Its first word and a space, as a share of the row's width: Vision
    /// gives boxes for whole lines.
    private static func firstWordWidth(_ row: Row) -> CGFloat {
        let word = row.text.prefix { !$0.isWhitespace }.count + 1
        return row.box.width * CGFloat(word) / CGFloat(max(row.text.count, 1))
    }

    /// Whether `below` carries on the line above, which ran out of room: the
    /// two line up (on the left, or centred), the same size of type, the first
    /// word below wouldn't have fit at the end of the line above, and it goes
    /// on with the sentence. Lists, columns and lines of code keep their
    /// breaks.
    static func wrap(from above: Row, to below: Row, right: CGFloat, prose: Bool, height: CGFloat) -> Wrap {
        guard above.pieces == 1, below.pieces == 1,
              abs(above.box.minX - below.box.minX) < height * 0.6 || abs(above.box.midX - below.box.midX) < height * 0.6,
              abs(above.box.height - below.box.height) < max(above.box.height, below.box.height) * 0.25,
              let last = above.text.last, let first = below.text.first,
              above.box.maxX + firstWordWidth(below) >= right - height * 0.5,
              !";{}()[]:=".contains(last),
              below.text.range(of: #"^([•·▪◦‣*–—-]|\d{1,3}[.)]|[a-zA-Z][.)])\s"#, options: .regularExpression) == nil
        else { return .newLine }
        if last == "-", above.text.dropLast().last?.isLetter == true, first.isLowercase { return .hyphen }
        return first.isLowercase || prose ? .space : .newLine
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
