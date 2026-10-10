// swift-tools-version: 6.0
import PackageDescription

// The blank-line checks that SwiftFormat and SwiftLint cannot express (TK-023): a blank line before
// a `return` that follows other statements, and after a multi-line `if`. Built on SwiftSyntax,
// pinned to the release that matches the toolchain (Swift 6.4 → 604).
let package = Package(
    name: "SpacingCheck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "spacing-check", targets: ["spacing-check"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "604.0.0")
    ],
    targets: [
        .target(
            name: "SpacingRules",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax")
            ]
        ),
        .executableTarget(name: "spacing-check", dependencies: ["SpacingRules"]),
        .testTarget(name: "SpacingRulesTests", dependencies: ["SpacingRules"])
    ],
    swiftLanguageModes: [.v6]
)
