import AppKit
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

/// What to capture. Rects are in global screen points with the origin at the
/// top left of the main display, the way Core Graphics and ScreenCaptureKit
/// have them.
enum CaptureTarget {
    case display(CGDirectDisplayID)
    case area(CGRect)
    case window(CGWindowID)
}

enum CaptureError: LocalizedError {
    case notFound
    case failed

    var errorDescription: String? {
        switch self {
        case .notFound: return "The window or display is no longer there."
        case .failed: return "The capture did not produce an image."
        }
    }
}

/// Lookups shared by screenshots and recordings.
enum CaptureContent {
    static func current() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// The display a rect is mostly on.
    static func display(for rect: CGRect, in content: SCShareableContent) -> SCDisplay? {
        content.displays.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
    }

    static func scale(of displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2
    }

    /// Our own windows to leave out (the overlay, the toolbar, thumbnails),
    /// and with `menuBar`, our menu bar items too.
    static func windows(_ ids: Set<CGWindowID>, in content: SCShareableContent, menuBar: Bool = false) -> [SCWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return content.windows.filter {
            ids.contains($0.windowID) || (menuBar && $0.owningApplication?.processID == own && $0.windowLayer == statusLevel)
        }
    }
}

enum Screenshotter {
    static func capture(_ target: CaptureTarget, config: CaptureConfig, excluding: Set<CGWindowID>) async throws -> (CGImage, CGFloat) {
        let content = try await CaptureContent.current()
        let shot = SCStreamConfiguration()
        shot.showsCursor = false
        shot.captureResolution = .best
        shot.colorSpaceName = CGColorSpace.sRGB
        shot.pixelFormat = kCVPixelFormatType_32BGRA

        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.notFound }
            let scale = CaptureContent.scale(of: id)
            let filter = SCContentFilter(display: display, excludingWindows: CaptureContent.windows(excluding, in: content))
            shot.width = Int(CGFloat(display.width) * scale)
            shot.height = Int(CGFloat(display.height) * scale)
            return (try await image(filter, shot), scale)

