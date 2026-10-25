import AudioToolbox
import Foundation

/// A short sound played as macOS plays its own interface sounds: by its sound
/// server (systemsoundserverd), not this process. The Audio Mixer's taps leave
/// this process out, or they'd hear their own output, so a sound played here
/// skipped the software volume and the equalizer: at full volume on a
/// monitor with no volume of its own. Played this way it goes through them
/// like any other sound, and follows Sound settings' "Play user interface
/// sound effects", as macOS's own screenshot sound does.
final class SystemSound {
    private var id: SystemSoundID = 0

    /// Nil when the file can't be read.
    init?(path: String) {
        guard AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id) == noErr else { return nil }
    }

    deinit { AudioServicesDisposeSystemSoundID(id) }

    func play() { AudioServicesPlaySystemSound(id) }

    /// Finder's own sound for files cut.
    static let pop = SystemSound(path: "/System/Library/Sounds/Pop.aiff")
    /// macOS's own screenshot sound.
    static let shutter = SystemSound(path: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
}
