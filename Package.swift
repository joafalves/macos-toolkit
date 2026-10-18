// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Toolkit",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Toolkit",
            path: "Sources/Toolkit",
            // SkyLight is private; the window switcher uses it to focus single windows.
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]
        ),
        // The Finder Sync extension, wrapped into an .appex by build.sh. It has
        // no main: extensions start in NSExtensionMain.
        .executableTarget(
            name: "FinderExtension",
            path: "Sources/FinderExtension",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
    ]
)
