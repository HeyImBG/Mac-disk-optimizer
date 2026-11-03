// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskEngine", targets: ["DiskEngine"]),
        .executable(name: "diskopt", targets: ["diskopt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .target(name: "DiskEngine", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "DiskCLI", dependencies: ["DiskEngine"]),
        .executableTarget(name: "diskopt", dependencies: ["DiskCLI"]),
        .testTarget(name: "DiskEngineTests", dependencies: ["DiskEngine"]),
        .testTarget(name: "DiskCLITests", dependencies: ["DiskCLI", "DiskEngine"]),
    ]
)
