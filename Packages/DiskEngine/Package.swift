// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskEngine",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DiskEngine", targets: ["DiskEngine"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .target(name: "DiskEngine", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "DiskEngineTests", dependencies: ["DiskEngine"]),
    ]
)
