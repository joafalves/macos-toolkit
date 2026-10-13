// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tiller",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Tiller", path: "Sources/Tiller"),
    ]
)
