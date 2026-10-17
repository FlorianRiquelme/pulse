// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PulseCore"),
        .executableTarget(name: "Pulse", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
    ]
)
