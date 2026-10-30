// swift-tools-version:5.9
import PackageDescription

// The SDK the binary says it was built with. The Command Line Tools record
// the deployment target there (15.0), and macOS then draws the app as one
// from before macOS 26: old window buttons, toolbar and sidebar. This puts
// the real SDK's version in, keeping 15.0 as the oldest macOS it runs on.
let sdkVersion = ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "27.0"]

let package = Package(
    name: "Toolkit",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Toolkit",
            dependencies: ["DriverShared"],
            path: "Sources/Toolkit",
            // The development flags (main.swift): in debug builds, and in
            // `build.sh --dev`, which passes it itself. Never in a release.
            swiftSettings: [.define("TOOLKIT_DEV", .when(configuration: .debug))],
            // SkyLight is private; the window switcher uses it to focus single windows.
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"] + sdkVersion)]
        ),
        // What the app and the audio driver (Driver/, built by build.sh) share.
        .target(name: "DriverShared", path: "Sources/DriverShared"),
        // The Finder Sync extension, wrapped into an .appex by build.sh. It has
        // no main: extensions start in NSExtensionMain.
        .executableTarget(
            name: "FinderExtension",
            path: "Sources/FinderExtension",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"] + sdkVersion)]
        ),
    ]
)
