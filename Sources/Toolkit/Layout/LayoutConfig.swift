import AppKit
import Carbon.HIToolbox

/// Something a shortcut does to the focused window. The default keys are
/// Rectangle's, so muscle memory carries over.
enum LayoutAction: String, Codable, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, almostMaximize, maximizeHeight, center, larger, smaller, restore
    case previousDisplay, nextDisplay

    var title: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .firstThird: return "First third"
        case .centerThird: return "Center third"
        case .lastThird: return "Last third"
        case .firstTwoThirds: return "First two thirds"
        case .lastTwoThirds: return "Last two thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost maximize"
        case .maximizeHeight: return "Maximize height"
        case .center: return "Center"
        case .larger: return "Larger"
        case .smaller: return "Smaller"
        case .restore: return "Restore"
        case .previousDisplay: return "Previous display"
        case .nextDisplay: return "Next display"
        }
    }

    var defaultShortcut: Shortcut {
        let co: NSEvent.ModifierFlags = [.control, .option]
        func key(_ code: Int, _ label: String? = nil, _ flags: NSEvent.ModifierFlags = co) -> Shortcut {
            Shortcut(keyCode: code, flags: flags, key: label)
        }
        switch self {
        case .leftHalf: return key(kVK_LeftArrow)
        case .rightHalf: return key(kVK_RightArrow)
        case .topHalf: return key(kVK_UpArrow)
        case .bottomHalf: return key(kVK_DownArrow)
        case .topLeft: return key(kVK_ANSI_U, "U")
        case .topRight: return key(kVK_ANSI_I, "I")
        case .bottomLeft: return key(kVK_ANSI_J, "J")
        case .bottomRight: return key(kVK_ANSI_K, "K")
        case .firstThird: return key(kVK_ANSI_D, "D")
        case .centerThird: return key(kVK_ANSI_F, "F")
        case .lastThird: return key(kVK_ANSI_G, "G")
        case .firstTwoThirds: return key(kVK_ANSI_E, "E")
        case .lastTwoThirds: return key(kVK_ANSI_T, "T")
        case .maximize: return key(kVK_Return)
        case .almostMaximize: return .none
        case .maximizeHeight: return key(kVK_UpArrow, nil, co.union(.shift))
        case .center: return key(kVK_ANSI_C, "C")
        case .larger: return key(kVK_ANSI_Equal, "=")
        case .smaller: return key(kVK_ANSI_Minus, "-")
        case .restore: return key(kVK_Delete)
        case .previousDisplay: return key(kVK_LeftArrow, nil, co.union(.command))
        case .nextDisplay: return key(kVK_RightArrow, nil, co.union(.command))
        }
    }

}

/// The grid for one display, in cells. The letter keys give up to ten
/// columns and, with the number row, four rows.
struct GridSize: Codable, Equatable {
    var columns: Int
    var rows: Int

    static let columnRange = 1...10
    static let rowRange = 1...4

