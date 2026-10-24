import AppKit
import Carbon.HIToolbox

/// Something a shortcut does to the focused window. The default keys are
/// the ones people already know for these, so muscle memory carries over.
enum LayoutAction: String, Codable, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, almostMaximize, maximizeHeight, center, larger, smaller, restore
    case previousDisplay, nextDisplay
    /// macOS's Show Desktop, on and off: no one window.
    case showDesktop
    /// For windows sharing a slot as tabs.
    case nextTab, previousTab, takeOutOfTabs, joinTabs

    /// Act on the tabs of the focused window rather than move it.
    var isTabs: Bool { [.nextTab, .previousTab, .takeOutOfTabs, .joinTabs].contains(self) }

    var title: String {
        switch self {
        case .leftHalf: return String(localized: "Left half")
        case .rightHalf: return String(localized: "Right half")
        case .topHalf: return String(localized: "Top half")
        case .bottomHalf: return String(localized: "Bottom half")
        case .topLeft: return String(localized: "Top left")
        case .topRight: return String(localized: "Top right")
        case .bottomLeft: return String(localized: "Bottom left")
        case .bottomRight: return String(localized: "Bottom right")
        case .firstThird: return String(localized: "First third")
        case .centerThird: return String(localized: "Center third")
        case .lastThird: return String(localized: "Last third")
        case .firstTwoThirds: return String(localized: "First two thirds")
        case .lastTwoThirds: return String(localized: "Last two thirds")
        case .maximize: return String(localized: "Maximize")
        case .almostMaximize: return String(localized: "Almost maximize")
        case .maximizeHeight: return String(localized: "Maximize height")
        case .center: return String(localized: "Center")
        case .larger: return String(localized: "Larger")
        case .smaller: return String(localized: "Smaller")
        case .restore: return String(localized: "Restore")
        case .previousDisplay: return String(localized: "Previous display")
        case .nextDisplay: return String(localized: "Next display")
        case .showDesktop: return String(localized: "Show the desktop")
        case .nextTab: return String(localized: "Next window in the stack")
        case .previousTab: return String(localized: "Previous window in the stack")
        case .takeOutOfTabs: return String(localized: "Take the window out of its stack")
        case .joinTabs: return String(localized: "Stack with the window under it")
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
        // ⌃⌥D is the first third.
        case .showDesktop: return key(kVK_ANSI_D, "D", co.union(.command))
        case .nextTab: return key(kVK_Tab)
        case .previousTab: return key(kVK_Tab, nil, co.union(.shift))
        case .takeOutOfTabs: return key(kVK_Delete, nil, co.union(.shift))
        case .joinTabs: return key(kVK_Return, nil, co.union(.shift))
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

/// What's offered for the rest of a display after a window is dropped into
/// part of it: nothing, the switcher's list, or its pictures.
enum SuggestStyle: String, Codable, CaseIterable {
    case off, list, previews

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .list: return String(localized: "List")
        case .previews: return String(localized: "Previews")
        }
    }
}

/// Whether windows on other displays are offered for the rest of one.
enum SuggestFrom: String, Codable, CaseIterable {
    /// Only this display's.
    case display
    /// This display's, or the others' when it has none.
    case fallback
    /// This display's first, then the others'.
    case all

    var title: String {
        switch self {
        case .display: return String(localized: "Only this display's")
        case .fallback: return String(localized: "Others' if it has none")
        case .all: return String(localized: "Always, after its own")
        }
    }
}

/// Whether windows can be stacked in a slot: with `tabsKey` held while a
/// window is dragged, the windows it can stack with are outlined.
enum TabsJoin: String, Codable, CaseIterable {
    case off
    case key

    var title: String { self == .off ? String(localized: "Off") : String(localized: "On") }

    init(from decoder: Decoder) throws {
        // An "always" from before is on.
        self = (try decoder.singleValueContainer().decode(String.self)) == "off" ? .off : .key
    }
}

/// Where a slot's tabs go.
enum TabsPosition: String, Codable, CaseIterable {
    case bottom, top

    var title: String { self == .bottom ? String(localized: "Bottom") : String(localized: "Top") }
}

/// The compact pill, a small bar of app icons over the window's bottom edge,
/// is left out of 0.13.0. Its code is kept below, commented out. To solve
/// before it comes back:
/// - It sits on its window, so a window coming forward (a click in it, ⌘Tab,
///   picking a tab) covers it until it's ordered above again: it flashes for
///   up to a second. Ordering it again after each raise wasn't enough.
/// - Floating it over every ordinary window (`.floating`) stops that, but then
///   it must be hidden whenever another window covers its spot, and macOS
///   says nothing when a window comes forward: clicks and keys were watched
///   for it, untested (the start of it is in `TabStrip.show`).
/// How a slot's tabs look. Only the strip for now; with the pill back, it
/// becomes a setting again (`tabsStyle` in the config, "Look" in the settings).
enum TabsStyle: String, Codable, CaseIterable {
    /// A strip of tabs with titles, in a band of its own.
    case strip
    // /// A small pill of app icons over the window's edge.
    // case pill

