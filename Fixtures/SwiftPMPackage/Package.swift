// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fixture",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Lib", targets: ["Lib"])],
    targets: [
        .target(name: "Lib"),
        .executableTarget(name: "App", dependencies: ["Lib"]),
        .testTarget(name: "LibTests", dependencies: ["Lib"]),
    ]
)
