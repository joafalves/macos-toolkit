import AppKit
import SwiftUI

/// Where everything on a ring of `n` places sits, from its centre, in points
/// (y down, as on screen): the places, the band they're on, and the fan of
/// windows beyond. Picking goes by the angle from the centre.
struct RingGeometry {
    let n: Int
    let size: CGFloat = 52
    let R1: CGFloat
    let rIn: CGFloat
    let rOut: CGFloat
    let hubR: CGFloat
    let span: CGFloat
    /// Choosing starts this far out, well inside the drawn centre: a flick of
    /// a few millimetres is enough.
    let pickR: CGFloat = 22
    /// Past the ring: a slot's windows, or into a folder.
    let far: CGFloat
    /// Half the panel's width and height: room for the cards all round.
    let ex: CGFloat
    let ey: CGFloat
    static let card = CGSize(width: 150, height: 88)
    /// The title's line under a card, with its gap.
    static let titleRoom: CGFloat = 22
    /// Between cards, and between them and the ring.
    static let cardGap: CGFloat = 10
    /// From an icon's centre to the inner track (letters) and the outer one (open windows).
    static let trackOffset: CGFloat = 44
    static let tickOffset: CGFloat = 35

    /// `n` places spread round a ring sized for `room`: the same disc for every
    /// ring of one dock, however many each has.
    init(n: Int, room: Int) {
        self.n = max(n, 1)
        R1 = max(100, CGFloat(max(room, self.n)) * (size + 24) / (2 * .pi))
        // Room inside the icons for the letters' track, and outside for the windows' ticks.
        rIn = R1 - (size / 2 + 28)
        rOut = R1 + RingGeometry.tickOffset + 11
        hubR = rIn - 4
        span = 2 * .pi / CGFloat(self.n)
        far = rOut + 14
        // Room for a row of four cards above or below, or a column of them beside.
        let card = RingGeometry.card
        ex = max(rOut + RingGeometry.cardGap + card.width + 14, (card.width + RingGeometry.cardGap) * 2 + 14)
        ey = max(rOut + RingGeometry.cardGap + card.height + RingGeometry.titleRoom + 14, (card.height + RingGeometry.titleRoom + RingGeometry.cardGap) * 2 + 14)
    }

    func angle(_ i: Int) -> CGFloat { -.pi / 2 + CGFloat(i) * span }
    func point(_ i: Int, radius: CGFloat? = nil) -> CGPoint {
        let a = angle(i), r = radius ?? R1
        return CGPoint(x: cos(a) * r, y: sin(a) * r)
    }
    func slot(at d: CGVector) -> Int {
        let a = atan2(d.dy, d.dx) + .pi / 2
        let t = (a.truncatingRemainder(dividingBy: 2 * .pi) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return Int((t / span).rounded()) % n
    }
    /// The first straight out, then one each side in turn.
    static func fanOffsets(_ m: Int) -> [CGFloat] {
        (0..<m).map { j in j == 0 ? 0 : (j % 2 == 1 ? CGFloat(j + 1) / 2 : -CGFloat(j) / 2) }
    }

    /// What a card takes, around its centre `p` (y down): the card with its title.
    static func rect(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - card.width / 2, y: p.y - card.height / 2, width: card.width, height: card.height + titleRoom)
    }

