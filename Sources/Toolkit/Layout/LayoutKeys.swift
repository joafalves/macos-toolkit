import AppKit
import os
import Carbon.HIToolbox

/// The layout shortcuts, as Carbon hot keys: they need no permission and
/// never see other keys.
final class LayoutKeys {
    enum Command: Equatable {
        case action(LayoutAction)
        case grid
        /// The tab at this place, from 0, in the focused window's slot.
        case tab(Int)
    }

    var onCommand: ((Command) -> Void)?
    /// The shortcuts macOS refused, usually because another app has them.
    private(set) var failed: [Command] = []

    private var refs: [EventHotKeyRef] = []
    private var commands: [Command] = []
    private var handler: EventHandlerRef?
    private var bindings: [(Shortcut, Command)]?
    private var suspended = false

    private static let signature = OSType(0x544B_574C)  // "TKWL"

    func start(_ bindings: [(Shortcut, Command)]) {
        if let current = self.bindings, current.elementsEqual(bindings, by: { $0.0 == $1.0 && $0.1 == $1.1 }) { return }
        self.bindings = bindings
        installHandler()
        register()
    }

    func stop() {
        guard bindings != nil else { return }
        bindings = nil
        unregister()
        failed = []
    }

    /// While a shortcut is being recorded in the settings, ours step aside so
    /// the keys reach the recorder.
    func suspend(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        register()
    }

    private func register() {
        unregister()
        guard let bindings, !suspended else { return }
        var failed: [Command] = []
        for (index, (shortcut, command)) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append(command)
                Log.layout.error("shortcut \(shortcut.display, privacy: .public) not registered (\(status))")
            }
            commands.append(command)
        }
        self.failed = failed
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        commands.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let keys = Unmanaged<LayoutKeys>.fromOpaque(refcon!).takeUnretainedValue()
            let index = Int(hotKeyID.id)
            guard hotKeyID.signature == LayoutKeys.signature, keys.commands.indices.contains(index) else { return OSStatus(eventNotHandledErr) }
            let command = keys.commands[index]
            DispatchQueue.main.async { keys.onCommand?(command) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
