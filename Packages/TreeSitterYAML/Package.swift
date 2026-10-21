// swift-tools-version:5.9
import PackageDescription

// tree-sitter-yaml 0.7.2 (MIT, https://github.com/tree-sitter-grammars/tree-sitter-yaml), copied as it is.
// Only this manifest is ours: the upstream one adds its scanner with a `fileExists` check that looks in
// the wrong folder when the package is a dependency, so the scanner is missing and linking fails.
let package = Package(
    name: "TreeSitterYAML",
    products: [
        .library(name: "TreeSitterYAML", targets: ["TreeSitterYAML"])
    ],
    targets: [
        .target(
            name: "TreeSitterYAML",
            path: "Sources/TreeSitterYAML",
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        )
    ],
    cLanguageStandard: .c11
)
