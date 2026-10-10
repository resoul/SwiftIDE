import Foundation
@testable import IDEApplication
import Testing

/// The shape `swift package describe --type json` gives (Xcode 27.0), cut down to what is read.
private let describeJSON = """
{
  "name": "Fixture",
  "path": "/w/pkg",
  "targets": [
    { "name": "LibTests", "type": "test", "module_type": "SwiftTarget", "path": "Tests/LibTests", "sources": ["GreeterTests.swift"] },
    { "name": "Lib", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Lib", "sources": ["Greeter.swift"] },
    { "name": "App", "type": "executable", "module_type": "SwiftTarget", "path": "Sources/App", "sources": ["main.swift"] },
    { "name": "CLib", "type": "library", "module_type": "ClangTarget", "path": "Sources/CLib", "sources": ["clib.c"] }
  ]
}
"""

private func layout(_ json: String = describeJSON, root: String = "/w/pkg") throws -> PackageLayout {
    try PackageLayout.parse(Data(json.utf8), root: root)
}

@Test
func theTargetsOfAPackageAreReadFromWhatDescribeGives() throws {
    let l = try layout()
    #expect(l.targets.map(\.name) == ["LibTests", "Lib", "App", "CLib"])
    #expect(l.targets.map(\.kind) == [.test, .library, .executable, .library])
    #expect(l.targets[1].directory == "/w/pkg/Sources/Lib", "a target's folder is made absolute from the package root")
    #expect(l.targets[1].sources == ["Greeter.swift"])
}

@Test
func aFileListedInATargetBelongsToThatTarget() throws {
    let l = try layout()
    #expect(l.membership(of: "/w/pkg/Sources/Lib/Greeter.swift") == .one(l.targets[1], .listed))
    #expect(l.membership(of: "/w/pkg/Tests/LibTests/GreeterTests.swift") == .one(l.targets[0], .listed))
    #expect(l.membership(of: "/w/pkg/Sources/App/main.swift") == .one(l.targets[2], .listed))
}

@Test
func aFileNotYetListedButInsideATargetsFolderBelongsToItByItsPlace() throws {
    let l = try layout()
    // A file made after describe ran, and a header: neither is in `sources`.
    #expect(l.membership(of: "/w/pkg/Sources/Lib/New.swift") == .one(l.targets[1], .inferred))
    #expect(l.membership(of: "/w/pkg/Sources/CLib/include/clib.h") == .one(l.targets[3], .inferred))
}

@Test
func aFileOutsideEveryTargetBelongsToNone() throws {
    let l = try layout()
    #expect(l.membership(of: "/w/pkg/Package.swift") == .none)
    #expect(l.membership(of: "/w/pkg/README.md") == .none)
    #expect(l.membership(of: "/elsewhere/Sources/Lib/Greeter.swift") == .none)
}

@Test
func aFolderThatMerelyStartsWithTheSameLettersIsNotTheTargets() throws {
    let l = try layout()
    #expect(l.membership(of: "/w/pkg/Sources/Library/X.swift") == .none)
}

@Test
func theInnermostTargetFolderWinsForAnUnlistedFile() throws {
    let nested = try layout("""
    { "targets": [
      { "name": "Outer", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Outer", "sources": ["a.swift"] },
      { "name": "Inner", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Outer/Inner", "sources": ["b.swift"] }
    ] }
    """)
    #expect(nested.membership(of: "/w/pkg/Sources/Outer/Inner/new.swift") == .one(nested.targets[1], .inferred))
    #expect(nested.membership(of: "/w/pkg/Sources/Outer/other.swift") == .one(nested.targets[0], .inferred))
    #expect(nested.membership(of: "/w/pkg/Sources/Outer/Inner/b.swift") == .one(nested.targets[1], .listed))
}

@Test
func aFileListedInTwoTargetsIsAmbiguousAndSaysWhichTwo() throws {
    let two = try layout("""
    { "targets": [
      { "name": "A", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Shared", "sources": ["x.swift"] },
      { "name": "B", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Shared", "sources": ["x.swift"] }
    ] }
    """)
    guard case .several(let candidates, _) = two.membership(of: "/w/pkg/Sources/Shared/x.swift") else {
        Issue.record("expected an ambiguous membership")

        return
    }

    #expect(candidates.map(\.name) == ["A", "B"])
}

