// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanArchitectureExample",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "architecture-demo", targets: ["ArchitectureDemo"])
    ],
    targets: [
        .target(name: "IDEDomain"),
        .target(name: "IDEApplication", dependencies: ["IDEDomain"]),
        .target(name: "IDEInfrastructure", dependencies: ["IDEDomain", "IDEApplication"]),
        .target(name: "EditorPlatformTextKit", dependencies: ["IDEDomain", "IDEApplication"]),
        .target(name: "IDEPresentation", dependencies: ["IDEDomain", "IDEApplication"]),
        .executableTarget(
            name: "ArchitectureDemo",
            dependencies: ["IDEDomain", "IDEApplication", "IDEInfrastructure", "IDEPresentation", "EditorPlatformTextKit"]
        ),
        .testTarget(
            name: "IDEApplicationTests",
            dependencies: ["IDEDomain", "IDEApplication", "IDEInfrastructure", "EditorPlatformTextKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
