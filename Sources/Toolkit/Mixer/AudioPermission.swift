import AppKit

/// The "System Audio Recording" permission that process taps need. macOS has
/// no public call to check it, so this goes through the private TCC calls.
enum AudioPermission {
    enum Status { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var status: Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFunc.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the macOS prompt if the user hasn't answered it yet.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return completion(false) }
        unsafeBitCast(symbol, to: RequestFunc.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Once denied, macOS won't ask again; the switch is in System Settings.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
