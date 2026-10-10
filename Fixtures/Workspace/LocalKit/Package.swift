// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LocalKit", targets: ["LocalKit"])],
    targets: [.target(name: "LocalKit")]
)
