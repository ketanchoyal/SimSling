// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimDrop",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SimDrop", path: "Sources/SimDrop")
    ]
)
