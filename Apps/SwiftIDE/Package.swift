// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftIDEApp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SwiftIDE", targets: ["SwiftIDE"])
    ],
    dependencies: [
        .package(path: "../../Packages/IDE")
    ],
    targets: [
        .executableTarget(
            name: "SwiftIDE",
            dependencies: [
                .product(name: "IDEDomain", package: "IDE"),
                .product(name: "IDEApplication", package: "IDE"),
                .product(name: "FileSystemInfrastructure", package: "IDE"),
                .product(name: "EditorPlatformTextKit", package: "IDE"),
                .product(name: "EditorUI", package: "IDE"),
                .product(name: "WorkspaceUI", package: "IDE"),
                .product(name: "SyntaxInfrastructure", package: "IDE"),
                .product(name: "LanguageInfrastructure", package: "IDE")
            ]
        ),
        .testTarget(name: "SwiftIDEAppTests", dependencies: ["SwiftIDE", .product(name: "IDETestSupport", package: "IDE")])
    ],
    swiftLanguageModes: [.v6]
)