    /// Where slot `i`'s cards go, their centres from the ring's (y down): round the
    /// ring, each against it, place 0 in the slot's direction and each next place
    /// turned just far enough to clear the last by the gap. Later places go to the
    /// right, or down at the sides, wherever the slot is: clockwise at the top and
    /// right, the other way at the bottom and left.
    func cardCentres(slot i: Int, places: [CGFloat]) -> [CGPoint] {
        guard !places.isEmpty else { return [] }
        let a = angle(i), gap = Self.cardGap
        func hugging(_ angle: CGFloat) -> CGPoint {
            let u = CGPoint(x: cos(angle), y: sin(angle))
            var t = rOut
            while t < ex + ey {
                let p = CGPoint(x: u.x * t, y: u.y * t), r = Self.rect(at: p)
                let nearest = CGPoint(x: min(max(0, r.minX), r.maxX), y: min(max(0, r.minY), r.maxY))
                if hypot(nearest.x, nearest.y) >= rOut + gap { return p }
                t += 1
            }
            return CGPoint(x: u.x * t, y: u.y * t)
        }
        func apart(_ p: CGPoint, _ q: CGPoint) -> Bool {
            let r = Self.rect(at: p), s = Self.rect(at: q)
            return r.minX - s.maxX >= gap || s.minX - r.maxX >= gap || r.minY - s.maxY >= gap || s.minY - r.maxY >= gap
        }
        var placed: [CGFloat: CGPoint] = [0: hugging(a)]
        // Which way round goes right (or, at a side, down).
        let tangent = CGPoint(x: -sin(a), y: cos(a))
        let clockwise: CGFloat = (abs(tangent.x) >= 0.5 ? tangent.x : tangent.y) > 0 ? 1 : -1
        for later in [CGFloat(1), -1] {
            var angle = a, last = placed[0]!, k = later
            while places.contains(k) {
                repeat { angle += later * clockwise * 0.004 } while !apart(hugging(angle), last) && abs(angle - a) < .pi
                last = hugging(angle)
                placed[k] = last
                k += later
            }
        }
        return places.map { placed[$0] ?? hugging(a) }
    }

    static func angleDiff(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = (a - b + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return abs((d < 0 ? d + 2 * .pi : d) - .pi)
    }
}

/// One card in a slot's fan: a window, or the way to all of the app's windows.
struct FanItem: Identifiable {
    enum Kind { case window(SwitcherItem), all(Int) }
    let id: String
    let kind: Kind
    /// The card's centre, from the ring's (y down).
    let center: CGPoint
    var title: String {
        switch kind {
        case .window(let item): return item.title.isEmpty ? item.appName : item.title
        case .all: return String(localized: "All windows")
        }
    }
}

/// What the ring shows, kept by the controller on the main thread.
final class DockRingModel: ObservableObject {
    @Published var slots: [RingSlot] = []
    @Published var geometry = RingGeometry(n: 10, room: 10)
    @Published var title = ""
    /// How many layers there are and which one shows; one draws no dots.
    @Published var layers = 1
    @Published var layer = 0
    /// ⌥ is held: a pick on an app opens a new window of it.
    @Published var newWindow = false
    @Published var hover: Int? {
        didSet {
            guard let hover, hover != oldValue else { return }
            // The way round that's shortest, so the highlight never sweeps the whole ring.
            var angle = geometry.angle(hover)
            if oldValue != nil {
                while angle - highlightAngle > .pi { angle -= 2 * .pi }
                while highlightAngle - angle > .pi { angle += 2 * .pi }
            }
            highlightAngle = angle
        }
    }
    /// Where the highlight is, unwrapped: it slides from place to place.
    @Published var highlightAngle: CGFloat = 0
    @Published var fan: [FanItem] = []
    @Published var fanHover: Int?
    /// The card letting go would bring forward: the one pointed at past the
    /// ring, or the most recent window, straight out, while on the app.
    var pick: Int? { far ? fanHover : (fan.isEmpty ? nil : 0) }
    /// Past the ring, where the fan is what's picked.
    @Published var far = false
    @Published var moved = false
    /// Each app's letter on its icon: only while the ring stays open after a tap, where they're used.
    @Published var letters = false
    @Published var previews: [CGWindowID: CGImage] = [:]

