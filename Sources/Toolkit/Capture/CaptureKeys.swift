import AppKit
import os
import Carbon.HIToolbox

/// The capture shortcuts. macOS handles its own screenshot shortcuts before
/// anyone else sees the keys, so the ones that clash with ours are switched
/// off while ours are on; the rest are left as they are.
final class CaptureKeys {
    enum Action: Equatable {
        case screen(copy: Bool)
        case area(copy: Bool)
        case text
        case toolbar
    }

    struct Bindings: Equatable {
        var screen: Shortcut?
        var area: Shortcut?
        var text: Shortcut?
        var toolbar: Shortcut?
    }

    var onAction: ((Action) -> Void)?

    /// macOS's screenshot shortcuts, with the keys they have out of the box:
    /// ⇧⌘3, ⌃⇧⌘3, ⇧⌘4, ⌃⇧⌘4, ⇧⌘5.
    private static let system: [(id: Int32, shortcut: Shortcut)] = [
        (28, Shortcut(keyCode: kVK_ANSI_3, flags: [.shift, .command])),
        (29, Shortcut(keyCode: kVK_ANSI_3, flags: [.control, .shift, .command])),
        (30, Shortcut(keyCode: kVK_ANSI_4, flags: [.shift, .command])),
        (31, Shortcut(keyCode: kVK_ANSI_4, flags: [.control, .shift, .command])),
        (184, Shortcut(keyCode: kVK_ANSI_5, flags: [.shift, .command])),
    ]

    private var refs: [EventHotKeyRef] = []
    private var actions: [Action] = []
    private var handler: EventHandlerRef?
    private var bindings: Bindings?
    private var suspended = false

    /// Registers the shortcuts, replacing any registered before.
    func start(_ bindings: Bindings) {
        guard bindings != self.bindings else { return }
        self.bindings = bindings
        installHandler()
        register()
        // Only the system shortcuts that clash with ours are switched off.
        let ours = Self.combos(bindings).map(\.0)
        let prefs = Self.systemPrefs()
        for (id, fallback) in Self.system {
            let entry = prefs[String(id)]
            if ours.contains(Self.systemShortcut(entry) ?? fallback) {
                CGSSetSymbolicHotKeyEnabled(id, false)
            } else {
                CGSSetSymbolicHotKeyEnabled(id, Self.systemEnabled(entry))
            }
        }
    }

    func stop() {
        guard bindings != nil else { return }
        bindings = nil
        unregister()
        Self.restoreSystem()
    }

    /// While a shortcut is being recorded in the settings, ours step aside so
    /// the keys reach the recorder. macOS's stay off meanwhile.
    func suspend(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        register()
    }

    /// Puts macOS's shortcuts back as System Settings has them. Also run at
    /// launch, in case a crash left them off.
    static func restoreSystem() {
        let prefs = systemPrefs()
        for (id, _) in system { CGSSetSymbolicHotKeyEnabled(id, systemEnabled(prefs[String(id)])) }
    }

    // MARK: - Registration

    /// Each shortcut with its action, plus ⌃ versions that copy. Text is
    /// always copied, so it has none.
    private static func combos(_ b: Bindings) -> [(Shortcut, Action)] {
        var list: [(Shortcut, Action)] = []
        func add(_ shortcut: Shortcut?, _ action: (Bool) -> Action) {
            guard let shortcut else { return }
            list.append((shortcut, action(false)))
            if !shortcut.flags.contains(.control) { list.append((shortcut.adding(.control), action(true))) }
        }
        add(b.screen) { .screen(copy: $0) }
        add(b.area) { .area(copy: $0) }
        if let text = b.text { list.append((text, .text)) }
        if let toolbar = b.toolbar { list.append((toolbar, .toolbar)) }
        // The same keys twice would register only once anyway.
        var seen: [Shortcut] = []
        return list.filter { combo in
            defer { seen.append(combo.0) }
            return !seen.contains(combo.0)
        }
    }

    private func register() {
        unregister()
        guard let bindings, !suspended else { return }
        for (index, (shortcut, action)) in Self.combos(bindings).enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x544B_4350), id: UInt32(index))  // "TKCP"
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                Log.capture.error("capture shortcut \(shortcut.display, privacy: .public) not registered (\(status))")
            }
            actions.append(action)
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let keys = Unmanaged<CaptureKeys>.fromOpaque(refcon!).takeUnretainedValue()
            let index = Int(hotKeyID.id)
            guard hotKeyID.signature == OSType(0x544B_4350), keys.actions.indices.contains(index) else { return OSStatus(eventNotHandledErr) }
            let action = keys.actions[index]
            DispatchQueue.main.async { keys.onAction?(action) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    // MARK: - macOS's settings

    private static func systemPrefs() -> [String: [String: Any]] {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: [String: Any]] ?? [:]
    }

    /// Missing from the file means never changed, which is on.
    private static func systemEnabled(_ entry: [String: Any]?) -> Bool {
        (entry?["enabled"] as? NSNumber)?.boolValue ?? true
    }

    /// The keys set in System Settings, when they were changed there.
    private static func systemShortcut(_ entry: [String: Any]?) -> Shortcut? {
        guard let value = entry?["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count == 3
        else { return nil }
        return Shortcut(keyCode: parameters[1].intValue, flags: NSEvent.ModifierFlags(rawValue: parameters[2].uintValue))
    }
}