        case .area(let rect):
            guard let display = CaptureContent.display(for: rect, in: content) else { throw CaptureError.notFound }
            let area = rect.intersection(display.frame).integral
            guard !area.isEmpty else { throw CaptureError.notFound }
            let scale = CaptureContent.scale(of: display.displayID)
            let filter = SCContentFilter(display: display, excludingWindows: CaptureContent.windows(excluding, in: content))
            shot.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            shot.width = Int(area.width * scale)
            shot.height = Int(area.height * scale)
            return (try await image(filter, shot), scale)

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.notFound }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            shot.ignoreShadowsSingleWindow = true
            shot.shouldBeOpaque = false
            shot.width = Int(filter.contentRect.width * scale)
            shot.height = Int(filter.contentRect.height * scale)
            let captured = try await image(filter, shot)
            switch config.windowStyle {
            case .plain:
                return (captured, scale)
            case .content:
                let inset = WindowChrome.topInset(of: window)
                return (crop(captured, top: Int(inset * scale)), scale)
            case .nice:
                var wallpaper: CGImage?
                if config.backdrop == .wallpaper {
                    wallpaper = try? await self.wallpaper(behind: window.frame.insetBy(dx: -config.padding, dy: -config.padding), in: content, scale: scale)
                }
                return (decorate(captured, scale: scale, config: config, wallpaper: wallpaper), scale)
            }
        }
    }

    private static func image(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? CaptureError.failed) }
            }
        }
    }

    private static func crop(_ image: CGImage, top: Int) -> CGImage {
        guard top > 0, top < image.height else { return image }
        return image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: image.height - top)) ?? image
    }

    /// The desktop picture under a rect, without windows or desktop icons.
    private static func wallpaper(behind rect: CGRect, in content: SCShareableContent, scale: CGFloat) async throws -> CGImage? {
        guard let display = CaptureContent.display(for: rect, in: content) else { return nil }
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let walls = content.windows.filter {
            $0.windowLayer <= desktopLevel && $0.owningApplication?.bundleIdentifier != "com.apple.finder"
        }
        guard !walls.isEmpty else { return nil }
        let area = rect.intersection(display.frame)
        guard !area.isEmpty else { return nil }
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        // Blurred anyway, so a quarter of the pixels is plenty.
        config.width = Int(area.width * scale / 2)
        config.height = Int(area.height * scale / 2)
        return try await image(SCContentFilter(display: display, including: walls), config)
    }

    /// The window on padding filled with the backdrop, with a soft shadow.
    static func decorate(_ window: CGImage, scale: CGFloat, config: CaptureConfig, wallpaper: CGImage?) -> CGImage {
        let pad = CGFloat(config.padding) * scale
        let size = CGSize(width: CGFloat(window.width) + pad * 2, height: CGFloat(window.height) + pad * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return window }
        let canvas = CGRect(origin: .zero, size: size)
        if let wallpaper, let blurred = blur(wallpaper, to: size) {
            ctx.draw(blurred, in: canvas)
        } else {
            ctx.setFillColor(config.backdropNSColor.cgColor)
            ctx.fill(canvas)
        }
        let strength = CGFloat(config.shadow)
        if strength > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale * strength), blur: 40 * scale * strength,
                          color: NSColor.black.withAlphaComponent(0.25 + 0.35 * strength).cgColor)
        }
        ctx.draw(window, in: CGRect(x: pad, y: pad, width: CGFloat(window.width), height: CGFloat(window.height)))
        return ctx.makeImage() ?? window
    }

    private static func blur(_ image: CGImage, to size: CGSize) -> CGImage? {
        let input = CIImage(cgImage: image)
        let fill = max(size.width / input.extent.width, size.height / input.extent.height)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let blurred = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(min(size.width, size.height)) / 25)
            .cropped(to: CGRect(x: (scaled.extent.width - size.width) / 2, y: (scaled.extent.height - size.height) / 2,
                                width: size.width, height: size.height))
        return CIContext().createCGImage(blurred, from: blurred.extent)
    }

    // MARK: - Files

    /// PNG for the clipboard, the configured format for files. Tagged with the
    /// display's density so it opens at its real size.
    static func encode(_ image: CGImage, as format: ImageFormat, scale: CGFloat) -> Data? {
        let type: UTType = format == .png ? .png : format == .jpeg ? .jpeg : .heic
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format != .png { properties[kCGImageDestinationLossyCompressionQuality] = 0.85 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Where a window's title bar and toolbar end, from Accessibility.
enum WindowChrome {
    static func topInset(of window: SCWindow) -> CGFloat {
        guard let pid = window.owningApplication?.processID,
              let element = axWindow(pid: pid, id: window.windowID)
        else { return 0 }
        var inset: CGFloat = 0
        // The traffic lights sit in the middle of the title bar, or of the
        // toolbar when the two are one.
        if let close = attribute(element, kAXCloseButtonAttribute).map({ $0 as! AXUIElement }), let frame = frame(of: close) {
            inset = (frame.midY - window.frame.minY) * 2
        }
        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children where (attribute(child, kAXRoleAttribute) as? String) == kAXToolbarRole {
                if let frame = frame(of: child) { inset = max(inset, frame.maxY - window.frame.minY) }
            }
        }
        return inset > 0 && inset < window.frame.height / 2 ? inset : 0
    }

    private static func axWindow(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return windows.first { element in
            var windowID: CGWindowID = 0
            _AXUIElementGetWindow(element, &windowID)
            return windowID == id
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

extension NSWindow {
    /// The window server's ID, when the number is one: a window that hasn't
    /// been on screen yet has a negative number, and menu bar items have
    /// numbers too big to be IDs.
    var windowID: CGWindowID? {
        windowNumber > 0 ? CGWindowID(exactly: windowNumber) : nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The frame in Core Graphics coordinates: origin at the top left of the
    /// main display, y going down.
    var cgFrame: CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// Between AppKit's bottom-left global coordinates and Core Graphics' top-left ones.
enum Coordinates {
    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toCG(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toAppKit(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