    @Published var searching = false
    @Published var query = ""
    @Published var results: [DockApp] = []
    @Published var selection = 0
}

// MARK: - The panel

/// A borderless panel that never takes focus or clicks: the controller follows
/// the pointer itself. The glass is one effect view, cut to the donut and its
/// centre, under the drawing.
final class DockRingPanel {
    private var panel: NSPanel?
    private var glass: NSVisualEffectView?
    /// The ring's own pointer: a view of its own, so a move redraws nothing else.
    private var pointerView: NSImageView?
    /// The shadow of the glass's shapes, outside them only: under see-through
    /// glass a shadow would darken it.
    private var shadow: CALayer?
    private var shadowCut: CAShapeLayer?
    /// The solid parts under the drawing: each shape's fill, the centre's shade and
    /// the edge's hairline. Layers, not SwiftUI: there, a fill under parts that
    /// moved was sometimes left undrawn, and what's behind read through it.
    private var fills: CAShapeLayer?
    private var well: CAShapeLayer?
    private var edge: CAShapeLayer?
    let model = DockRingModel()
    var isVisible: Bool { panel?.isVisible ?? false }
    var windowNumber: Int? { panel?.windowNumber }
    /// Whether the ring draws its own pointer: not when the real one is it.
    var showsPointer = true {
        didSet { pointerView?.isHidden = !showsPointer }
    }

    /// Shows it with its centre at `center`, in AppKit's coordinates.
    func show(at center: CGPoint) {
        let panel = self.panel ?? make()
        let g = model.geometry
        let wasVisible = panel.isVisible
        panel.setFrame(NSRect(x: center.x - g.ex, y: center.y - g.ey, width: g.ex * 2, height: g.ey * 2), display: false)
        updateMask()
        guard !wasVisible else { return }
        // A quick fade in, never waited on: picking works from the first frame.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The ring's pointer at `offset` from the centre (y down).
    func movePointer(to offset: CGPoint) {
        guard let panel, let view = pointerView else { return }
        let size = view.frame.size, hot = NSCursor.pointingHand.hotSpot
        let c = CGPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
        view.setFrameOrigin(NSPoint(x: c.x + offset.x - hot.x, y: c.y - offset.y - (size.height - hot.y)))
    }

    /// Lets the panel go, with the pictures it drew: it's made again on the next open.
    func release() {
        panel?.orderOut(nil)
        panel = nil
        glass = nil
        fills = nil
        well = nil
        edge = nil
    }

    /// The glass's shapes, in the panel's coordinates (y up), each with how
    /// solid it is: the donut, the centre and the windows' cards, or the search's card.
    private func shapes(in size: CGSize) -> [(CGPath, CGFloat)] {
        let g = model.geometry, c = CGPoint(x: size.width / 2, y: size.height / 2)
        if model.searching {
            return [(CGPath(roundedRect: CGRect(x: c.x - 230, y: c.y - 170, width: 460, height: 340), cornerWidth: 18, cornerHeight: 18, transform: nil), 1)]
        }
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: c.x - g.rOut, y: c.y - g.rOut, width: g.rOut * 2, height: g.rOut * 2))
        // One disc, the centre included: a gap between them showed what's behind as noise.
        var list: [(CGPath, CGFloat)] = [(ring, 1)]
        let card = RingGeometry.card
        for (k, item) in model.fan.enumerated() {
            // y up here.
            let x = c.x + item.center.x, y = c.y - item.center.y
            let rect = CGRect(x: x - card.width / 2, y: y - card.height / 2, width: card.width, height: card.height)
            list.append((CGPath(roundedRect: rect, cornerWidth: 11, cornerHeight: 11, transform: nil), 1))
        }
        return list
    }

