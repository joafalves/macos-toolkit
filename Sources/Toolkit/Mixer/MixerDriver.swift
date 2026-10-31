import AudioToolbox
import CoreAudio
import CryptoKit
import DriverShared
import Foundation
import os
import Security

/// The audio driver on this Mac: whether it's there, and putting it there.
/// Install and removal run as root for a moment, through macOS's own password
/// dialog, and nothing stays running as root.
enum DriverInstall: Equatable {
    /// None in this build of the app (`swift build`).
    case unavailable
    case missing
    /// Not the one this app brought.
    case outdated
    case current

    private static let name = "ToolkitAudio.driver"
    private static let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL").appendingPathComponent(name)
    /// Beside the HAL folder, not in it, where coreaudiod would load it.
    private static let staged = URL(fileURLWithPath: "/Library/Audio/Plug-Ins").appendingPathComponent(".\(name).new")
    private static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent(name) }

    /// From the file: `Bundle` reads no Info.plist for a bundle inside an app's
    /// Resources (measured), and keeps what it read of one that's since been replaced.
    /// The version this app brings, to ask about each one once.
    static var bundledVersion: String? { bundled.flatMap(version(at:)) }

    private static func version(at driver: URL) -> String? {
        NSDictionary(contentsOf: driver.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    static var status: DriverInstall {
        guard let bundled, let ours = version(at: bundled) else { return .unavailable }
        guard let theirs = version(at: installed) else { return .missing }
        return ours == theirs ? .current : .outdated
    }

    /// Puts the app's driver in place, or removes it, and restarts coreaudiod,
    /// which stops all sound for a moment. False if refused, or cancelled. Blocks.
    static func run(install: Bool) -> Bool {
        var commands: String
        if install {
            guard let bundled, let requirement = signedLikeThisApp else {
                Log.mixer.error("driver: this copy can't tell its own driver from another: not installed")
                return false
            }
            // The app's folder is the user's, so anything running as them could
            // swap the driver at any moment up to the copy. So it's copied first
            // into a place only root can write, loses the owner, ACLs (which ditto
            // keeps, even with --noacl: measured) and modes that would leave it
            // writable, and is checked there, where it can no longer change. An
            // app that came as a download marks what's in it, and a driver must
            // not carry that.
            let stage = quoted(staged.path)
            commands = "/bin/rm -rf \(stage)"
                + " && /usr/bin/ditto \(quoted(bundled.path)) \(stage)"
                + " && /usr/sbin/chown -R root:wheel \(stage)"
                + " && /bin/chmod -R -N \(stage)"
                + " && /bin/chmod -R u-s,g-s,go-w \(stage)"
                + " && /usr/bin/codesign --verify --strict -R\(quoted("=" + requirement)) \(stage)"
                + " && /usr/bin/xattr -dr com.apple.quarantine \(stage)"
                + " && /bin/mkdir -p \(quoted(installed.deletingLastPathComponent().path))"
                + " && /bin/rm -rf \(quoted(installed.path))"
                + " && /bin/mv \(stage) \(quoted(installed.path))"
                + " || { /bin/rm -rf \(stage); exit 1; }"
        } else {
            commands = "/bin/rm -rf \(quoted(installed.path)) || exit 1"
        }
        commands += "; /usr/bin/killall coreaudiod || true"
        let script = "do shell script \"\(commands.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        Log.mixer.notice("driver: \(install ? "install" : "removal", privacy: .public) ended with status \(process.terminationStatus, privacy: .public)")
        return process.terminationStatus == 0
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The requirement for a driver worth installing: this app's own certificate,
    /// as the driver asks of the app. Nil for a copy signed ad hoc, which has none.
    private static var signedLikeThisApp: String? {
        var me: SecCode?
        var mine: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopySigningInformation(mine, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let certificates = (information as NSDictionary?)?[kSecCodeInfoCertificates] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(DRIVER_PLUGIN_BUNDLE_ID)\" and certificate leaf = H\"\(hash)\""
    }
}

/// What's being done to the driver on this Mac.
enum DriverWork: Equatable {
    case installing, removing
}

/// Why the mixer isn't on the driver though it was asked to be, for its page.
enum DriverProblem: Equatable {
    case notInstalled, outdated, notInApplications, refused, noDevice, installFailed
}

/// Where sound goes when outputs come and go, with the driver's device as the
/// default, so macOS has nothing of its own to move when one goes. Anything else
/// making an output the default is followed before this is asked. Plain data,
/// so `--test-driver-outputs` can run every case with no sound.
struct DriverRoutes {
    /// What was there last time, by UID. Nil until the first look, when what's
    /// there is simply what's there.
    private var known: Set<String>?
    /// The outputs chosen, oldest first: by a person, or headphones taking over.
    /// Not one the sound only fell back to when a chosen one went, so that one
    /// is still the latest, and gets the sound back when it returns.
    private(set) var used: [String]

    init(used: [String] = []) {
        self.used = used
    }

    mutating func use(_ uid: String) {
        used.removeAll { $0 == uid }
        used.append(uid)
        if used.count > 8 { used.removeFirst() }
    }

    /// The first look, with `current` what macOS has as its default. That's a
    /// choice made while the toolkit was away, unless the latest choice just
    /// isn't here: then it's what macOS fell back to, and the choice stands.
    mutating func begin(among outputs: [OutputDevice], current: String?) {
        known = Set(outputs.map(\.uid))
        guard let current else { return }
        if let latest = used.last, !outputs.contains(where: { $0.uid == latest }) { return }
        use(current)
    }

    /// Headphones take over as they appear, as they do on a Mac whose default is
    /// a real output: Bluetooth, and the jack, which is an output of its own on
    /// Apple silicon. Not a display or a dock, which appear with no one asking
    /// for their sound, unless they're the output chosen and only went away;
    /// macOS making one the default is still followed.
    static func takesOver(_ device: OutputDevice) -> Bool {
        switch device.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return true
        case kAudioDeviceTransportTypeBuiltIn: return device.uid.localizedCaseInsensitiveContains("headphone")
        default: return false
        }
    }

    /// The output to move to, if any, given what's there now and what's playing.
    /// A new pair of headphones first, then the latest choice if it has just
    /// returned; if the current output has gone, the latest choice still there,
    /// else the built-in one, else any.
    mutating func next(among outputs: [OutputDevice], current: String?) -> OutputDevice? {
        let previous = known
        known = Set(outputs.map(\.uid))
        let arrived = previous.map { previous in outputs.filter { !previous.contains($0.uid) } } ?? []
        if let headphones = arrived.first(where: Self.takesOver), headphones.uid != current {
            use(headphones.uid)
            return headphones
        }
        let latest = used.reversed().lazy.compactMap { uid in outputs.first { $0.uid == uid } }.first
        if let current, outputs.contains(where: { $0.uid == current }) {
            guard let latest, latest.uid != current, arrived.contains(where: { $0.uid == latest.uid }) else { return nil }
            return latest
        }
        return latest ?? outputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn && !Self.takesOver($0) } ?? outputs.first
    }

    /// `--test-driver-outputs`: every case, with made-up outputs.
    static func selfTest() {
        let speakers = OutputDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "Speakers")
        let jack = OutputDevice(id: 2, uid: "BuiltInHeadphoneOutputDevice", name: "Headphones")
        let airPods = OutputDevice(id: 3, uid: "AA-BB:output", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
        let beats = OutputDevice(id: 4, uid: "CC-DD:output", name: "Earbuds", transport: kAudioDeviceTransportTypeBluetoothLE)
        let display = OutputDevice(id: 5, uid: "display", name: "Display", transport: kAudioDeviceTransportTypeDisplayPort)
        let usb = OutputDevice(id: 6, uid: "usb", name: "USB", transport: kAudioDeviceTransportTypeUSB)
        var failures = 0
        func check(_ what: String, _ result: OutputDevice?, _ wanted: OutputDevice?) {
            let ok = result?.uid == wanted?.uid
            print((ok ? "ok    " : "FAIL  ") + "\(what): \(result?.name ?? "stays")")
            if !ok { failures += 1 }
        }
        var routes = DriverRoutes()
        routes.use(speakers.uid)
        check("at the start, headphones already there don't take over", routes.next(among: [speakers, airPods], current: speakers.uid), nil)
        routes = DriverRoutes()
        routes.use(speakers.uid)
        _ = routes.next(among: [speakers], current: speakers.uid)
        check("nothing changed", routes.next(among: [speakers], current: speakers.uid), nil)
        check("a display appears: stays", routes.next(among: [speakers, display], current: speakers.uid), nil)
        check("a USB device appears: stays", routes.next(among: [speakers, display, usb], current: speakers.uid), nil)
        check("Bluetooth headphones appear: move", routes.next(among: [speakers, display, usb, airPods], current: speakers.uid), airPods)
        check("still there: stays", routes.next(among: [speakers, display, usb, airPods], current: airPods.uid), nil)
        check("they go: back to the last one used", routes.next(among: [speakers, display, usb], current: airPods.uid), speakers)
        check("they come back: move again", routes.next(among: [speakers, display, usb, airPods], current: speakers.uid), airPods)
        check("Bluetooth LE appears too: the newest", routes.next(among: [speakers, airPods, beats], current: airPods.uid), beats)
        check("those go: back to the first pair", routes.next(among: [speakers, airPods], current: beats.uid), airPods)
        check("the jack: takes over", routes.next(among: [speakers, airPods, jack], current: airPods.uid), jack)
        check("the jack and the pair both go: speakers", routes.next(among: [speakers], current: jack.uid), speakers)
        routes = DriverRoutes()
        routes.use(display.uid)
        _ = routes.next(among: [speakers, display], current: display.uid)
        check("a chosen display goes, nothing else used: built-in", routes.next(among: [speakers], current: display.uid), speakers)
        check("nothing changed on the fallback: stays", routes.next(among: [speakers], current: speakers.uid), nil)
        check("the chosen display returns: back to it", routes.next(among: [speakers, display], current: speakers.uid), display)
        check("and stays there", routes.next(among: [speakers, display], current: display.uid), nil)
        _ = routes.next(among: [speakers], current: display.uid)
        routes.use(speakers.uid)
        check("speakers chosen while it was away: it returns, sound stays", routes.next(among: [speakers, display], current: speakers.uid), nil)
        routes = DriverRoutes()
        routes.use(speakers.uid)
        routes.use(display.uid)
        _ = routes.next(among: [speakers, display, usb], current: display.uid)
        check("the display goes: back to the speakers", routes.next(among: [speakers, usb], current: display.uid), speakers)
        routes.use(usb.uid)
        check("USB chosen meanwhile: the display returns, sound stays", routes.next(among: [speakers, usb, display], current: usb.uid), nil)
        routes = DriverRoutes()
        routes.use(display.uid)
        _ = routes.next(among: [speakers, display], current: display.uid)
        _ = routes.next(among: [speakers], current: display.uid)
        check("headphones while the display is away: move", routes.next(among: [speakers, airPods], current: speakers.uid), airPods)
        check("the display returns under the headphones: stays", routes.next(among: [speakers, airPods, display], current: airPods.uid), nil)
        check("the headphones go: the display, not the speakers", routes.next(among: [speakers, display], current: airPods.uid), display)
        routes = DriverRoutes(used: [speakers.uid, display.uid])
        routes.begin(among: [speakers], current: speakers.uid)
        check("saved, restarted with the display away: stays", routes.next(among: [speakers], current: speakers.uid), nil)
        check("saved, the display returns: back to it", routes.next(among: [speakers, display], current: speakers.uid), display)
        routes = DriverRoutes(used: [speakers.uid, display.uid])
        routes.begin(among: [speakers, display], current: speakers.uid)
        check("saved, speakers made the default with both here: that's the choice", routes.next(among: [speakers], current: speakers.uid), nil)
        check("and the display returning doesn't take it", routes.next(among: [speakers, display], current: speakers.uid), nil)
        routes = DriverRoutes()
        _ = routes.next(among: [usb, display], current: usb.uid)
        check("nothing used or built in: any", routes.next(among: [display], current: usb.uid), display)
        routes = DriverRoutes()
        check("no current output: built-in, never the jack", routes.next(among: [jack, speakers], current: nil), speakers)
        print(failures == 0 ? "all ok" : "\(failures) failed")
    }
}

/// The mixer on the driver: the link, the driver's device as the default output,
/// and the real output the sound goes on to. The real output runs only while
/// something plays to the device, so the Mac can sleep.
///
/// Nothing here is undone by anything but `close`, or by the driver when the
/// toolkit is gone: its device goes, and macOS moves sound to a real output.
final class MixerDriver {
    let link: DriverLink
    /// Once the driver shows it, a moment after the link.
    private(set) var device: AudioObjectID?
    /// Where the sound goes on to.
    private(set) var output: AudioObjectID = .unknown
    private var systemOutput: AudioObjectID = .unknown
    /// Saved so a choice outlives a restart with its output away: an update, or
    /// a display that's off.
    var routes = DriverRoutes(used: UserDefaults.standard.stringArray(forKey: MixerDriver.outputsChosenKey) ?? []) {
        didSet {
            if routes.used != oldValue.used { UserDefaults.standard.set(routes.used, forKey: Self.outputsChosenKey) }
        }
    }
    private static let outputsChosenKey = "driverOutputsChosen"
    private var outputListeners: [AudioListener] = []
    /// The output's shape when it last started, so the same news twice doesn't
    /// restart it, which on Bluetooth is a second without sound.
    private var shape = ""
    /// Letting go of the real output a moment after the sound stops: the next
    /// sound, often soon, starts at once rather than waiting for it to come up.
    private var letGo: DispatchWorkItem?
    private static let lingers: TimeInterval = 3
    private var listeners: [AudioListener] = []
    /// What was last written to the device's own volume, to tell a change
    /// made elsewhere from our own.
    private var mirrored: (volume: Float, muted: Bool)?
    /// Hearing our own write back isn't someone moving the slider, even if the
    /// host reads back a value a little off what it was given.
    private var mirroredAt = Date.distantPast
    /// A change to the device's volume or mute made elsewhere: macOS's slider.
    var onVolume: ((Float, Bool) -> Void)?

    init(equalizer: EqualizerState) throws {
        link = try DriverLink(equalizer: equalizer)
    }

    /// Whether the device shown is ours and still there: coreaudiod restarting
    /// or a heartbeat that came too late takes it away.
    var deviceIsGone: Bool { device != nil && DriverLink.device == nil }

    /// Takes over as the default output if the device has shown up. `real`:
    /// what the sound goes on to, or `fallback` if that's the device itself, as
    /// it still is for a moment after a toolkit that was killed.
    /// True once it has happened, now or before.
    @discardableResult
    func adopt(real: AudioObjectID, fallback: AudioObjectID?) -> Bool {
        if device != nil { return true }
        guard let found = DriverLink.device else { return false }
        device = found
        output = real == found ? fallback ?? .unknown : real
        systemOutput = AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self) ?? real
        watchOutput()
        shape = currentShape
        followRate()
        let scope = kAudioObjectPropertyScopeOutput
        listeners = [
            AudioListener(found, kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in self?.runningChanged() },
            // An app can set the device's rate as it could a real output's, and
            // it has to be the real output's, or everything plays at the wrong pitch.
            AudioListener(found, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.followRate() },
            AudioListener(found, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) { [weak self] in self?.volumeChanged() },
            AudioListener(found, kAudioDevicePropertyMute, scope: scope) { [weak self] in self?.volumeChanged() },
        ]
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, found)
        takeSystemOutput(ifOn: real)
        Log.mixer.notice("driver: device \(found, privacy: .public) is the default output, on to \(real.readString(kAudioDevicePropertyDeviceUID) ?? "?", privacy: .public)")
        runningChanged()
        return true
    }

    /// `real` was chosen, even if it's what's playing already: the sound having
    /// fallen back to it doesn't make it the choice, picking it does.
    func setOutput(_ real: AudioObjectID) {
        real.readString(kAudioDevicePropertyDeviceUID).map { routes.use($0) }
        move(to: real)
    }

    /// Plays on `real` from now on. The device's rate follows it, which a
    /// playing app has no way to hear but as a moment's stop.
    func move(to real: AudioObjectID) {
        guard real != output else { return }
        output = real
        watchOutput()
        restart()
    }

    private func watchOutput() {
        outputListeners = [AudioListener(output, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
            self?.outputReconfigured()
        }]
    }

    private var currentShape: String {
        let scope = kAudioObjectPropertyScopeOutput
        return "\(output) \(output.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0) "
            + "\(output.readArray(kAudioDevicePropertyPreferredChannelsForStereo, scope: scope, as: UInt32.self)) "
            + "\(DriverLink.readStreamConfiguration(of: output))"
    }

    private func restart() {
        shape = currentShape
        link.stop()
        followRate()
        runningChanged()
    }

    /// macOS or someone made `real` the default: sound goes on to it, and the
    /// device goes back in front.
    func follow(_ real: AudioObjectID) {
        setOutput(real)
        guard let device else { return }
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, device)
        takeSystemOutput(ifOn: real)
    }

    /// Alerts follow the sound to the device, unless Sound Settings has them on
    /// an output of their own, which stays theirs: that's only so if they weren't
    /// on the one the sound was on.
    private func takeSystemOutput(ifOn real: AudioObjectID) {
        guard let device else { return }
        let system = AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self)
        if system == real { AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, device) }
    }

    /// The real output changed its rate or stereo pair.
    func outputReconfigured() {
        guard device != nil, currentShape != shape else { return }
        Log.mixer.notice("driver: the output changed shape: \(self.currentShape, privacy: .public)")
        restart()
    }

    private func followRate() {
        guard let device, let rate = output.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self), rate > 0,
              device.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) != rate else { return }
        if !device.write(kAudioDevicePropertyNominalSampleRate, rate) {
            Log.mixer.error("driver: the device can't run at \(rate, privacy: .public) Hz")
        }
    }

    private func runningChanged() {
        guard let device else { return }
        let running = (device.read(kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) ?? 0) != 0
        letGo?.cancel()
        letGo = nil
        if running, output != .unknown {
            link.start(on: output)
        } else if !running {
            let work = DispatchWorkItem { [weak self] in self?.link.stop() }
            letGo = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingers, execute: work)
        }
    }

    /// Shows the real volume on the device, for macOS's slider and keys.
    func mirror(volume: Float, muted: Bool) {
        guard let device else { return }
        if let mirrored, abs(mirrored.volume - volume) < 0.001, mirrored.muted == muted { return }
        mirrored = (volume, muted)
        mirroredAt = Date()
        let scope = kAudioObjectPropertyScopeOutput
        device.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, Float32(volume))
        device.write(kAudioDevicePropertyMute, scope: scope, UInt32(muted ? 1 : 0))
    }

    private func volumeChanged() {
        guard let device, let mirrored, Date().timeIntervalSince(mirroredAt) > 0.2 else { return }
        let scope = kAudioObjectPropertyScopeOutput
        let volume = device.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, as: Float32.self) ?? mirrored.volume
        let muted = (device.read(kAudioDevicePropertyMute, scope: scope, as: UInt32.self) ?? 0) != 0
        guard abs(mirrored.volume - volume) >= 0.001 || mirrored.muted != muted else { return }
        self.mirrored = (volume, muted)
        onVolume?(volume, muted)
    }

    /// Everything back as it was: macOS's outputs, and the driver's device gone.
    func close() {
        letGo?.cancel()
        listeners = []
        outputListeners = []
        if let device {
            let own = { (id: AudioObjectID?) in id == device || id == nil }
            if own(AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)), output != .unknown {
                AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, output)
            }
            if own(AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self)) {
                // Back on whatever the sound goes to now, if that's what it followed.
                AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, output != .unknown ? output : systemOutput)
            }
        }
        link.close()
        device = nil
        Log.mixer.notice("driver: closed")
    }
}
