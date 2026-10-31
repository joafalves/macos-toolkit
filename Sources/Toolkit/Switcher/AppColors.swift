import AppKit
import SwiftUI

/// An app's flat colour: a hue, in one of two tones. Everything else is fixed,
/// so all colours have the same weight and none looks more important. The
/// second tone is what makes room once the hues run out.
struct AppColor: Codable, Equatable {
    var hue: Double
    var deep: Bool
}

/// The colours, worked out in OKLCH, where a distance looks like the same
/// difference whatever the hue. A row's colour is quiet; the selected row's,
/// with white on it, is the same hue, stronger.
enum AppPalette {
    private struct Tone {
        let l: Double, c: Double
    }

    private static func rowTone(_ deep: Bool, dark: Bool) -> Tone {
        dark ? Tone(l: deep ? 0.27 : 0.35, c: deep ? 0.06 : 0.065)
             : Tone(l: deep ? 0.85 : 0.905, c: 0.05)
    }

    private static func strongTone(_ deep: Bool, dark: Bool) -> Tone {
        dark ? Tone(l: deep ? 0.47 : 0.56, c: 0.115)
             : Tone(l: deep ? 0.44 : 0.52, c: 0.115)
    }

    private static func dynamic(_ color: AppColor, _ tone: (Bool, Bool) -> Tone) -> Color {
        let (light, dark) = (tone(color.deep, false), tone(color.deep, true))
        let lightColor = oklch(light.l, light.c, color.hue), darkColor = oklch(dark.l, dark.c, color.hue)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    static func row(_ color: AppColor) -> Color { dynamic(color) { rowTone($0, dark: $1) } }
    static func selected(_ color: AppColor) -> Color { dynamic(color) { strongTone($0, dark: $1) } }

    /// How different two colours look on their rows: the distance between them
    /// in OKLab, in whichever appearance has them closer.
    static func difference(_ x: AppColor, _ y: AppColor) -> Double {
        func distance(dark: Bool) -> Double {
            let (a, b) = (rowTone(x.deep, dark: dark), rowTone(y.deep, dark: dark))
            let (ha, hb) = (x.hue * .pi / 180, y.hue * .pi / 180)
            let (dl, da, db) = (a.l - b.l, a.c * cos(ha) - b.c * cos(hb), a.c * sin(ha) - b.c * sin(hb))
            return (dl * dl + da * da + db * db).squareRoot()
        }
        return min(distance(dark: true), distance(dark: false))
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Without leaving sRGB: anything outside it would be clipped by a device
    /// that only has sRGB, and two hues would come out alike.
    static func oklch(_ l: Double, _ c: Double, _ hue: Double) -> NSColor {
        let radians = hue * .pi / 180
        let (a, b) = (c * cos(radians), c * sin(radians))
        let (lm, mm, sm) = (l + 0.3963377774 * a + 0.2158037573 * b,
                            l - 0.1055613458 * a - 0.0638541728 * b,
                            l - 0.0894841775 * a - 1.2914855480 * b)
        let (lc, mc, sc) = (lm * lm * lm, mm * mm * mm, sm * sm * sm)
        func gamma(_ x: Double) -> CGFloat {
            let x = min(max(x, 0), 1)
            return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        return NSColor(srgbRed: gamma(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
                       green: gamma(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
                       blue: gamma(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc),
                       alpha: 1)
    }

    /// The hue that most of what's coloured in an image has, or nil for an
    /// image with little colour (grey, black and white icons).
    static func dominantHue(of image: NSImage) -> Double? {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = { () -> UnsafeMutableRawPointer? in
                  context.interpolationQuality = .medium
                  context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
                  return context.data
              }() else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var bins = [Double](repeating: 0, count: 36)
        var opaque = 0.0, coloured = 0.0
        for index in 0..<(side * side) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            func linear(_ value: UInt8) -> Double {
                let x = min(Double(value) / 255 / alpha, 1)
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            let (r, g, b) = (linear(pixels[index * 4]), linear(pixels[index * 4 + 1]), linear(pixels[index * 4 + 2]))
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            let (oa, ob) = (1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
            let chroma = (oa * oa + ob * ob).squareRoot()
            opaque += 1
            guard chroma > 0.05 else { continue }
            coloured += 1
            let hue = (atan2(ob, oa) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            bins[min(Int(hue / 10), 35)] += chroma * chroma
        }
        guard opaque > 0, coloured / opaque > 0.15, let peak = bins.indices.max(by: { bins[$0] < bins[$1] }) else { return nil }
        return Double(peak) * 10 + 5
    }
}

/// Which colour each app has. A colour isn't picked from a list: one is made
/// for the app, far enough from those of the apps open with it. It keeps it,
/// so it can be learnt, until it's open beside an older app it looks too much
/// like, and then it gets a new one. Plain data, so all of this can be tested.
struct AppColorChoices: Codable, Equatable {
    struct Choice: Codable, Equatable {
        let app: String
        var color: AppColor
        /// What the icon suggested, for when it needs a new colour.
        let iconHue: Double?
    }

    /// Oldest first: of two that look alike, the newer changes.
    private(set) var choices: [Choice] = []

    /// How different two colours have to be to count as different, in OKLab.
    /// About 45° of hue in the same tone, which leaves room for some fourteen
    /// apps open at once.
    static let enough = 0.04

    private static let hueStep = 5.0

    func color(of app: String) -> AppColor? {
        choices.first { $0.app == app }?.color
    }

    /// The colour for an app, made if it hasn't one, with `open` the apps open now.
    @discardableResult
    mutating func assign(_ app: String, iconHue: Double?, open: Set<String>) -> AppColor {
        if let known = color(of: app) { return known }
        let color = make(for: app, iconHue: iconHue, against: colors(of: open.subtracting([app])))
        choices.append(Choice(app: app, color: color, iconHue: iconHue))
        return color
    }

    /// Open apps that look too much like an older open one get a new colour,
    /// unless nothing better is left (a great many open). Returns whether
    /// anything changed. Leaves everything alone once they differ.
    @discardableResult
    mutating func separate(open: Set<String>) -> Bool {
        var changed = false
        var older: [AppColor] = []
        for index in choices.indices where open.contains(choices[index].app) {
            let current = choices[index].color
            if let nearest = older.map({ AppPalette.difference($0, current) }).min(), nearest < Self.enough {
                let others = colors(of: open.subtracting([choices[index].app]))
                let fresh = make(for: choices[index].app, iconHue: choices[index].iconHue, against: others)
                let freshNearest = others.map { AppPalette.difference($0, fresh) }.min() ?? .infinity
                if freshNearest > nearest {
                    choices[index].color = fresh
                    changed = true
                }
            }
            older.append(choices[index].color)
        }
        return changed
    }

    private func colors(of apps: Set<String>) -> [AppColor] {
        choices.filter { apps.contains($0.app) }.map(\.color)
    }

    /// Of every colour far enough from `others`, the one nearest the icon's
    /// hue, in the first tone if it can be, and not too close to apps seen at
    /// some other time, so they rarely have to change later. With none far
    /// enough, the one that's furthest.
    private func make(for app: String, iconHue: Double?, against others: [AppColor]) -> AppColor {
        var candidates: [AppColor] = []
        for deep in [false, true] {
            for step in 0..<Int(360 / Self.hueStep) { candidates.append(AppColor(hue: Double(step) * Self.hueStep, deep: deep)) }
        }
        func nearest(_ color: AppColor) -> Double { others.map { AppPalette.difference($0, color) }.min() ?? .infinity }
        // Ties go by a hash that's the same on every launch, unlike `hashValue`.
        func tie(_ color: AppColor) -> UInt64 {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in "\(app)#\(color.hue)#\(color.deep)".utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return hash
        }
        let distant = candidates.filter { nearest($0) >= Self.enough }
        guard !distant.isEmpty else {
            return candidates.max { (nearest($0), tie($0)) < (nearest($1), tie($1)) } ?? candidates[0]
        }
        let seen = choices.filter { $0.app != app }.map(\.color)
        func cost(_ color: AppColor) -> Double {
            var cost = color.deep ? 10.0 : 0
            if let iconHue { cost += AppPalette.hueDistance(iconHue, color.hue) / 180 * 6 }
            cost += Double(seen.filter { AppPalette.difference($0, color) < Self.enough }.count) * 0.25
            // With nothing else to go by, well away from the others.
            cost -= min(nearest(color), 0.1) * 5
            return cost
        }
        return distant.min { (cost($0), tie($0)) < (cost($1), tie($1)) } ?? distant[0]
    }
}

/// The colours of this Mac's apps, kept in their own file: they're worked out
/// from what's used here, not a setting, so they stay out of an export.
final class AppColors {
    static let shared = AppColors()

    /// The switcher's setting, kept here for everything that shows its rows.
    var enabled = false
    private var choices: AppColorChoices
    /// The apps last checked against each other. Nothing can have come to look
    /// alike until they change, so a switch doesn't compare anything.
    private var checked = Set<String>()

    private static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("app-colors.json")
    }

    private init() {
        choices = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode(AppColorChoices.self, from: $0) } ?? AppColorChoices()
    }

    /// Gives each row its app's colour, making one for an app not seen yet.
    /// Looking at an icon, and comparing colours, only happen when an app
    /// opens or closes, so a switch costs a few lookups.
    func tint(_ items: inout [SwitcherItem]) {
        guard enabled else { return }
        var open = Set<String>()
        for item in items { if let key = item.colorKey, item.state != .notListed { open.insert(key) } }
        var changed = false
        // Only what's in use gets a colour, not an app that a search came across.
        for item in items where item.state != .notListed {
            guard let key = item.colorKey, choices.color(of: key) == nil else { continue }
            choices.assign(key, iconHue: item.icon.flatMap(AppPalette.dominantHue), open: open)
            changed = true
        }
        if open != checked {
            if choices.separate(open: open) { changed = true }
            checked = open
        }
        for index in items.indices { items[index].tint = items[index].colorKey.flatMap(choices.color) }
        if changed { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(choices) else { return }
        let url = Self.fileURL
        DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
    }
}
