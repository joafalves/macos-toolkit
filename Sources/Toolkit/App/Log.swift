import os

/// The app's lines in the system log, under its own subsystem with a category
/// per tool. What the toolkit says and the values it picks (bundle IDs, pids,
/// device UIDs, statuses) are marked public, so a trace reads as written;
/// anything of the user's (a path, text read from the screen) stays private.
/// Errors and notices are kept on disk, so a trace can be taken afterwards:
/// `/usr/bin/log show --predicate 'subsystem == "dev.jalves.macos-toolkit"' --info --last 30m`
enum Log {
    static let subsystem = "dev.jalves.macos-toolkit"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let updater = Logger(subsystem: subsystem, category: "updater")
    static let mouse = Logger(subsystem: subsystem, category: "mouse")
    static let switcher = Logger(subsystem: subsystem, category: "switcher")
    static let layout = Logger(subsystem: subsystem, category: "layout")
    static let mixer = Logger(subsystem: subsystem, category: "mixer")
    static let finder = Logger(subsystem: subsystem, category: "finder")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let awake = Logger(subsystem: subsystem, category: "awake")
}
