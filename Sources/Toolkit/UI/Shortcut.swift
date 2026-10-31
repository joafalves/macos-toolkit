import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key with modifiers, as a tool's shortcut.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    /// `NSEvent.ModifierFlags` raw value: only ⌘ ⌥ ⌃ ⇧ are kept.
    var modifiers: UInt
    /// The key as it was typed, for showing. Shortcuts are matched by key
    /// code, so this is only a label.
    var key: String

    static let commandTab = Shortcut(keyCode: kVK_Tab, flags: [.command])
    /// ⌘ and the key above Tab, wherever the keyboard has it: on an ISO
    /// keyboard that key has a code of its own, and macOS's ⌘` is beside Z.
    static var commandAboveTab: Shortcut {
        let iso = Int(KBGetLayoutType(Int16(LMGetKbdType()))) == Int(kKeyboardISO)
        let code = iso ? kVK_ISO_Section : kVK_ANSI_Grave
        return Shortcut(keyCode: code, flags: [.command], key: typed(code)?.uppercased())
    }
    /// A cleared shortcut. Stored as a value rather than left out, so a
    /// cleared one doesn't come back as the default.
    static let none = Shortcut(keyCode: -1, flags: [], key: "")

    var isNone: Bool { keyCode < 0 }
    /// nil for `none`.
    var active: Shortcut? { isNone ? nil : self }

    init(keyCode: Int, flags: NSEvent.ModifierFlags, key: String? = nil) {
        self.keyCode = keyCode
        modifiers = flags.intersection(Self.relevant).rawValue
        self.key = key ?? Self.name(of: keyCode) ?? "?"
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let key = Self.name(of: Int(event.keyCode)) ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard !key.isEmpty else { return nil }
        self.init(keyCode: Int(event.keyCode), flags: event.modifierFlags, key: key)
    }

    static func == (a: Shortcut, b: Shortcut) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    private static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Has a modifier that can be held: ⌘, ⌥ or ⌃.
    var hasHoldableModifier: Bool { !flags.isDisjoint(with: [.command, .option, .control]) }

    func adding(_ flag: NSEvent.ModifierFlags) -> Shortcut {
        Shortcut(keyCode: keyCode, flags: flags.union(flag), key: key)
    }

    /// The modifiers alone, in the order macOS shows them.
    static func glyphs(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    var display: String { isNone ? String(localized: "Shortcut.none", defaultValue: "None", comment: "A shortcut that is not set; masculine in Portuguese, unlike a gap's None") : Self.glyphs(flags) + key }

    var carbonModifiers: UInt32 {
        var value = 0
        if flags.contains(.command) { value |= cmdKey }
        if flags.contains(.option) { value |= optionKey }
        if flags.contains(.control) { value |= controlKey }
        if flags.contains(.shift) { value |= shiftKey }
        return UInt32(value)
    }

    var cgFlags: CGEventFlags {
        var value: CGEventFlags = []
        if flags.contains(.command) { value.insert(.maskCommand) }
        if flags.contains(.option) { value.insert(.maskAlternate) }
        if flags.contains(.control) { value.insert(.maskControl) }
        if flags.contains(.shift) { value.insert(.maskShift) }
        return value
    }

    /// What the key types with no modifiers, on the keyboard layout in use.
    /// On the main thread: the layout can't be asked for elsewhere.
    static func typed(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    /// Keys whose typed character is missing or unhelpful.
    static func name(of keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Tab: return "⇥"
        case kVK_Space: return String(localized: "Space")
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        default: return nil
        }
    }
}

/// While a shortcut is being typed into a recorder, tools let their own
/// shortcuts through, so pressing ⇧⌘4 or ⌘Tab records it instead.
enum ShortcutRecording {
    static let changed = Notification.Name("dev.jalves.macos-toolkit.shortcut-recording")
    /// Read by event taps on their own threads.
    private static let state = Locked(false)
    static var active: Bool { state.value }

    static func set(_ on: Bool) {
        guard on != active else { return }
        state.value = on
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// A shortcut setting: click, then press the keys. Esc cancels, Delete clears
/// (when `optional`), and the arrow puts the default back.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let defaultValue: Shortcut
    var optional = true
    /// Shortcuts already used by the same tool, refused with a beep.
    var taken: [Shortcut] = []

    @StateObject private var model = ShortcutRecorderModel()

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Group { if model.recording, model.live.isEmpty { Text("Type Shortcut") } else { Text(verbatim: model.recording ? model.live : shortcut.display) } }
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundStyle(model.recording ? Color.accentColor : shortcut.isNone ? .secondary : .primary)
                    .frame(minWidth: 96)
            }
            .help(!model.recording ? "Click to change" : optional ? "Press the keys. Esc cancels, Delete clears." : "Press the keys. Esc cancels.")
            if shortcut != defaultValue, !model.recording, !taken.contains(defaultValue) {
                Button { shortcut = defaultValue } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Back to \(defaultValue.display)")
            }
        }
        .onDisappear { model.stop() }
    }

    private func toggle() {
        if model.recording { return model.stop() }
        model.start { event in
            let plain = event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
            if plain, event.keyCode == UInt16(kVK_Escape) { return model.stop() }
            if plain, optional, [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
                shortcut = .none
                return model.stop()
            }
            guard let typed = Shortcut(event: event), typed.hasHoldableModifier, !taken.contains(typed) else {
                return NSSound.beep()
            }
            shortcut = typed
            model.stop()
        }
    }
}

final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var recording = false
    /// The modifiers held so far, shown while recording.
    @Published private(set) var live = ""
    private var monitor: Any?
    private var resign: NSObjectProtocol?
    /// One recorder at a time: a second one ending would otherwise give the
    /// tools their shortcuts back while the first still records.
    private static weak var current: ShortcutRecorderModel?

    /// `handle` gets each key press until `stop()`.
    func start(_ handle: @escaping (NSEvent) -> Void) {
        if Self.current !== self { Self.current?.stop() }
        Self.current = self
        stop()
        recording = true
        ShortcutRecording.set(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            if event.type == .flagsChanged {
                self?.live = Shortcut.glyphs(event.modifierFlags)
                return event
            }
            handle(event)
            return nil
        }
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        if recording { ShortcutRecording.set(false) }
        recording = false
        live = ""
    }
}
