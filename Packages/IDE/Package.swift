// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IDE",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "IDEDomain", targets: ["IDEDomain"]),
        .library(name: "IDEApplication", targets: ["IDEApplication"]),
        .library(name: "FileSystemInfrastructure", targets: ["FileSystemInfrastructure"]),
        .library(name: "EditorPlatformTextKit", targets: ["EditorPlatformTextKit"]),
        .library(name: "EditorUI", targets: ["EditorUI"]),
        .library(name: "IDETestSupport", targets: ["IDETestSupport"])
    ],
    targets: [
        .target(name: "IDEDomain"),
        .target(name: "IDEApplication", dependencies: ["IDEDomain"]),
        // POSIX/Foundation file access lives only here; the app composes it, Application never sees it.
        .target(name: "FileSystemInfrastructure", dependencies: ["IDEDomain", "IDEApplication"]),
        // AppKit/TextKit live only in the platform and UI modules.
        .target(name: "EditorPlatformTextKit", dependencies: ["IDEDomain", "IDEApplication"]),
        .target(name: "EditorUI", dependencies: ["EditorPlatformTextKit"]),
        // Headless adapters of the same ports; not linked into the app.
        .target(name: "IDETestSupport", dependencies: ["IDEDomain", "IDEApplication"]),
        .testTarget(
            name: "IDEApplicationTests",
            dependencies: ["IDEDomain", "IDEApplication", "IDETestSupport", "EditorPlatformTextKit"]
        ),
        .testTarget(
            name: "FileSystemInfrastructureTests",
            dependencies: ["IDEDomain", "IDEApplication", "FileSystemInfrastructure", "IDETestSupport"]
        )
    ],
    swiftLanguageModes: [.v6]
)
