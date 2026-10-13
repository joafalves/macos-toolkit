// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Toolkit",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Toolkit", path: "Sources/Toolkit"),
    ]
)
