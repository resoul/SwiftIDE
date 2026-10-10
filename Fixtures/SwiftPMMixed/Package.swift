// swift-tools-version: 6.0
import PackageDescription

// One package with the three C-family languages beside Swift (TK-017 fixture): Swift calls into
// the C and Objective-C targets through their public headers; the C++ target stands on its own.
let package = Package(
    name: "Mixed",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CLib", targets: ["CLib"])],
    targets: [
        .target(name: "CLib"),
        .target(name: "CxxLib"),
        .target(name: "ObjCLib"),
        .executableTarget(name: "App", dependencies: ["CLib", "ObjCLib"]),
    ],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx17
)
