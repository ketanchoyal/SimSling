// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimSling",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SimSling", path: "Sources/SimSling")
    ]
)
