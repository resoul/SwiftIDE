// swift-tools-version: 6.0
import PackageDescription

// Measurement tool, not shipped: it drives the real pipeline (file store, session, bridge, TextKit
// view) the same way the app does. Build and run it in release configuration only.
let package = Package(
    name: "TextKitBenchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../../Packages/IDE")],
    targets: [
        .executableTarget(
            name: "TextKitBenchmarks",
            dependencies: [
                .product(name: "IDEDomain", package: "IDE"),
                .product(name: "IDEApplication", package: "IDE"),
                .product(name: "FileSystemInfrastructure", package: "IDE"),
                .product(name: "EditorPlatformTextKit", package: "IDE"),
                .product(name: "EditorUI", package: "IDE"),
                .product(name: "SyntaxInfrastructure", package: "IDE")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