    /// Cuts the glass to its shapes, and lays their shadow round them.
    func updateMask() {
        guard let panel, let glass else { return }
        let size = panel.frame.size
        let shapes = shapes(in: size)
        glass.maskImage = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for (path, alpha) in shapes {
                context.addPath(path)
                context.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
                // The donut's two circles, filled between them.
                context.fillPath(using: .evenOdd)
            }
            return true
        }
        guard let shadow, let shadowCut else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layFills(shapes.map(\.0), in: size, appearance: panel.effectiveAppearance)
        let outline = CGMutablePath(), cut = CGMutablePath()
        cut.addRect(CGRect(origin: .zero, size: size))
        for (index, (path, alpha)) in shapes.enumerated() where alpha == 1 {
            // The donut's shadow is its outer circle's; the rest are whole shapes.
            let shape = index == 0 ? CGPath(ellipseIn: path.boundingBox, transform: nil) : path
            outline.addPath(shape)
            cut.addPath(shape)
        }
        shadow.frame = CGRect(origin: .zero, size: size)
        shadow.shadowPath = outline
        shadowCut.frame = shadow.bounds
        shadowCut.path = cut
        CATransaction.commit()
    }

    private func layFills(_ paths: [CGPath], in size: CGSize, appearance: NSAppearance) {
        guard let fills, let well, let edge else { return }
        var background = NSColor.clear.cgColor, shade = background, line = background
        appearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
            shade = NSColor.labelColor.withAlphaComponent(0.045).cgColor
            line = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
        let all = CGMutablePath()
        paths.forEach { all.addPath($0) }
        for layer in [fills, well, edge] { layer.frame = CGRect(origin: .zero, size: size) }
        fills.path = all
        fills.fillColor = background
        let g = model.geometry, c = CGPoint(x: size.width / 2, y: size.height / 2)
        let ring = !model.searching
        well.path = ring ? CGPath(ellipseIn: CGRect(x: c.x - g.hubR, y: c.y - g.hubR, width: g.hubR * 2, height: g.hubR * 2), transform: nil) : nil
        well.fillColor = shade
        well.strokeColor = line
        well.lineWidth = 0.5
        edge.path = ring ? CGPath(ellipseIn: CGRect(x: c.x - g.rOut + 0.25, y: c.y - g.rOut + 0.25, width: g.rOut * 2 - 0.5, height: g.rOut * 2 - 0.5), transform: nil) : nil
        edge.fillColor = nil
        edge.strokeColor = line
        edge.lineWidth = 0.5
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Its shadow follows the glass and the cards, as any window's follows its shape.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = NSView()
        root.wantsLayer = true
        let shadow = CALayer()
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.3
        shadow.shadowRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        let cut = CAShapeLayer()
        cut.fillRule = .evenOdd
        shadow.mask = cut
        root.layer?.addSublayer(shadow)
        self.shadow = shadow
        self.shadowCut = cut
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        let drawing = NSHostingView(rootView: DockRingView(model: model))
        let solid = NSView()
        solid.wantsLayer = true
        let fills = CAShapeLayer(), well = CAShapeLayer(), edge = CAShapeLayer()
        for layer in [fills, well, edge] { solid.layer?.addSublayer(layer) }
        self.fills = fills
        self.well = well
        self.edge = edge
        for view in [glass, solid, drawing] as [NSView] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        let hand = NSCursor.pointingHand.image
        let pointer = NSImageView(image: hand)
        pointer.frame = NSRect(origin: .zero, size: hand.size)
        root.addSubview(pointer)
        panel.contentView = root
        self.panel = panel
        self.glass = glass
        self.pointerView = pointer
        pointer.isHidden = !showsPointer
        return panel
    }
}

// MARK: - Drawing

struct DockRingView: View {
    @ObservedObject var model: DockRingModel
    /// For `--snapshot`: the glass is the window server's, so a stand-in is drawn.
    static var drawnGlass = false

    var body: some View {
        let g = model.geometry
        ZStack {
            if model.searching {
                DockSearchView(model: model)
            } else {
                ring(g)
            }
        }
        .frame(width: g.ex * 2, height: g.ey * 2)
    }

