// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "truncprobe",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "truncprobe")],
    swiftLanguageModes: [.v6]
)
