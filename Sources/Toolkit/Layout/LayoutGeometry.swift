import AppKit
import Carbon.HIToolbox

/// A display as the window code needs it. Taken on the main thread, since
/// NSScreen isn't safe elsewhere, and handed to the work queue.
struct LayoutDisplay: Equatable {
    let id: CGDirectDisplayID
    /// Stays the same for a monitor across reconnects, and differs between
    /// two monitors on the same cable.
    let uuid: String
    let name: String
    /// Core Graphics coordinates: origin at the top left of the main display.
    let frame: CGRect
    /// Without the menu bar and the Dock.
    let usable: CGRect

    init(_ screen: NSScreen) {
        id = screen.displayID
        uuid = Self.uuid(of: screen.displayID)
        name = screen.localizedName
        frame = Coordinates.toCG(screen.frame)
        usable = Coordinates.toCG(screen.visibleFrame)
    }

    init(id: CGDirectDisplayID, uuid: String, name: String, frame: CGRect, usable: CGRect) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.usable = usable
    }

    /// Left to right, the order "next display" goes in.
    static func all() -> [LayoutDisplay] {
        NSScreen.screens.map(LayoutDisplay.init).sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    static func uuid(of id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == id } }
}

enum LayoutGeometry {
    /// How close to an edge counts (a little more than Rectangle's 5), and
    /// how far along an edge a corner reaches.
    static let edgeMargin: CGFloat = 8
    /// An edge against another display has no wall to push against, so the
    /// pointer has to stop short of it, often while moving fast: more room there.
    static let sharedEdgeMargin: CGFloat = 24
    static let cornerSize: CGFloat = 20
    /// The margin macOS leaves around a window it fills, with its margins
    /// on; it has no setting for the size.
    static let macOSMargin: CGFloat = 8
    /// What Larger and Smaller change each side by.
    static let step: CGFloat = 30

    /// A part of a display in fractions of its usable area, top left origin,
    /// placed with `gap` between neighbours and around the edges.
    static func place(_ unit: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        let width = area.width - gap, height = area.height - gap
        let x = (area.minX + gap + unit.minX * width).rounded()
        let y = (area.minY + gap + unit.minY * height).rounded()
        let maxX = (area.minX + unit.maxX * width).rounded()
        let maxY = (area.minY + unit.maxY * height).rounded()
        return CGRect(x: x, y: y, width: max(maxX - x, 1), height: max(maxY - y, 1))
    }