    var title: String { String(localized: "Tabs") }
    // var title: String { self == .strip ? "Tabs" : "Compact" }
}

/// The modifiers for picking a tab by number, 1 to 9.
enum TabNumbers: String, Codable, CaseIterable {
    case off, controlOption, controlOptionCommand

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .controlOption: return String(localized: "⌃⌥ 1–9")
        case .controlOptionCommand: return String(localized: "⌃⌥⌘ 1–9")
        }
    }

    var flags: NSEvent.ModifierFlags? {
        switch self {
        case .off: return nil
        case .controlOption: return [.control, .option]
        case .controlOptionCommand: return [.control, .option, .command]
        }
    }
}

/// The key held while dragging a window to place it on the grid.
enum DragModifier: String, Codable, CaseIterable {
    case none, shift, control, option, command

    var title: String {
        switch self {
        case .none: return String(localized: "Off")
        case .shift: return String(localized: "⇧")
        case .control: return String(localized: "⌃")
        case .option: return String(localized: "⌥")
        case .command: return String(localized: "⌘")
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
    /// A part in the menu bar, whose panel places the front window.
    var menuBarIcon = false
    /// Only the changed ones, by action; the rest are the defaults.
    var shortcuts: [String: Shortcut] = [:]
    var gridShortcut = Self.defaultGridShortcut
    /// By display UUID, so each monitor keeps its own.
    var grids: [String: GridSize] = [:]
    /// Points between windows and around the edges of the display. 8 is
    /// macOS's own margin, so its Fill and ours look the same.
    var gap: Double = 8
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
    /// After a window is dropped into part of a display (an edge, a layout),
    /// the other windows there are offered for the rest. Pictures fall back
    /// to the list without Screen Recording.
    var suggest = SuggestStyle.previews
    var suggestFrom = SuggestFrom.fallback
    /// Several windows in one slot, one shown at a time.
    var tabsJoin = TabsJoin.off
    var tabsKey = DragModifier.control
    var tabsPosition = TabsPosition.bottom
    // var tabsStyle = TabsStyle.strip
    var tabNumbers = TabNumbers.controlOption

    /// ⌃⌥Space is macOS's "next input source".
    static let defaultGridShortcut = Shortcut(keyCode: kVK_Space, flags: [.control, .option, .command])

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        menuBarIcon = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarIcon)) ?? false
        shortcuts = (try? c.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts)) ?? [:]
        gridShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .gridShortcut)) ?? Self.defaultGridShortcut
        grids = (try? c.decodeIfPresent([String: GridSize].self, forKey: .grids)) ?? [:]
        gap = min(max(try c.decodeIfPresent(Double.self, forKey: .gap) ?? 8, 0), 40)
        cycleAtEdge = try c.decodeIfPresent(Bool.self, forKey: .cycleAtEdge) ?? false
        edgeSnapping = try c.decodeIfPresent(Bool.self, forKey: .edgeSnapping) ?? true
        dragGrid = (try? c.decodeIfPresent(DragModifier.self, forKey: .dragGrid)) ?? .shift
        dragSlots = (try? c.decodeIfPresent(DragModifier.self, forKey: .dragSlots)) ?? .option
        // One key can't do both.
        if dragSlots == dragGrid { dragGrid = .none }
        restoreOnDragOut = try c.decodeIfPresent(Bool.self, forKey: .restoreOnDragOut) ?? true
        holdAtEdges = try c.decodeIfPresent(Bool.self, forKey: .holdAtEdges) ?? false
        suggest = (try? c.decodeIfPresent(SuggestStyle.self, forKey: .suggest)) ?? .previews
        suggestFrom = (try? c.decodeIfPresent(SuggestFrom.self, forKey: .suggestFrom)) ?? .fallback
        tabsJoin = (try? c.decodeIfPresent(TabsJoin.self, forKey: .tabsJoin)) ?? .off
        tabsKey = (try? c.decodeIfPresent(DragModifier.self, forKey: .tabsKey)) ?? .control
        tabsPosition = (try? c.decodeIfPresent(TabsPosition.self, forKey: .tabsPosition)) ?? .bottom
        // tabsStyle = (try? c.decodeIfPresent(TabsStyle.self, forKey: .tabsStyle)) ?? .strip
        tabNumbers = (try? c.decodeIfPresent(TabNumbers.self, forKey: .tabNumbers)) ?? .controlOption
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
