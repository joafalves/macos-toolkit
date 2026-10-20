import AppKit
import Carbon.HIToolbox

/// The screenshot shortcuts, taken from macOS while on. macOS handles its own
/// before anyone else sees the keys, so its shortcuts are switched off and
/// ours registered in their place.
final class CaptureKeys {
    enum Action {
        case screen(copy: Bool)
        case area(copy: Bool)
        case toolbar
    }

    var onAction: ((Action) -> Void)?

    /// macOS's IDs: ⇧⌘3, ⌃⇧⌘3, ⇧⌘4, ⌃⇧⌘4, ⇧⌘5.
    private static let systemIDs: [Int32] = [28, 29, 30, 31, 184]

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var active = false

    func start() {
        guard !active else { return }
        active = true
        for id in Self.systemIDs { CGSSetSymbolicHotKeyEnabled(id, false) }
        installHandler()
        let shiftCmd = UInt32(cmdKey | shiftKey)
        let ctrl = UInt32(controlKey)
        register(kVK_ANSI_3, shiftCmd, id: 1)
        register(kVK_ANSI_3, shiftCmd | ctrl, id: 2)
        register(kVK_ANSI_4, shiftCmd, id: 3)
        register(kVK_ANSI_4, shiftCmd | ctrl, id: 4)
        register(kVK_ANSI_5, shiftCmd, id: 5)
    }

    func stop() {
        guard active else { return }
        active = false
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        Self.restoreSystem()
    }

    /// Puts macOS's shortcuts back as System Settings has them. Also run at
    /// launch, in case a crash left them off.
    static func restoreSystem() {
        let prefs = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        for id in systemIDs {
            let entry = prefs?[String(id)] as? [String: Any]
            // Missing from the file means never changed, which is on.
            let enabled = (entry?["enabled"] as? NSNumber)?.boolValue ?? true
            CGSSetSymbolicHotKeyEnabled(id, enabled)
        }
    }

    private func register(_ key: Int, _ modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x544B_4350), id: id)  // "TKCP"
        let status = RegisterEventHotKey(UInt32(key), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) } else { NSLog("Toolkit: capture shortcut \(id) not registered (\(status))") }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let keys = Unmanaged<CaptureKeys>.fromOpaque(refcon!).takeUnretainedValue()
            let action: Action?
            switch hotKeyID.id {
            case 1: action = .screen(copy: false)
            case 2: action = .screen(copy: true)
            case 3: action = .area(copy: false)
            case 4: action = .area(copy: true)
            case 5: action = .toolbar
            default: action = nil
            }
            if let action { DispatchQueue.main.async { keys.onAction?(action) } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
