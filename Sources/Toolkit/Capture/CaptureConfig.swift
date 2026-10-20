import AppKit

/// What a capture covers.
enum CaptureMode: String, Codable, CaseIterable {
    case screen, window, area
}

enum CaptureKind: String, Codable {
    case photo, video
}

/// How a window screenshot is framed.
enum WindowStyle: String, Codable, CaseIterable {
    /// The window without its title bar and toolbar.
    case content
    /// The window as it is, without the shadow.
    case plain
    /// The window with a shadow, on a backdrop.
    case nice
}

enum Backdrop: String, Codable {
    /// A blurred piece of the desktop picture behind the window.
    case wallpaper
    case color
}

enum ImageFormat: String, Codable, CaseIterable {
    case png, jpeg, heic

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

struct CaptureConfig: Codable, Equatable {
    /// When on, ⇧⌘3, ⇧⌘4 and ⇧⌘5 (and their ⌃ versions) come here instead of
    /// to macOS.
    var replaceShortcuts = true
    /// Gives Screen Capture an icon of its own in the menu bar.
    var standaloneIcon = false

    // The toolbar's choices, kept as last picked.
    var mode = CaptureMode.area
    var kind = CaptureKind.photo
    /// Seconds before a capture from the toolbar starts: 0, 3, 5 or 10.
    var timer = 0
    /// The area the toolbar opens with, in global screen points (origin at the
    /// top left of the main display, as Core Graphics has it).
    var lastArea: CGRect?

    // Screenshots
    var windowStyle = WindowStyle.plain
    var backdrop = Backdrop.wallpaper
    /// "#RRGGBB", for the solid backdrop.
    var backdropColor = "#5B7FD6"
    /// Points of backdrop around the window.
    var padding = 48.0
    /// 0 to 1.
    var shadow = 0.6
    var format = ImageFormat.png
    /// ⌃ puts the screenshot on the clipboard; this also saves it to a file.
    var saveWhenCopying = false
    var shutterSound = true
    /// Empty means the Desktop.
    var screenshotFolder = ""

    // Recordings
    /// Records at the display's pixel size rather than its point size.
    var nativeResolution = false
    var frameRate = 30
    var showCursor = true
    var showClicks = false
    var systemAudio = false
    var microphone = false
    /// An AVCaptureDevice unique ID. Empty means the default input.
    var microphoneID = ""
    /// Empty means ~/Movies.
    var recordingFolder = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        replaceShortcuts = try c.decodeIfPresent(Bool.self, forKey: .replaceShortcuts) ?? true
        standaloneIcon = try c.decodeIfPresent(Bool.self, forKey: .standaloneIcon) ?? false
        mode = (try? c.decodeIfPresent(CaptureMode.self, forKey: .mode)) ?? .area
        kind = (try? c.decodeIfPresent(CaptureKind.self, forKey: .kind)) ?? .photo
        timer = try c.decodeIfPresent(Int.self, forKey: .timer) ?? 0
        lastArea = try? c.decodeIfPresent(CGRect.self, forKey: .lastArea)
        windowStyle = (try? c.decodeIfPresent(WindowStyle.self, forKey: .windowStyle)) ?? .plain
        backdrop = (try? c.decodeIfPresent(Backdrop.self, forKey: .backdrop)) ?? .wallpaper
        backdropColor = try c.decodeIfPresent(String.self, forKey: .backdropColor) ?? "#5B7FD6"
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 48
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0.6
        format = (try? c.decodeIfPresent(ImageFormat.self, forKey: .format)) ?? .png
        saveWhenCopying = try c.decodeIfPresent(Bool.self, forKey: .saveWhenCopying) ?? false
        shutterSound = try c.decodeIfPresent(Bool.self, forKey: .shutterSound) ?? true
        screenshotFolder = try c.decodeIfPresent(String.self, forKey: .screenshotFolder) ?? ""
        nativeResolution = try c.decodeIfPresent(Bool.self, forKey: .nativeResolution) ?? false
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 30
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? true
        showClicks = try c.decodeIfPresent(Bool.self, forKey: .showClicks) ?? false
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? false
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        microphoneID = try c.decodeIfPresent(String.self, forKey: .microphoneID) ?? ""
        recordingFolder = try c.decodeIfPresent(String.self, forKey: .recordingFolder) ?? ""
    }

    var screenshotDirectory: URL {
        screenshotFolder.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            : URL(fileURLWithPath: screenshotFolder)
    }

    var recordingDirectory: URL {
        recordingFolder.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
            : URL(fileURLWithPath: recordingFolder)
    }

    var backdropNSColor: NSColor {
        NSColor(hex: backdropColor) ?? NSColor(red: 0.36, green: 0.5, blue: 0.84, alpha: 1)
    }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("capture.json")
    }

    static func load() -> CaptureConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return CaptureConfig() }
        return (try? JSONDecoder().decode(CaptureConfig.self, from: data)) ?? CaptureConfig()
    }

    func save() {
        let url = CaptureConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