    @ViewBuilder
    private func ring(_ g: RingGeometry) -> some View {
        let c = CGPoint(x: g.ex, y: g.ey)
        ZStack {
            // The solid disc, the centre's shade and the edge's hairline are the panel's
            // layers (`layFills`); a snapshot has no panel, so draws them here.
            if Self.drawnGlass {
                Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                    .frame(width: g.rOut * 2, height: g.rOut * 2).position(c)
                Circle().fill(Color.primary.opacity(0.045))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .frame(width: g.hubR * 2, height: g.hubR * 2).position(c)
                Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    .frame(width: g.rOut * 2, height: g.rOut * 2).position(c)
            }
            if let hover = model.hover, model.slots.indices.contains(hover) {
                // The place's stretch of the band, its letter and ticks in it, sliding round
                // the ring from place to place.
                BandHighlight(angle: model.highlightAngle, geometry: g)
                    .fill(Color.primary.opacity(0.11))
                    .frame(width: g.ex * 2, height: g.ey * 2)
                    .animation(.spring(response: 0.18, dampingFraction: 0.88), value: model.highlightAngle)
                    .transition(.opacity)
            }
            // Open windows as ticks on the outer track, towards where they fan out: one
            // a window, up to five; one faint tick for an app open without any.
            Ticks(slots: model.slots, geometry: g, hover: model.hover)
                .frame(width: g.ex * 2, height: g.ey * 2)
            if Self.drawnGlass {
                ForEach(Array(model.fan.enumerated()), id: \.element.id) { k, item in
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
                        .frame(width: RingGeometry.card.width, height: RingGeometry.card.height)
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                        .position(x: c.x + item.center.x, y: c.y + item.center.y)
                }
            }
            ForEach(Array(model.fan.enumerated()), id: \.element.id) { k, item in
                // The card itself centred where its glass is; its title below.
                let p = CGPoint(x: c.x + item.center.x, y: c.y + item.center.y + RingGeometry.titleRoom / 2)
                FanCard(item: item, icon: model.hover.flatMap { model.slots.indices.contains($0) ? model.slots[$0].icon : nil },
                        preview: preview(item), hot: model.pick == k)
                    .position(p)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .animation(.easeOut(duration: 0.1), value: model.hover)
            ForEach(Array(model.slots.enumerated()), id: \.element.id) { i, slot in
                let p = g.point(i)
                SlotView(slot: slot, size: g.size, angle: g.angle(i), hot: model.hover == i, letters: model.letters)
                    .position(x: c.x + p.x, y: c.y + p.y)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            .animation(.easeOut(duration: 0.14), value: model.layer)
            .animation(.easeOut(duration: 0.14), value: model.title)
            HubView(model: model)
                .frame(width: g.hubR * 2 - 16, height: g.hubR * 2 - 16)
                .position(c)
        }
    }

    private func preview(_ item: FanItem) -> CGImage? {
        guard case .window(let window) = item.kind, let id = window.window else { return nil }
        return model.previews[id]
    }
}

/// Each place's open windows as ticks, one shape per place. Not a Canvas: as the
/// highlight moved off a place, the window redrew only where it had been, and a
/// Canvas under it wasn't drawn again there, which cut the ticks along its edge.
private struct Ticks: View {
    let slots: [RingSlot]
    let geometry: RingGeometry
    let hover: Int?

    var body: some View {
        ZStack {
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, slot in
                let count = min(5, slot.windows.count)
                if count > 0 || slot.running {
                    TickMarks(count: max(count, 1), angle: geometry.angle(i), radius: geometry.R1 + RingGeometry.tickOffset)
                        .stroke(hover == i ? Color.accentColor : Color.primary.opacity(count > 0 ? 0.55 : 0.22),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// `count` ticks on the circle of `radius`, centred on `angle`: each a stroke of
/// its own, not joined to the last.
private struct TickMarks: Shape {
    let count: Int
    let angle: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = radius
        let length: CGFloat = 7 / r, gap: CGFloat = 4 / r
        let a0 = angle - (CGFloat(count) * length + CGFloat(count - 1) * gap) / 2
        var path = Path()
        for k in 0..<count {
            let a = a0 + CGFloat(k) * (length + gap)
            path.move(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
            path.addArc(center: c, radius: r, startAngle: .radians(a), endAngle: .radians(a + length), clockwise: false)
        }
        return path
    }
}

/// A place's stretch of the band with rounded corners: an inset sector joined
/// with its outline stroked round, one path.
private struct BandHighlight: Shape {
    var angle: CGFloat
    let geometry: RingGeometry
    var animatableData: CGFloat {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let g = geometry, corner: CGFloat = 12, margin: CGFloat = 5
        let half = g.span / 2 - (corner + 3) / g.R1
        let inset = Sector(r0: g.hubR + 3 + corner, r1: g.rOut - margin - corner, a0: angle - half, a1: angle + half).path(in: rect).cgPath
        let outline = inset.copy(strokingWithWidth: corner * 2, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        return Path(inset.union(outline))
    }
}

struct Sector: Shape {
    let r0, r1, a0, a1: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: r1, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        p.addArc(center: c, radius: r0, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct SlotView: View {
    let slot: RingSlot
    let size: CGFloat
    let angle: CGFloat
    let hot: Bool
    let letters: Bool

    var body: some View {
        ZStack {
            // The icon and its red badge grow together when pointed at.
            ZStack {
                if let icon = slot.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                } else {
                    FolderTile(minis: slot.minis, size: size)
                }
                if let badge = slot.badge {
                    Text(verbatim: badge)
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                        .background(Capsule().fill(Color(nsColor: .systemRed)))
                        // Off the icon's clockwise side, towards the outside: clear of the
                        // windows' ticks beyond it and the letter inside, all round the ring.
                        .offset(x: cos(angle) * 12 - sin(angle) * (size / 2 - 2), y: sin(angle) * 12 + cos(angle) * (size / 2 - 2))
                }
            }
            .shadow(color: .black.opacity(hot ? 0.28 : 0.16), radius: hot ? 6 : 3, y: hot ? 3 : 1.5)
            .scaleEffect(hot ? 1.05 : 1)
            // The letter on the ring's inner track, between the icon and the centre,
            // the way a key's legend sits: only while the ring stays open, where it's used.
            if letters, let letter = slot.letter {
                Text(verbatim: letter.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(hot ? Color.primary : Color.secondary)
                    .offset(x: -cos(angle) * RingGeometry.trackOffset, y: -sin(angle) * RingGeometry.trackOffset)
            }
        }
        .animation(.easeOut(duration: 0.08), value: hot)
    }
}

private struct FolderTile: View {
    let minis: [NSImage]
    let size: CGFloat
    var body: some View {
        let m = (size - 16) / 2
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay(
                LazyVGrid(columns: [GridItem(.fixed(m), spacing: 3), GridItem(.fixed(m), spacing: 3)], spacing: 3) {
                    ForEach(Array(minis.prefix(4).enumerated()), id: \.offset) { _, icon in
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: m, height: m)
                    }
                }
                .frame(width: size - 10, height: size - 10)
            )
    }
}

private struct FanCard: View {
    let item: FanItem
    let icon: NSImage?
    let preview: CGImage?
    let hot: Bool
    private var size: CGSize { RingGeometry.card }
    static let titleRoom = RingGeometry.titleRoom

    var body: some View {
        // The card's glass is the panel's, cut to it: only what's on it is drawn here.
        VStack(spacing: 6) {
            ZStack {
                // Its solid fill is the panel's layer; a snapshot draws it here.
                if DockRingView.drawnGlass {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                }
                if hot { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.opacity(0.16)) }
                switch item.kind {
                case .all(let more):
                    VStack(spacing: 2) {
                        Text(verbatim: "+\(more)").font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("more").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .window:
                    if let preview {
                        // A rim and a shadow, as a window has, so a dark window stands out on dark glass.
                        Image(decorative: preview, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            .padding(8)
                    } else if let icon {
                        // Without Screen Recording the app's icon stands for the window.
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 36, height: 36).opacity(0.9)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(hot ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: hot ? 2 : 0.5))
            // On a plate of its own, readable over any desktop; a plain fill, as materials misdraw in this panel.
            // As wide as the title, up to the card's width, where a long one is cut short.
            ViewThatFits(in: .horizontal) {
                plate(Text(verbatim: item.title).fixedSize())
                plate(Text(verbatim: item.title).frame(width: size.width))
            }
            .frame(width: size.width + 20)
        }
        .animation(.easeOut(duration: 0.08), value: hot)
    }

    /// The title on a plate of its own, readable over any desktop: a plain
    /// fill, since materials misdraw in this panel.
    private func plate(_ text: some View) -> some View {
        text
            .font(.system(size: 12, weight: hot ? .semibold : .medium))
            .foregroundStyle(hot ? Color.white : Color.primary)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(height: Self.titleRoom - 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hot ? Color.accentColor : Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(hot ? 0 : 0.1), lineWidth: 0.5))
    }
}

private struct HubView: View {
    @ObservedObject var model: DockRingModel

    var body: some View {
        // The layers' dots in a place of their own at the bottom, the text centred above.
        ZStack(alignment: .bottom) {
            texts
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, model.layers > 1 ? 14 : 0)
            if model.layers > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<model.layers, id: \.self) { i in
                        Circle().fill(Color.primary.opacity(i == model.layer ? 0.75 : 0.2)).frame(width: 5, height: 5)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(6)
    }

    private var texts: some View {
        VStack(spacing: 3) {
            let (name, detail) = text
            if let name {
                // Smaller rather than broken mid-word: a long title shrinks to fit.
                Text(verbatim: name).font(.system(size: 15, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.6).multilineTextAlignment(.center)
            }
            if let detail {
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
            }
            // Which of its windows that is, when it has more than one.
            if let k = model.pick, let hover = model.hover, model.slots.indices.contains(hover), model.slots[hover].windows.count > 1 {
                Text(verbatim: String(localized: "\(windowNumber(k) + 1) of \(model.slots[hover].windows.count)"))
                    .font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
    }

    /// A card's place among the app's windows, most recent first; the cards go
    /// straight out, then one each side, so their order on screen isn't it.
    private func windowNumber(_ k: Int) -> Int {
        guard model.fan.indices.contains(k), let hover = model.hover, model.slots.indices.contains(hover),
              case .window(let item) = model.fan[k].kind else { return k }
        return model.slots[hover].windows.firstIndex { $0.id == item.id } ?? k
    }

    private var text: (String?, String?) {
        if let hover = model.hover, model.slots.indices.contains(hover) {
            let slot = model.slots[hover]
            // ⌥ held: letting go, or a click, opens a new window rather than bringing one forward.
            if model.newWindow, !model.far, case .app = slot.kind { return (String(localized: "New window"), slot.name) }
            if model.far, let k = model.fanHover, model.fan.indices.contains(k) {
                switch model.fan[k].kind {
                case .window: return (model.fan[k].title, slot.name)
                case .all: return (String(localized: "All windows"), slot.name)
                }
            }
            if case .folder(let entries) = slot.kind {
                return (slot.name, entries.count == 1 ? String(localized: "1 app") : String(localized: "\(entries.count) apps"))
            }
            // The window letting go brings forward, as its card shows lit.
            if let k = model.pick, model.fan.indices.contains(k) { return (slot.name, model.fan[k].title) }
            return (slot.name, slot.running ? String(localized: "Open, no windows") : String(localized: "Not open"))
        }
        if model.moved { return (String(localized: "Cancel"), nil) }
        return (model.title, nil)
    }
}

/// Every app, for typing a few letters of one: what Tab shows.
private struct DockSearchView: View {
    @ObservedObject var model: DockRingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                if model.query.isEmpty {
                    Text("Type to search").foregroundStyle(.secondary)
                } else {
                    Text(verbatim: model.query)
                }
                Spacer()
                Text(verbatim: "esc").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
            if model.results.isEmpty {
                Text("No app has that name").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                    ForEach(Array(model.results.prefix(15).enumerated()), id: \.element.path) { i, app in
                        VStack(spacing: 5) {
                            Image(nsImage: DockRings.icon(app)).resizable().frame(width: 44, height: 44)
                            Text(verbatim: app.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        }
                        .padding(.vertical, 7).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(i == model.selection ? Color.accentColor.opacity(0.22) : .clear))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(width: 460, height: 340)
    }
}
