import AppKit

/// The grid windows snap to with ⌃⌥S, apart from the keyboard grid's cells:
/// finer, drawn as dots, and only a guide for where edges land. Per display.
struct SnapGrid: Codable, Equatable {
    var columns: Int
    var rows: Int

    static let columnRange = 2...64
    static let rowRange = 2...40

    init(columns: Int, rows: Int) {
        self.columns = min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        self.rows = min(max(rows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(columns: try c.decodeIfPresent(Int.self, forKey: .columns) ?? 24,
                  rows: try c.decodeIfPresent(Int.self, forKey: .rows) ?? 15)
    }

    /// 24 columns, which halves, thirds, quarters and sixths divide evenly;
    /// 48 across an ultrawide. Rows to make the cells about square.
    static func suggested(for size: CGSize) -> SnapGrid {
        let aspect = size.width / max(size.height, 1)
        let columns = aspect < 1 ? 12 : aspect >= GridSize.ultrawideAspect ? 48 : 24
        return SnapGrid(columns: columns, rows: Int((CGFloat(columns) / max(aspect, 0.1)).rounded()))
    }

    /// The width of a step, and its height, in an area with this gap: a block
    /// of `n` steps is `n` of them less one gap, as `LayoutGeometry.place` lays it out.
    func step(in area: CGRect, gap: CGFloat) -> CGSize {
        CGSize(width: (area.width - gap) / CGFloat(columns), height: (area.height - gap) / CGFloat(rows))
    }

    /// Where the dot for line `i` across (and `j` down) sits: halfway across
    /// the gap between two blocks, so a window's corners are right by it.
    func dot(_ i: Int, _ j: Int, in area: CGRect, gap: CGFloat) -> CGPoint {
        let s = step(in: area, gap: gap)
        return CGPoint(x: area.minX + gap / 2 + CGFloat(i) * s.width, y: area.minY + gap / 2 + CGFloat(j) * s.height)
    }

    /// The block whose edges are each nearest the window's own: what ⌃⌥S
    /// snaps to. One smaller than a step gets the step its middle is in.
    func snapping(_ frame: CGRect, in area: CGRect, gap: CGFloat) -> SnapCells {
        let s = step(in: area, gap: gap)
        func span(_ low: CGFloat, _ high: CGFloat, _ origin: CGFloat, _ step: CGFloat, _ count: Int) -> (Int, Int) {
            guard step > 0, low.isFinite, high.isFinite else { return (0, count) }
            var a = Int(((low - origin - gap) / step).rounded()), b = Int(((high - origin) / step).rounded())
            a = min(max(a, 0), count)
            b = min(max(b, 0), count)
            if b <= a {
                let middle = Int(((low + high) / 2 - origin - gap / 2) / step)
                a = min(max(middle, 0), count - 1)
                b = a + 1
            }
            return (a, b)
        }
        let (left, right) = span(frame.minX, frame.maxX, area.minX, s.width, columns)
        let (top, bottom) = span(frame.minY, frame.maxY, area.minY, s.height, rows)
        return SnapCells(left: left, top: top, right: right, bottom: bottom)
    }

    /// The smallest block the window fits in: for a window that won't get
    /// as small as the block it was snapped to.
    func covering(_ frame: CGRect, in area: CGRect, gap: CGFloat) -> SnapCells {
        let s = step(in: area, gap: gap)
        func span(_ low: CGFloat, _ high: CGFloat, _ origin: CGFloat, _ step: CGFloat, _ count: Int) -> (Int, Int) {
            guard step > 0, low.isFinite, high.isFinite else { return (0, count) }
            let a = min(max(Int(((low - origin - gap) / step + 0.01).rounded(.down)), 0), count - 1)
            let b = min(max(Int(((high - origin) / step - 0.01).rounded(.up)), a + 1), count)
            return (a, b)
        }
        let (left, right) = span(frame.minX, frame.maxX, area.minX, s.width, columns)
        let (top, bottom) = span(frame.minY, frame.maxY, area.minY, s.height, rows)
        return SnapCells(left: left, top: top, right: right, bottom: bottom)
    }

    /// A block of about this window's size in the middle of the area, on the
    /// dots. Both sides of it are the same number of steps from the edge, so
    /// it's an even number of steps short of the whole: it changes a step at
    /// each side at a time.
    func centering(_ frame: CGRect, in area: CGRect, gap: CGFloat) -> SnapCells {
        let s = step(in: area, gap: gap)
        let across = Self.centered(steps: (frame.width + gap) / max(s.width, 1), of: columns)
        let down = Self.centered(steps: (frame.height + gap) / max(s.height, 1), of: rows)
        return SnapCells(left: (columns - across) / 2, top: (rows - down) / 2,
                         right: (columns + across) / 2, bottom: (rows + down) / 2)
    }

    /// The number of steps nearest `steps` that leaves room for the same
    /// number on each side of it.
    static func centered(steps: CGFloat, of count: Int) -> Int {
        let fitting = min(max(steps.isFinite ? steps : CGFloat(count), 1), CGFloat(count))
        var k = Int(fitting.rounded())
        if (count - k) % 2 != 0 { k += fitting > CGFloat(k) ? 1 : -1 }
        let least = count % 2 == 0 ? 2 : 1
        return min(max(k, least), count)
    }

    func centered(_ cells: SnapCells) -> SnapCells {
        let across = Self.centered(steps: CGFloat(cells.width), of: columns)
        let down = Self.centered(steps: CGFloat(cells.height), of: rows)
        return SnapCells(left: (columns - across) / 2, top: (rows - down) / 2,
                         right: (columns + across) / 2, bottom: (rows + down) / 2)
    }

    /// The block as a fraction of the area, for `LayoutGeometry.place`.
    func unit(of cells: SnapCells) -> CGRect {
        let w = 1 / CGFloat(columns), h = 1 / CGFloat(rows)
        return CGRect(x: CGFloat(cells.left) * w, y: CGFloat(cells.top) * h,
                      width: CGFloat(cells.width) * w, height: CGFloat(cells.height) * h)
    }

    func contains(_ cells: SnapCells) -> Bool {
        cells.left >= 0 && cells.top >= 0 && cells.right <= columns && cells.bottom <= rows && cells.width >= 1 && cells.height >= 1
    }
}

/// A block on the snap grid, by the lines at its edges: from `left` to
/// `right` across, `top` to `bottom` down.
struct SnapCells: Equatable {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int

    var width: Int { right - left }
    var height: Int { bottom - top }

    enum Edge { case left, right, top, bottom }

    /// Moved a step at a time, as far as the grid goes: at its edge, that way stays put.
    func moved(dx: Int, dy: Int, in grid: SnapGrid) -> SnapCells {
        var c = self
        if left + dx >= 0, right + dx <= grid.columns {
            c.left += dx
            c.right += dx
        }
        if top + dy >= 0, bottom + dy <= grid.rows {
            c.top += dy
            c.bottom += dy
        }
        return c
    }

    /// That edge moved `by` steps outwards (inwards when negative), if the
    /// block stays on the grid and at least a step wide.
    func pushed(_ edge: Edge, by d: Int, in grid: SnapGrid) -> SnapCells {
        var c = self
        switch edge {
        case .left: c.left -= d
        case .right: c.right += d
        case .top: c.top -= d
        case .bottom: c.bottom += d
        }
        return grid.contains(c) ? c : self
    }

    /// A step wider (or narrower), or taller (or shorter), as dragging the
    /// bottom right corner does: the top left stays. A side against the
    /// edge of the display stays instead, so a window in the right half
    /// grows to the left; one that fills that way can only get smaller.
    func resized(across: Bool, by d: Int, in grid: SnapGrid) -> SnapCells {
        let (low, high, count) = across ? (left, right, grid.columns) : (top, bottom, grid.rows)
        let (near, far): (Edge, Edge) = across ? (.left, .right) : (.top, .bottom)
        // The far side stays when it's against the display and the near one isn't.
        let keepFar = high == count && low != 0
        if d > 0, high == count, low == 0 { return self }
        return pushed(keepFar ? near : far, by: d, in: grid)
    }

    /// Both ends of one way a step out (or in): across, or down. Each only as
    /// far as the grid lets it, so against an edge the other end goes alone.
    func spread(across: Bool, by d: Int, in grid: SnapGrid) -> SnapCells {
        across ? pushed(.left, by: d, in: grid).pushed(.right, by: d, in: grid)
               : pushed(.top, by: d, in: grid).pushed(.bottom, by: d, in: grid)
    }

    /// Every edge a step out (or in), each one only as far as the grid lets it.
    func inflated(by d: Int, in grid: SnapGrid) -> SnapCells {
        var c = self
        for edge in [Edge.left, .right, .top, .bottom] { c = c.pushed(edge, by: d, in: grid) }
        return c
    }
}