    /// The display under the pointer. Where two displays meet, the row of
    /// pixels belongs to the one it's in, not to its neighbour.
    static func display(at point: CGPoint, in displays: [LayoutDisplay]) -> LayoutDisplay? {
        displays.first { $0.frame.contains(point) } ?? displays.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// The display a window is on: the one with most of it.
    static func display(of frame: CGRect, in displays: [LayoutDisplay]) -> LayoutDisplay? {
        let best = displays.max { area($0.frame.intersection(frame)) < area($1.frame.intersection(frame)) }
        if let best, area(best.frame.intersection(frame)) > 0 { return best }
        return displays.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? displays.first
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    enum Direction { case left, right, up, down }

    /// The nearest display beside this one, in that direction.
    static func neighbour(of display: LayoutDisplay, _ direction: Direction, in displays: [LayoutDisplay]) -> LayoutDisplay? {
        let f = display.frame
        let candidates = displays.filter { other in
            guard other.id != display.id else { return false }
            let o = other.frame
            switch direction {
            case .left: return o.midX < f.midX && o.maxY > f.minY && o.minY < f.maxY
            case .right: return o.midX > f.midX && o.maxY > f.minY && o.minY < f.maxY
            case .up: return o.midY < f.midY && o.maxX > f.minX && o.minX < f.maxX
            case .down: return o.midY > f.midY && o.maxX > f.minX && o.minX < f.maxX
            }
        }
        return candidates.min { distance($0.frame, f) < distance($1.frame, f) }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    /// The fraction of the display an action covers. `step` picks the size
    /// of a left or right half: ½, ⅔, ⅓.
    static func unit(for action: LayoutAction, step: Int = 0, portrait: Bool = false) -> CGRect? {
        let sizes: [CGFloat] = [1 / 2, 2 / 3, 1 / 3]
        let s = sizes[step % sizes.count]
        // Thirds run down a portrait display, across any other.
        func third(_ start: CGFloat, _ length: CGFloat) -> CGRect {
            portrait ? CGRect(x: 0, y: start, width: 1, height: length) : CGRect(x: start, y: 0, width: length, height: 1)
        }
        switch action {
        case .leftHalf: return CGRect(x: 0, y: 0, width: s, height: 1)
        case .rightHalf: return CGRect(x: 1 - s, y: 0, width: s, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .firstThird: return third(0, 1 / 3)
        case .centerThird: return third(1 / 3, 1 / 3)
        case .lastThird: return third(2 / 3, 1 / 3)
        case .firstTwoThirds: return third(0, 2 / 3)
        case .lastTwoThirds: return third(1 / 3, 2 / 3)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        default: return nil
        }
    }

    /// What's left of the display beside a part that runs its whole height
    /// or width from one edge (a half, a third, two thirds): nil for any
    /// other shape, which leaves no single part to fill.
    static func complement(of unit: CGRect) -> CGRect? {
        let e: CGFloat = 0.001
        if abs(unit.minY) < e, abs(unit.height - 1) < e {
            if abs(unit.minX) < e, unit.maxX < 1 - e { return CGRect(x: unit.maxX, y: 0, width: 1 - unit.maxX, height: 1) }
            if abs(unit.maxX - 1) < e, unit.minX > e { return CGRect(x: 0, y: 0, width: unit.minX, height: 1) }
        }
        if abs(unit.minX) < e, abs(unit.width - 1) < e {
            if abs(unit.minY) < e, unit.maxY < 1 - e { return CGRect(x: 0, y: unit.maxY, width: 1, height: 1 - unit.maxY) }
            if abs(unit.maxY - 1) < e, unit.minY > e { return CGRect(x: 0, y: 0, width: 1, height: unit.minY) }
        }
        return nil
    }

    /// Where a left or right half goes next: the display that way, as the
    /// half on its near side.
    static func hop(for action: LayoutAction) -> (Direction, LayoutAction)? {
        switch action {
        case .leftHalf: return (.left, .rightHalf)
        case .rightHalf: return (.right, .leftHalf)
        default: return nil
        }
    }

    // MARK: - Dragging

    /// The snap for a window dropped with the pointer here (Core Graphics
    /// coordinates): a half at a side or the bottom, a quarter in a corner,
    /// the whole display at the top. Edges that lead on to another display count too,
    /// in a wider strip: snapping is only on the drop, so a window still
    /// crosses over when the pointer keeps going.
    static func edgeZone(at point: CGPoint, in displays: [LayoutDisplay]) -> (LayoutDisplay, LayoutAction)? {
        guard let display = display(at: point, in: displays) else { return nil }
        let f = display.frame, u = display.usable
        func shared(_ beyond: CGPoint) -> Bool { displays.contains { $0.frame.contains(beyond) } }
        // Windows stop at the menu bar and the Dock, so the edge is where
        // they stop: the strip covers those and a little more. A little more
        // against another display, where the pointer doesn't stop either.
        func margin(_ beyond: CGPoint) -> CGFloat {
            displays.contains { $0.frame.contains(beyond) } ? sharedEdgeMargin : edgeMargin
        }
        let left = point.x <= u.minX + margin(CGPoint(x: f.minX - 2, y: point.y))
        let right = point.x >= u.maxX - 1 - margin(CGPoint(x: f.maxX + 1, y: point.y))
        let top = point.y <= u.minY + margin(CGPoint(x: point.x, y: f.minY - 2))
        let bottom = point.y >= u.maxY - 1 - margin(CGPoint(x: point.x, y: f.maxY + 1))
        let nearTop = point.y <= u.minY + cornerSize, nearBottom = point.y >= u.maxY - cornerSize
        let nearLeft = point.x <= u.minX + cornerSize, nearRight = point.x >= u.maxX - cornerSize
        let action: LayoutAction?
        if (left && nearTop) || (top && nearLeft) {
            action = .topLeft
        } else if (right && nearTop) || (top && nearRight) {
            action = .topRight
        } else if (left && nearBottom) || (bottom && nearLeft) {
            action = .bottomLeft
        } else if (right && nearBottom) || (bottom && nearRight) {
            action = .bottomRight
        } else if left {
            action = .leftHalf
        } else if right {
            action = .rightHalf
        } else if top {
            action = .maximize
        } else if bottom {
            action = .bottomHalf
        } else {
            action = nil
        }
        return action.map { (display, $0) }
    }
}

/// A block of grid cells, from one corner to the opposite one.
struct CellRange: Equatable {
    var anchor: Cell
    var cursor: Cell

    struct Cell: Equatable {
        var column: Int
        var row: Int

        func clamped(to grid: GridSize) -> Cell {
            Cell(column: min(max(column, 0), grid.columns - 1), row: min(max(row, 0), grid.rows - 1))
        }
    }

    init(_ cell: Cell) {
        anchor = cell
        cursor = cell
    }

    var columns: ClosedRange<Int> { min(anchor.column, cursor.column)...max(anchor.column, cursor.column) }
    var rows: ClosedRange<Int> { min(anchor.row, cursor.row)...max(anchor.row, cursor.row) }

    func contains(_ cell: Cell) -> Bool { columns.contains(cell.column) && rows.contains(cell.row) }

    func unit(in grid: GridSize) -> CGRect {
        let w = 1 / CGFloat(grid.columns), h = 1 / CGFloat(grid.rows)
        return CGRect(x: CGFloat(columns.lowerBound) * w, y: CGFloat(rows.lowerBound) * h,
                      width: CGFloat(columns.count) * w, height: CGFloat(rows.count) * h)
    }

    /// The cell a point falls in, for a point given as a fraction of the display.
    /// Kept to 0...1 first: a display with no size gives no fraction (NaN),
    /// and NaN or a huge value would crash `Int(_:)`. NaN counts as the first cell.
    static func cell(at unit: CGPoint, in grid: GridSize) -> Cell {
        let x = unit.x.isFinite ? min(max(unit.x, 0), 1) : 0, y = unit.y.isFinite ? min(max(unit.y, 0), 1) : 0
        return Cell(column: Int(x * CGFloat(grid.columns)), row: Int(y * CGFloat(grid.rows))).clamped(to: grid)
    }
}

/// The grid's keys, by where they sit on the keyboard rather than what they
/// type, so the top left key is the top left cell on any layout.
enum GridKeys {
    /// Key codes, left to right: the number row, then the three letter rows.
    private static let keyboard: [[Int]] = [
        [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0],
        [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T, kVK_ANSI_Y, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_P],
        [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_Semicolon],
        [kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_N, kVK_ANSI_M, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash],
    ]

    /// Up to three rows use the letters, from the top letter row; four add
    /// the number row above them.
    private static func rows(for grid: GridSize) -> ArraySlice<[Int]> {
        grid.rows >= 4 ? keyboard[0...3] : keyboard[1...grid.rows]
    }

    static func keyCode(for cell: CellRange.Cell, in grid: GridSize) -> Int {
        Array(rows(for: grid))[cell.row][cell.column]
    }

    static func cell(for keyCode: Int, in grid: GridSize) -> CellRange.Cell? {
        for (row, keys) in rows(for: grid).enumerated() {
            if let column = keys.firstIndex(of: keyCode), column < grid.columns { return CellRange.Cell(column: column, row: row) }
        }
        return nil
    }

    /// What the key types on the current keyboard layout, for its label.
    static func labels(for grid: GridSize) -> [Int: String] {
        var labels: [Int: String] = [:]
        let layout = currentLayout()
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let code = keyCode(for: CellRange.Cell(column: column, row: row), in: grid)
                labels[code] = layout.flatMap { character(code, in: $0) } ?? fallback(code)
            }
        }
        return labels
    }

    private static func currentLayout() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private static func character(_ code: Int, in layout: Data) -> String? {
        layout.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text.uppercased()
        }
    }

    /// The US labels, for snapshots, which shouldn't depend on this Mac's layout.
    static func usLabels(for grid: GridSize) -> [Int: String] {
        var labels: [Int: String] = [:]
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let code = keyCode(for: CellRange.Cell(column: column, row: row), in: grid)
                labels[code] = fallback(code)
            }
        }
        return labels
    }

    private static func fallback(_ code: Int) -> String {
        let names = ["1234567890", "QWERTYUIOP", "ASDFGHJKL;", "ZXCVBNM,./"]
        for (row, keys) in keyboard.enumerated() {
            if let column = keys.firstIndex(of: code) {
                return String(Array(names[row])[column])
            }
        }
        return "?"
    }
}
