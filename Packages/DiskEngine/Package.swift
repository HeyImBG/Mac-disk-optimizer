// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskEngine",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DiskEngine", targets: ["DiskEngine"])],
    targets: [
        .target(name: "DiskEngine"),
        .testTarget(name: "DiskEngineTests", dependencies: ["DiskEngine"]),
    ]
)
