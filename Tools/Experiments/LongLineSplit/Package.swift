// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "splitprobe",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "splitprobe")],
    swiftLanguageModes: [.v6]
)