    init(columns: Int, rows: Int) {
        self.columns = min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        self.rows = min(max(rows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(columns: try c.decodeIfPresent(Int.self, forKey: .columns) ?? 4,
                  rows: try c.decodeIfPresent(Int.self, forKey: .rows) ?? 3)
    }

    /// Before a display has a grid of its own: halves, quarters across an
    /// ultrawide, and halves down one that stands upright.
    static func suggested(for size: CGSize) -> GridSize {
        let aspect = size.width / max(size.height, 1)
        if aspect < 1 { return GridSize(columns: 1, rows: 2) }
        return GridSize(columns: aspect >= ultrawideAspect ? 4 : 2, rows: 1)
    }

    /// 21:9 and wider, with room to spare for displays that are nearly there.
    static let ultrawideAspect: CGFloat = 2.1
}

/// The key held while dragging a window to place it on the grid.
enum DragModifier: String, Codable, CaseIterable {
    case none, shift, control, option, command

    var title: String {
        switch self {
        case .none: return "Off"
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .none: return []
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }
}

struct LayoutConfig: Codable, Equatable {
    /// When off, no shortcuts, no snapping, and macOS's own tiling is back.
    var enabled = true
    /// Only the changed ones, by action; the rest are the defaults.
    var shortcuts: [String: Shortcut] = [:]
    var gridShortcut = Self.defaultGridShortcut
    /// By display UUID, so each monitor keeps its own.
    var grids: [String: GridSize] = [:]
    /// Points between windows and around the edges of the display.
    var gap: Double = 0
    /// Pressing a half again goes through its sizes, then on to the next display.
    /// At the outer edge of the last display, left and right pressed again
    /// go through ⅔ and ⅓ instead of stopping. Its own key, so the earlier
    /// always-on version doesn't carry over as on.
    var cycleAtEdge = false
    /// Dragging a window to an edge or a corner of the display snaps it there.
    var edgeSnapping = true
    var dragGrid = DragModifier.shift
    /// Held while dragging: a bar of layouts by the pointer to drop onto.
    /// ⌥, since that's macOS's own key for tiling while dragging.
    var dragSlots = DragModifier.option
    /// A snapped window dragged away gets back the size it had before.
    var restoreOnDragOut = true
    /// While a window is dragged, the pointer stops at an edge between
    /// displays until pushed on, so that edge's snap is easy to hit.
    var holdAtEdges = false

    /// ⌃⌥Space is macOS's "next input source".
    static let defaultGridShortcut = Shortcut(keyCode: kVK_Space, flags: [.control, .option, .command])

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        shortcuts = (try? c.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts)) ?? [:]
        gridShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .gridShortcut)) ?? Self.defaultGridShortcut
        grids = (try? c.decodeIfPresent([String: GridSize].self, forKey: .grids)) ?? [:]
        gap = min(max(try c.decodeIfPresent(Double.self, forKey: .gap) ?? 0, 0), 40)
        cycleAtEdge = try c.decodeIfPresent(Bool.self, forKey: .cycleAtEdge) ?? false
        edgeSnapping = try c.decodeIfPresent(Bool.self, forKey: .edgeSnapping) ?? true
        dragGrid = (try? c.decodeIfPresent(DragModifier.self, forKey: .dragGrid)) ?? .shift
        dragSlots = (try? c.decodeIfPresent(DragModifier.self, forKey: .dragSlots)) ?? .option
        // One key can't do both.
        if dragSlots == dragGrid { dragGrid = .none }
        restoreOnDragOut = try c.decodeIfPresent(Bool.self, forKey: .restoreOnDragOut) ?? true
        holdAtEdges = try c.decodeIfPresent(Bool.self, forKey: .holdAtEdges) ?? false
        // For a while it had strengths; any of them was on.
        if !c.contains(.holdAtEdges), let old = try? decoder.container(keyedBy: Legacy.self).decodeIfPresent(String.self, forKey: .edgeHold) {
            holdAtEdges = old != "off"
        }
    }

    private enum Legacy: String, CodingKey {
        case edgeHold
    }

    func shortcut(_ action: LayoutAction) -> Shortcut {
        shortcuts[action.rawValue] ?? action.defaultShortcut
    }

    mutating func setShortcut(_ shortcut: Shortcut, for action: LayoutAction) {
        shortcuts[action.rawValue] = shortcut == action.defaultShortcut ? nil : shortcut
    }

    /// Whether anything happens while a window is dragged, which is also when
    /// macOS's own edge tiling would get in the way.
    var watchesDrags: Bool { edgeSnapping || dragGrid != .none || dragSlots != .none }

    static var fileURL: URL {
        MouseConfig.fileURL.deletingLastPathComponent().appendingPathComponent("layout.json")
    }

    static func load() -> LayoutConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return LayoutConfig() }
        return (try? JSONDecoder().decode(LayoutConfig.self, from: data)) ?? LayoutConfig()
    }

    func save() {
        let url = LayoutConfig.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