@Test
func twoTargetsWithTheSameFolderAreAmbiguousForAnUnlistedFileToo() throws {
    let two = try layout("""
    { "targets": [
      { "name": "A", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Shared", "sources": ["a.swift"] },
      { "name": "B", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Shared", "sources": ["b.swift"] }
    ] }
    """)
    guard case .several = two.membership(of: "/w/pkg/Sources/Shared/new.swift") else {
        Issue.record("expected an ambiguous membership")

        return
    }

    #expect(two.membership(of: "/w/pkg/Sources/Shared/a.swift") == .one(two.targets[0], .listed), "a listed file settles it")
}

@Test
func aTargetWithNoSourcesListStillHoldsItsFolder() throws {
    let l = try layout("""
    { "targets": [ { "name": "Plugin", "type": "plugin", "module_type": "PluginTarget", "path": "Plugins/P" } ] }
    """)
    #expect(l.targets[0].kind == .other)
    #expect(l.membership(of: "/w/pkg/Plugins/P/plugin.swift") == .one(l.targets[0], .inferred))
}

@Test
func outputThatIsNotDescribeJSONIsRefusedNotGuessedAt() {
    #expect(throws: PackageLayout.ParseError.self) { try PackageLayout.parse(Data("not json".utf8), root: "/w") }
    #expect(throws: PackageLayout.ParseError.self) { try PackageLayout.parse(Data("{\"name\": \"x\"}".utf8), root: "/w") }
    #expect(throws: PackageLayout.ParseError.self) { try PackageLayout.parse(Data("{\"targets\": [{\"name\": \"x\"}]}".utf8), root: "/w") }
}

@Test
func theLayoutOfAPackageWithNoTargetsIsEmptyNotAnError() throws {
    let l = try layout("{ \"targets\": [] }")
    #expect(l.targets.isEmpty && l.membership(of: "/w/pkg/Sources/A/a.swift") == .none)
}

@Test
func aFileThePackageListsIsListedAndOneItDoesNotIsInferred() throws {
    let l = try layout()
    #expect(l.membership(of: "/w/pkg/Sources/Lib/Greeter.swift").basis == .listed)
    #expect(l.membership(of: "/w/pkg/Sources/Lib/New.swift").basis == .inferred)
    #expect(l.membership(of: "/w/pkg/README.md").basis == nil, "no target, nothing to qualify")
}

/// Checked with the real `swift package describe` (Xcode 27.0): SwiftPM accepts two targets in one
/// folder when each lists its own sources, so an ambiguous file does occur in a package.
@Test
func twoTargetsSharingAFolderWithExplicitSourcesAreAmbiguousForAFileNeitherLists() throws {
    let shared = try layout("""
    { "targets": [
      { "name": "A", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Shared", "sources": ["A.swift"] },
      { "name": "B", "type": "library", "module_type": "SwiftTarget", "path": "Sources/Shared", "sources": ["B.swift"] }
    ] }
    """)
    #expect(shared.membership(of: "/w/pkg/Sources/Shared/A.swift") == .one(shared.targets[0], .listed))
    #expect(shared.membership(of: "/w/pkg/Sources/Shared/B.swift") == .one(shared.targets[1], .listed))
    let other = shared.membership(of: "/w/pkg/Sources/Shared/C.swift")
    #expect(other.names == ["A", "B"] && other.basis == .inferred)
}

/// `swift package describe` does not report `exclude`: a file the manifest leaves out looks like any
/// unlisted file in the folder, which is why such a target is only inferred.
@Test
func aFileTheManifestExcludesIsStillOnlyInferredToBeInTheTargetsFolder() throws {
    let l = try layout("""
    { "targets": [ { "name": "App", "type": "executable", "module_type": "SwiftTarget", "path": "Sources/App", "sources": ["main.swift"] } ] }
    """)
    #expect(l.membership(of: "/w/pkg/Sources/App/Skip/S.swift") == .one(l.targets[0], .inferred))
}
