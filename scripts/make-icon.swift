// Renders Resources/AppIcon.icns. Run from the repo root:
//   swift scripts/make-icon.swift
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // Standard macOS icon grid: an 824pt rounded tile inside a 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
    drop.shadowBlurRadius = 24
    drop.shadowOffset = NSSize(width: 0, height: -10)
    drop.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.42, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.16, blue: 0.22, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // Soft highlight along the top edge.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
        .applying(.init(paletteColors: [NSColor(srgbRed: 1.0, green: 0.78, blue: 0.3, alpha: 1)]))
    if let glyph = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let fit = min(520 / glyph.size.width, 520 / glyph.size.height)
        let size = NSSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
        let rect = NSRect(x: 512 - size.width / 2, y: 512 - size.height / 2, width: size.width, height: size.height)
        let glow = NSShadow()
        glow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        glow.shadowBlurRadius = 18
        glow.shadowOffset = NSSize(width: 0, height: -8)
        glow.set()
        glyph.draw(in: rect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try render(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
