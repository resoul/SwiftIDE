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
        .library(name: "SyntaxInfrastructure", targets: ["SyntaxInfrastructure"]),
        .library(name: "LanguageInfrastructure", targets: ["LanguageInfrastructure"]),
        .library(name: "IDETestSupport", targets: ["IDETestSupport"])
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-objc", exact: "3.0.2")
    ],
    targets: [
        .target(name: "IDEDomain"),
        .target(name: "IDEApplication", dependencies: ["IDEDomain"]),
        .target(name: "FileSystemInfrastructure", dependencies: ["IDEDomain", "IDEApplication"]),
        .target(name: "EditorPlatformTextKit", dependencies: ["IDEDomain", "IDEApplication"]),
        .target(name: "EditorUI", dependencies: ["IDEApplication", "EditorPlatformTextKit"]),
        .target(
            name: "SyntaxInfrastructure",
            dependencies: [
                "IDEDomain",
                "IDEApplication",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterObjc", package: "tree-sitter-objc")
            ],
            resources: [.copy("Resources")]
        ),
        .target(name: "LanguageInfrastructure", dependencies: ["IDEDomain", "IDEApplication"]),
        .target(name: "IDETestSupport", dependencies: ["IDEDomain", "IDEApplication"]),
        .testTarget(
            name: "IDEApplicationTests",
            dependencies: ["IDEDomain", "IDEApplication", "IDETestSupport", "EditorPlatformTextKit", "EditorUI"]
        ),
        .testTarget(
            name: "SyntaxInfrastructureTests",
            dependencies: ["IDEDomain", "IDEApplication", "SyntaxInfrastructure", "IDETestSupport", "EditorPlatformTextKit", "EditorUI"]
        ),
        .testTarget(
            name: "LanguageInfrastructureTests",
            dependencies: ["IDEDomain", "IDEApplication", "LanguageInfrastructure", "IDETestSupport", "EditorPlatformTextKit", "EditorUI"]
        ),
        .testTarget(
            name: "FileSystemInfrastructureTests",
            dependencies: ["IDEDomain", "IDEApplication", "FileSystemInfrastructure", "IDETestSupport"]
        )
    ],
    swiftLanguageModes: [.v6]
)
