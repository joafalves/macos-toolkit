import CoreGraphics

/// The layouts offered while a window is dragged with ⌥ held: a small bar of
/// miniature displays by the pointer, each split the way the window could go.
/// Moving onto one part of one picks that slot. The slots overlap (a half,
/// a third, the whole display), so they can't all be drawn on the screen at
/// full size; small, side by side, they can.
struct SlotPicker: Equatable {
    struct Hit: Equatable {
        var layout: Int
        var zone: Int
    }

    let display: CGDirectDisplayID
    /// Core Graphics coordinates, like everything else here.
    let frame: CGRect
    /// Each layout's slots, as fractions of the display.
    let layouts: [[CGRect]]
    /// Where each layout's miniature is drawn.
    let tiles: [CGRect]
    var hovered: Hit?

    private static let tileWidth: CGFloat = 88
    private static let spacing: CGFloat = 10
    private static let padding: CGFloat = 10
    /// Between the pointer and the bar, so the bar doesn't sit under it.
    private static let offset: CGFloat = 28

    /// Just above the pointer, or below it when there's no room above, and
    /// kept on the display.
    init(display: LayoutDisplay, pointer: CGPoint) {
        self.display = display.id
        layouts = Self.layouts(for: display)
        let aspect = display.frame.width / max(display.frame.height, 1)
        let tileHeight = min(max(Self.tileWidth / aspect, 28), Self.tileWidth)
        let count = CGFloat(layouts.count)
        let size = CGSize(width: count * Self.tileWidth + (count - 1) * Self.spacing + Self.padding * 2,
                          height: tileHeight + Self.padding * 2)
        let area = display.usable.insetBy(dx: 8, dy: 8)
        var origin = CGPoint(x: pointer.x - size.width / 2, y: pointer.y - Self.offset - size.height)
        if origin.y < area.minY { origin.y = pointer.y + Self.offset }
        origin.x = min(max(origin.x, area.minX), max(area.maxX - size.width, area.minX))
        origin.y = min(max(origin.y, area.minY), max(area.maxY - size.height, area.minY))
        let bar = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
        frame = bar
        tiles = (0..<layouts.count).map { index in
            CGRect(x: bar.minX + Self.padding + CGFloat(index) * (Self.tileWidth + Self.spacing),
                   y: bar.minY + Self.padding, width: Self.tileWidth, height: tileHeight)
        }
    }

    /// The slot under the point, if it's over one.
    func hit(_ point: CGPoint) -> Hit? {
        for (index, tile) in tiles.enumerated() where tile.contains(point) {
            let unit = CGPoint(x: (point.x - tile.minX) / tile.width, y: (point.y - tile.minY) / tile.height)
            if let zone = layouts[index].firstIndex(where: { $0.contains(unit) }) { return Hit(layout: index, zone: zone) }
        }
        return nil
    }

    func unit(of hit: Hit) -> CGRect {
        layouts[hit.layout][hit.zone]
    }

    /// A slot drawn inside its miniature, a little apart from its neighbours.
    func rect(of zone: CGRect, in tile: CGRect) -> CGRect {
        CGRect(x: tile.minX + zone.minX * tile.width, y: tile.minY + zone.minY * tile.height,
               width: zone.width * tile.width, height: zone.height * tile.height).insetBy(dx: 1.5, dy: 1.5)
    }

    /// Whole display, halves both ways, thirds, two thirds and one third,
    /// quarters; on an ultrawide also fourths and a wide middle. Down instead
    /// of across on a display that stands upright.
    static func layouts(for display: LayoutDisplay) -> [[CGRect]] {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        let full = [r(0, 0, 1, 1)]
        let quarters = [r(0, 0, 0.5, 0.5), r(0.5, 0, 0.5, 0.5), r(0, 0.5, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]
        let third: CGFloat = 1 / 3
        if display.portrait {
            return [full, [r(0, 0, 1, 0.5), r(0, 0.5, 1, 0.5)], [r(0, 0, 1, third), r(0, third, 1, third), r(0, 2 * third, 1, third)], quarters]
        }
        var list = [
            full,
            [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 1)],
            [r(0, 0, 1, 0.5), r(0, 0.5, 1, 0.5)],
            [r(0, 0, third, 1), r(third, 0, third, 1), r(2 * third, 0, third, 1)],
            [r(0, 0, 2 * third, 1), r(2 * third, 0, third, 1)],
            [r(0, 0, third, 1), r(third, 0, 2 * third, 1)],
            quarters,
        ]
        if display.ultrawide {
            list.insert([r(0, 0, 0.25, 1), r(0.25, 0, 0.25, 1), r(0.5, 0, 0.25, 1), r(0.75, 0, 0.25, 1)], at: 4)
            list.append([r(0, 0, 0.25, 1), r(0.25, 0, 0.5, 1), r(0.75, 0, 0.25, 1)])
        }
        return list
    }
}

extension LayoutDisplay {
    var ultrawide: Bool { frame.width / max(frame.height, 1) >= GridSize.ultrawideAspect }
}
