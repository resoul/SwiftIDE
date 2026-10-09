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
        .library(name: "IDETestSupport", targets: ["IDETestSupport"])
    ],
    dependencies: [
        // Parsing for syntax colouring (ADR-014). Pinned exactly; the grammar is built from its
        // pre-generated sources, so no generator is needed. Licences: tree-sitter MIT,
        // swift-tree-sitter BSD-3-Clause, tree-sitter-swift MIT.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files")
    ],
    targets: [
        .target(name: "IDEDomain"),
        .target(name: "IDEApplication", dependencies: ["IDEDomain"]),
        // POSIX/Foundation file access lives only here; the app composes it, Application never sees it.
        .target(name: "FileSystemInfrastructure", dependencies: ["IDEDomain", "IDEApplication"]),
        // AppKit/TextKit live only in the platform and UI modules.
        .target(name: "EditorPlatformTextKit", dependencies: ["IDEDomain", "IDEApplication"]),
        .target(name: "EditorUI", dependencies: ["IDEApplication", "EditorPlatformTextKit"]),
        // Tree-sitter behind the SyntaxHighlighter port; the only module that knows the parser.
        .target(
            name: "SyntaxInfrastructure",
            dependencies: [
                "IDEDomain", "IDEApplication",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift")
            ],
            resources: [.copy("Resources")]
        ),
        // Headless adapters of the same ports; not linked into the app.
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
            name: "FileSystemInfrastructureTests",
            dependencies: ["IDEDomain", "IDEApplication", "FileSystemInfrastructure", "IDETestSupport"]
        )
    ],
    swiftLanguageModes: [.v6]
)
