import Foundation

/// The apps making sound now, as the Audio Mixer's driver hears them, for the
/// Window Switcher to mark. Only with the driver: taps are on their way out.
/// By the app's process, with its helpers counted as it. Main thread.
final class AudioActivity {
    static let shared = AudioActivity()

    private(set) var apps: Set<pid_t> = []
    var onChange: (() -> Void)?

    func set(_ apps: Set<pid_t>) {
        guard apps != self.apps else { return }
        self.apps = apps
        onChange?()
    }
}
