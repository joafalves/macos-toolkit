import AudioToolbox
import CoreAudio
import DriverShared
import Foundation
import os

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
    private static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent(name) }

    /// From the file: `Bundle` reads no Info.plist for a bundle inside an app's
    /// Resources (measured), and keeps what it read of one that's since been replaced.
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
        var commands = ["/bin/rm -rf \(quoted(installed.path))"]
        if install {
            guard let bundled else { return false }
            // An app that came as a download marks what's in it, and a driver
            // must not carry that.
            commands += ["/usr/bin/ditto \(quoted(bundled.path)) \(quoted(installed.path))",
                         "/usr/bin/xattr -dr com.apple.quarantine \(quoted(installed.path))",
                         "/usr/sbin/chown -R root:wheel \(quoted(installed.path))"]
        }
        commands.append("/usr/bin/killall coreaudiod")
        let script = "do shell script \"\(commands.joined(separator: " && ").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
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
}

/// Why the mixer isn't on the driver though it was asked to be, for its page.
enum DriverProblem: Equatable {
    case notInstalled, outdated, notInApplications, refused, noDevice, installFailed
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
    private var listeners: [AudioListener] = []
    /// What was last written to the device's own volume, to tell a change
    /// made elsewhere from our own.
    private var mirrored: (volume: Float, muted: Bool)?
    /// A change to the device's volume or mute made elsewhere: macOS's slider.
    var onVolume: ((Float, Bool) -> Void)?

    init(equalizer: EqualizerState) throws {
        link = try DriverLink(equalizer: equalizer)
    }

    /// Takes over as the default output if the device has shown up. `real`:
    /// what the sound goes on to. True once it has happened, now or before.
    @discardableResult
    func adopt(real: AudioObjectID) -> Bool {
        if device != nil { return true }
        guard let found = DriverLink.device else { return false }
        device = found
        output = real
        systemOutput = AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self) ?? real
        followRate()
        let scope = kAudioObjectPropertyScopeOutput
        listeners = [
            AudioListener(found, kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in self?.runningChanged() },
            AudioListener(found, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) { [weak self] in self?.volumeChanged() },
            AudioListener(found, kAudioDevicePropertyMute, scope: scope) { [weak self] in self?.volumeChanged() },
        ]
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, found)
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, found)
        Log.mixer.notice("driver: device \(found, privacy: .public) is the default output, on to \(real.readString(kAudioDevicePropertyDeviceUID) ?? "?", privacy: .public)")
        runningChanged()
        return true
    }

    /// Plays on `real` from now on. The device's rate follows it, which a
    /// playing app has no way to hear but as a moment's stop.
    func setOutput(_ real: AudioObjectID) {
        guard real != output else { return }
        output = real
        link.stop()
        followRate()
        runningChanged()
    }

    /// The real output changed its rate or stereo pair.
    func outputReconfigured() {
        link.stop()
        followRate()
        runningChanged()
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
        if running, output != .unknown {
            link.start(on: output)
        } else if !running {
            link.stop()
        }
    }

    /// Shows the real volume on the device, for macOS's slider and keys.
    func mirror(volume: Float, muted: Bool) {
        guard let device else { return }
        if let mirrored, abs(mirrored.volume - volume) < 0.001, mirrored.muted == muted { return }
        mirrored = (volume, muted)
        let scope = kAudioObjectPropertyScopeOutput
        device.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, Float32(volume))
        device.write(kAudioDevicePropertyMute, scope: scope, UInt32(muted ? 1 : 0))
    }

    private func volumeChanged() {
        guard let device, let mirrored else { return }
        let scope = kAudioObjectPropertyScopeOutput
        let volume = device.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, as: Float32.self) ?? mirrored.volume
        let muted = (device.read(kAudioDevicePropertyMute, scope: scope, as: UInt32.self) ?? 0) != 0
        guard abs(mirrored.volume - volume) >= 0.001 || mirrored.muted != muted else { return }
        self.mirrored = (volume, muted)
        onVolume?(volume, muted)
    }

    /// Everything back as it was: macOS's outputs, and the driver's device gone.
    func close() {
        listeners = []
        if let device {
            let own = { (id: AudioObjectID?) in id == device || id == nil }
            if own(AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)), output != .unknown {
                AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, output)
            }
            if own(AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self)) {
                AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, systemOutput != device ? systemOutput : output)
            }
        }
        link.close()
        device = nil
        Log.mixer.notice("driver: closed")
    }
}
