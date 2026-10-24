import Foundation

/// Development aid: with `defaults write dev.jalves.macos-toolkit layoutTrace <file>`
/// (read at launch), the drag path's decisions are added to that file, from
/// any thread. Off, and costing nothing, otherwise.
enum LayoutTrace {
    // Dev builds only: any process can set a default, and the trace names windows.
    #if TOOLKIT_DEV
    private static let path = UserDefaults.standard.string(forKey: "layoutTrace")
    #else
    private static let path: String? = nil
    #endif
    private static let queue = DispatchQueue(label: "dev.jalves.macos-toolkit.layout-trace")

    static func log(_ text: @autoclosure () -> String) {
        guard let path else { return }
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + text() + "\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    static func text(_ r: CGRect?) -> String {
        r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil"
    }
}
