import Foundation
import IOKit.hid
import os

/// The buttons a mouse keeps to itself (a DPI switch), taken through its HID++
/// channel: each control given an action is diverted, so the mouse reports it
/// pressed and let go instead of acting on it. A divert lasts until the mouse
/// disconnects, so it is made again each time the mouse comes back, and undone
/// when the tool stops or a button's action is taken away. After a crash the
/// mouse keeps it until it reconnects or the next launch sets it straight.
///
/// Everything here lives on a thread of its own: a request waits for the
/// mouse's reply, which can take a moment over Bluetooth.
final class HIDPPButtons {
    /// On the main thread: a mouse (by `MouseIdentity.key`), a control, and down or up.
    var onPress: (String, UInt16, Bool) -> Void = { _, _, _ in }
    /// On the main thread: each mouse's controls that can be diverted, by key.
    var onControls: ([String: [HIDPPChannel.Control]]) -> Void = { _ in }

    private final class Mouse {
        let key: String
        let channel: HIDPPChannel
        let feature: UInt8
        var controls: [HIDPPChannel.Control]
        var diverted: Set<UInt16> = []
        var pressed: Set<UInt16> = []
        init(key: String, channel: HIDPPChannel, feature: UInt8, controls: [HIDPPChannel.Control]) {
            self.key = key; self.channel = channel; self.feature = feature; self.controls = controls
        }
    }

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?
    private var mice: [UnsafeMutableRawPointer: Mouse] = [:]
    /// Devices macOS wouldn't open, tried again on the next `set`.
    private var refused: [UnsafeMutableRawPointer: IOHIDDevice] = [:]
    private var desired: [String: Set<UInt16>] = [:]
    /// While a button is being chosen on the page: every control offered is
    /// asked for, so a press of one says which it is.
    private var learning = false

    var isRunning: Bool { thread != nil }

    func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatchingMultiple(manager, HIDPPChannel.matching as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
                let buttons = Unmanaged<HIDPPButtons>.fromOpaque(context!).takeUnretainedValue()
                buttons.later { buttons.added(device) }
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
                let buttons = Unmanaged<HIDPPButtons>.fromOpaque(context!).takeUnretainedValue()
                buttons.later { buttons.removed(device) }
            }, context)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            self.manager = manager
            ready.signal()
            // A port to keep the loop running until stop() ends it.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "dev.jalves.macos-toolkit.hidpp"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
        ready.wait()
    }

    /// Lets every control go back to the mouse, then ends the thread.
    func stop() {
        guard let thread else { return }
        let done = DispatchSemaphore(value: 0)
        perform { [self] in
            for mouse in mice.values { for cid in mouse.diverted { mouse.channel.setDiverted(cid, false, feature: mouse.feature) } }
            mice.removeAll()
            refused.removeAll()
            if let manager { IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) }
            manager = nil
            done.signal()
        }
        // On quit the undo must reach the mouse before the process ends.
        _ = done.wait(timeout: .now() + 2)
        thread.cancel()
        self.thread = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
    }

    /// While on, every button the mice keep to themselves reports to us, so
    /// pressing one can name it; off, back to only those with an action.
    func learn(_ on: Bool) {
        perform { [self] in
            learning = on
            for mouse in mice.values { apply(mouse) }
        }
    }

    /// The controls to take from each mouse; any not listed are given back.
    func set(_ wanted: [String: Set<UInt16>]) {
        perform { [self] in
            desired = wanted
            for (id, device) in refused { refused[id] = nil; added(device) }
            for mouse in mice.values { apply(mouse) }
        }
    }

    private func perform(_ work: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in self?.later(work) }
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `work` once no request is waiting for its reply: run from inside
    /// one's wait, a second request would take the first one's reply.
    private func later(_ work: @escaping () -> Void) {
        guard HIDPPChannel.waiting > 0 else { return work() }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.02, 0, 0, 0) { [weak self] _ in self?.later(work) }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
    }

    // MARK: - On the thread

    private func added(_ device: IOHIDDevice) {
        let id = Unmanaged.passUnretained(device).toOpaque()
        guard mice[id] == nil else { return }
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        // Only a mouse connected directly: through a receiver the channel is the
        // receiver's, and which mouse it means isn't known here.
        let pairs = prop(kIOHIDDeviceUsagePairsKey) as? [[String: Int]] ?? []
        guard pairs.contains(where: { $0[kIOHIDDeviceUsagePageKey] == kHIDPage_GenericDesktop && $0[kIOHIDDeviceUsageKey] == kHIDUsage_GD_Mouse }),
              let identity = MouseIdentity(prop, entry: IOHIDDeviceGetService(device)) else { return }
        guard let channel = HIDPPChannel(device) else {
            refused[id] = device
            return
        }
        guard channel.findIndex(), let feature = channel.featureIndex(HIDPPChannel.reprogControls) else { return }
        // A DPI switch is marked a mouse button too: what tells it apart is that macOS never sees it.
        let controls = (channel.controls() ?? []).filter(\.offered)
        let mouse = Mouse(key: identity.key, channel: channel, feature: feature, controls: controls)
        channel.onNotification = { [weak self, weak mouse] bytes in
            guard let self, let mouse else { return }
            self.notified(mouse, bytes)
        }
        mice[id] = mouse
        Log.mouse.notice("hid++ channel open: \(controls.count, privacy: .public) controls that can be diverted")
        apply(mouse)
        publish()
    }

    private func removed(_ device: IOHIDDevice) {
        let id = Unmanaged.passUnretained(device).toOpaque()
        refused[id] = nil
        guard let mouse = mice.removeValue(forKey: id) else { return }
        // Released buttons it can no longer report.
        for cid in mouse.pressed { press(mouse.key, cid, false) }
        publish()
    }

    private func apply(_ mouse: Mouse) {
        let all = Set(mouse.controls.map(\.cid))
        let wanted = learning ? all : (desired[mouse.key] ?? []).intersection(all)
        for cid in wanted.subtracting(mouse.diverted) where mouse.channel.setDiverted(cid, true, feature: mouse.feature) {
            mouse.diverted.insert(cid)
            Log.mouse.notice("hid++ control diverted: \(String(format: "%04X", cid), privacy: .public)")
        }
        for cid in mouse.diverted.subtracting(wanted) {
            mouse.channel.setDiverted(cid, false, feature: mouse.feature)
            mouse.diverted.remove(cid)
            if mouse.pressed.remove(cid) != nil { press(mouse.key, cid, false) }
        }
    }

    /// The diverted-buttons event: every diverted control held now, up to four.
    private func notified(_ mouse: Mouse, _ bytes: [UInt8]) {
        guard bytes.count >= 12, bytes[2] == mouse.feature, bytes[3] >> 4 == 0 else { return }
        var now = Set<UInt16>()
        for i in stride(from: 4, to: 12, by: 2) {
            let cid = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            if cid != 0 { now.insert(cid) }
        }
        for cid in now.subtracting(mouse.pressed) { press(mouse.key, cid, true) }
        for cid in mouse.pressed.subtracting(now) { press(mouse.key, cid, false) }
        mouse.pressed = now
    }

    private func press(_ key: String, _ cid: UInt16, _ down: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onPress(key, cid, down) }
    }

    private func publish() {
        var list: [String: [HIDPPChannel.Control]] = [:]
        for mouse in mice.values { list[mouse.key] = mouse.controls }
        DispatchQueue.main.async { [weak self] in self?.onControls(list) }
    }
}
