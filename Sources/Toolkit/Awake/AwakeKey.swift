import AppKit
import Carbon.HIToolbox

/// Keep Awake's one shortcut, as a Carbon hot key: no permission needed, and
/// it never sees other keys.
final class AwakeKey {
    var onPress: (() -> Void)?
    /// macOS refused it, usually because another app has it.
    private(set) var failed = false

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var shortcut: Shortcut?
    private var suspended = false

    private static let signature = OSType(0x544B_4B41)  // "TKKA"

    func set(_ shortcut: Shortcut?) {
        guard shortcut != self.shortcut else { return }
        self.shortcut = shortcut
        installHandler()
        register()
    }

    /// While a shortcut is being recorded, so the keys reach the recorder.
    func suspend(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        register()
    }

    private func register() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        failed = false
        guard let shortcut, !suspended else { return }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            failed = true
            NSLog("Toolkit: Keep Awake shortcut \(shortcut.display) not registered (\(status))")
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == AwakeKey.signature else { return OSStatus(eventNotHandledErr) }
            let key = Unmanaged<AwakeKey>.fromOpaque(refcon!).takeUnretainedValue()
            DispatchQueue.main.async { key.onPress?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
