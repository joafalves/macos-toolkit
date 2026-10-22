import AppKit
import Carbon.HIToolbox

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

/// How sharp a recording is, against how big the file gets.
enum RecordingQuality: String, Codable, CaseIterable {
    /// Point size, modest bitrate: fine for clicking through a UI.
    case standard
    /// Every pixel, and enough bits that small text survives scrolling.
    case high
    /// Every pixel, and bits to spare, for code and tutorials.
    case maximum

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    var nativeResolution: Bool { self != .standard }

    /// Bits per pixel per frame, before the frame-rate curve in `Recorder.bitRate`.
    var bitsPerPixel: Double {
        switch self {
        case .standard: return 0.1
        case .high: return 0.25
        case .maximum: return 0.5
        }
    }

    var maxBitRate: Double {
        switch self {
        case .standard: return 16_000_000
        case .high: return 30_000_000
        case .maximum: return 60_000_000
        }
    }
}

enum ImageFormat: String, Codable, CaseIterable {
    case png, jpeg, heic

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

struct CaptureConfig: Codable, Equatable {
    /// When off, the tool is gone: no shortcuts, no menu entry, and macOS's own
    /// screenshot keys work again.
    var enabled = true
    /// `Shortcut.none` for no shortcut. ⌃ added to the display and area ones
    /// copies instead of saving.
    var screenShortcut = Self.defaultScreenShortcut
    var areaShortcut = Self.defaultAreaShortcut
    var toolbarShortcut = Self.defaultToolbarShortcut
    static let defaultScreenShortcut = Shortcut(keyCode: kVK_ANSI_3, flags: [.shift, .command])
    static let defaultAreaShortcut = Shortcut(keyCode: kVK_ANSI_4, flags: [.shift, .command])
    static let defaultToolbarShortcut = Shortcut(keyCode: kVK_ANSI_5, flags: [.shift, .command])
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
    /// Empty means ~/Pictures/Capture.
    var screenshotFolder = ""

    // Recordings
    var quality = RecordingQuality.standard
    var frameRate = 30
    var showCursor = true
    var showClicks = false
    var systemAudio = false
    var microphone = false
    /// An AVCaptureDevice unique ID. Empty means the default input.
    var microphoneID = ""
    /// Empty means ~/Movies/Capture.
    var recordingFolder = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        // Called replaceShortcuts before the tool had its own on/off.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .replaceShortcuts) ?? true
        screenShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .screenShortcut)) ?? Self.defaultScreenShortcut
        areaShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .areaShortcut)) ?? Self.defaultAreaShortcut
        toolbarShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .toolbarShortcut)) ?? Self.defaultToolbarShortcut
        standaloneIcon = try c.decodeIfPresent(Bool.self, forKey: .standaloneIcon) ?? false
        mode = (try? c.decodeIfPresent(CaptureMode.self, forKey: .mode)) ?? .area
        kind = (try? c.decodeIfPresent(CaptureKind.self, forKey: .kind)) ?? .photo
        timer = try c.decodeIfPresent(Int.self, forKey: .timer) ?? 0
        lastArea = try? c.decodeIfPresent(CGRect.self, forKey: .lastArea)
        windowStyle = (try? c.decodeIfPresent(WindowStyle.self, forKey: .windowStyle)) ?? .plain
        backdrop = (try? c.decodeIfPresent(Backdrop.self, forKey: .backdrop)) ?? .wallpaper
        backdropColor = try c.decodeIfPresent(String.self, forKey: .backdropColor) ?? "#5B7FD6"
        // Within what the settings offer: a file edited by hand can say
        // anything, and these become pixel sizes and a time scale.
        padding = min(max(try c.decodeIfPresent(Double.self, forKey: .padding) ?? 48, 0), 120)
        shadow = min(max(try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0.6, 0), 1)
        format = (try? c.decodeIfPresent(ImageFormat.self, forKey: .format)) ?? .png
        saveWhenCopying = try c.decodeIfPresent(Bool.self, forKey: .saveWhenCopying) ?? false
        shutterSound = try c.decodeIfPresent(Bool.self, forKey: .shutterSound) ?? true
        screenshotFolder = try c.decodeIfPresent(String.self, forKey: .screenshotFolder) ?? ""
        // Before quality, there was only a native resolution switch.
        let native = try legacy.decodeIfPresent(Bool.self, forKey: .nativeResolution) ?? false
        quality = (try? c.decodeIfPresent(RecordingQuality.self, forKey: .quality)) ?? (native ? .high : .standard)
        let rate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 30
        frameRate = [15, 30, 60].contains(rate) ? rate : 30
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? true
        showClicks = try c.decodeIfPresent(Bool.self, forKey: .showClicks) ?? false
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? false
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        microphoneID = try c.decodeIfPresent(String.self, forKey: .microphoneID) ?? ""
        recordingFolder = try c.decodeIfPresent(String.self, forKey: .recordingFolder) ?? ""
    }

    static let defaultScreenshotDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Capture")
    static let defaultRecordingDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Capture")

    private enum LegacyKeys: String, CodingKey {
        case replaceShortcuts, nativeResolution
    }

    /// The shortcuts in use, for `CaptureKeys`.
    var bindings: CaptureKeys.Bindings {
        CaptureKeys.Bindings(screen: screenShortcut.active, area: areaShortcut.active, toolbar: toolbarShortcut.active)
    }

    var screenshotDirectory: URL {
        screenshotFolder.isEmpty ? Self.defaultScreenshotDirectory : URL(fileURLWithPath: screenshotFolder)
    }

    var recordingDirectory: URL {
        recordingFolder.isEmpty ? Self.defaultRecordingDirectory : URL(fileURLWithPath: recordingFolder)
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
