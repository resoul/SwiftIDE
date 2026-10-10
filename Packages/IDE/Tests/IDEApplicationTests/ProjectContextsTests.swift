import Foundation
@testable import IDEApplication
import Testing

/// A folder tree made for a test, removed afterwards.
private final class Tree {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("contexts-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func make(_ path: String, marker: String? = nil, file: String? = nil) throws -> String {
        let folder = base.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let marker {
            let url = folder.appendingPathComponent(marker)
            if marker.hasSuffix(".xcodeproj") || marker.hasSuffix(".xcworkspace") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try "x".write(to: url, atomically: true, encoding: .utf8)
            }
        }

        if let file { try "x".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8) }

        return folder.path
    }

    func path(_ relative: String) -> String { base.appendingPathComponent(relative).path }
}

// MARK: What a folder is

@Test
func aFoldersBuildSystemIsRecognisedByWhatIsInIt() throws {
    let tree = try Tree()
    #expect(ProjectContexts.buildSystem(ofFolder: try tree.make("a", marker: "Package.swift")) == .swiftPM)
    #expect(ProjectContexts.buildSystem(ofFolder: try tree.make("b", marker: "MODULE.bazel")) == .bazel)
    #expect(ProjectContexts.buildSystem(ofFolder: try tree.make("c", marker: "App.xcodeproj")) == .xcode)
    #expect(ProjectContexts.buildSystem(ofFolder: try tree.make("d", marker: "App.xcworkspace")) == .xcode)
    #expect(ProjectContexts.buildSystem(ofFolder: try tree.make("e", marker: "compile_commands.json")) == .compilationDatabase)
    #expect(ProjectContexts.buildSystem(ofFolder: try tree.make("f")) == BuildSystem.none)
}

@Test
func whenSeveralSystemsAreInOneFolderTheOrderIsFixedAndNotGuessed() throws {
    let tree = try Tree()
    let both = try tree.make("both", marker: "Package.swift")
    try "x".write(toFile: both + "/MODULE.bazel", atomically: true, encoding: .utf8)
    #expect(ProjectContexts.buildSystem(ofFolder: both) == .swiftPM, "SwiftPM first, as before; a mixed folder is the user's to choose")
}

// MARK: Which context a file has

@MainActor @Test
func withNoFolderOpenAFileBelongsToItsNearestPackageAsBefore() throws {
    let tree = try Tree()
    let package = try tree.make("pkg", marker: "Package.swift")
    try tree.make("pkg/Sources/App", file: "main.swift")
    let contexts = ProjectContexts()

    let context = try #require(contexts.context(forFile: tree.path("pkg/Sources/App/main.swift")))
    #expect(context.root == package && context.buildSystem == .swiftPM && !context.isExplicit)
    #expect(contexts.context(forFile: tree.path("loose/a.swift")) == nil)
}

@MainActor @Test
func anOpenedFolderTakesPriorityOverANestedPackage() throws {
    let tree = try Tree()
    let outer = try tree.make("repo", marker: "MODULE.bazel")
    try tree.make("repo/Vendor/lib", marker: "Package.swift", file: "L.swift")
    let contexts = ProjectContexts()
    contexts.open(folder: outer)

    let context = try #require(contexts.context(forFile: tree.path("repo/Vendor/lib/L.swift")))
    #expect(context.root == outer, "a nested package does not silently change the workspace")
    #expect(context.buildSystem == .bazel && context.isExplicit)
}

@MainActor @Test
func ofSeveralOpenedFoldersTheInnermostThatHoldsTheFileIsUsed() throws {
    let tree = try Tree()
    let outer = try tree.make("repo")
    let inner = try tree.make("repo/app", marker: "Package.swift", file: "a.swift")
    let contexts = ProjectContexts()
    contexts.open(folder: outer)
    contexts.open(folder: inner)

    #expect(contexts.context(forFile: tree.path("repo/app/a.swift"))?.root == inner)
    #expect(contexts.context(forFile: tree.path("repo/other.swift"))?.root == outer)
}

@MainActor @Test
func aFolderThatMerelyStartsWithTheSameLettersDoesNotHoldTheFile() throws {
    let tree = try Tree()
    let folder = try tree.make("app")
    try tree.make("app-extra", marker: "Package.swift", file: "x.swift")
    let contexts = ProjectContexts()
    contexts.open(folder: folder)

    let context = try #require(contexts.context(forFile: tree.path("app-extra/x.swift")))
    #expect(!context.isExplicit && context.root == tree.path("app-extra"))
}

@MainActor @Test
func anOpenedFolderWithNoProjectInItHasNoBuildSystem() throws {
    let tree = try Tree()
    let folder = try tree.make("plain")
    let contexts = ProjectContexts()
    contexts.open(folder: folder)

    let context = try #require(contexts.context(forFile: tree.path("plain/a.swift")))
    #expect(context.buildSystem == BuildSystem.none && context.isExplicit)
}

@MainActor @Test
func aFolderIsKeptUnderItsCanonicalPath() throws {
    let tree = try Tree()
    let real = try tree.make("real", marker: "Package.swift", file: "a.swift")
    let link = tree.path("link")
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
    let contexts = ProjectContexts()
    contexts.open(folder: link)

    #expect(contexts.openedFolders == [real])
    #expect(contexts.context(forFile: real + "/a.swift")?.isExplicit == true)
}

// MARK: Revision and changes

@MainActor @Test
func theRevisionGrowsWhenTheSetOfOpenedFoldersChangesAndOnlyThen() throws {
    let tree = try Tree()
    let a = try tree.make("a"), b = try tree.make("b")
    let contexts = ProjectContexts()
    let start = contexts.revision
    var heard = 0
    let id = contexts.subscribe { heard += 1 }

    contexts.open(folder: a)
    #expect(contexts.revision == start + 1 && heard == 1)
    contexts.open(folder: a)
    #expect(contexts.revision == start + 1 && heard == 1, "opening the same folder again changes nothing")
    contexts.open(folder: b)
    #expect(contexts.revision == start + 2)
    contexts.close(folder: a)
    #expect(contexts.revision == start + 3 && contexts.openedFolders == [b])
    contexts.close(folder: a)
    #expect(contexts.revision == start + 3, "closing what is not open changes nothing")

    contexts.unsubscribe(id)
    contexts.close(folder: b)
    #expect(heard == 3, "an unsubscribed observer hears nothing")
}

@MainActor @Test
func aContextCarriesTheRevisionItWasMadeAt() throws {
    let tree = try Tree()
    let a = try tree.make("a", marker: "Package.swift", file: "f.swift")
    let contexts = ProjectContexts()
    let before = try #require(contexts.context(forFile: a + "/f.swift"))
    contexts.open(folder: a)
    let after = try #require(contexts.context(forFile: a + "/f.swift"))

    #expect(after.revision == before.revision + 1, "the same project, opened by the user: another context to the consumers")
    #expect(before != after)
}

// MARK: Temporary folders

@Test
func aPathInTheSystemTemporaryFolderIsRecognisedAndOthersAreNot() {
    #expect(TemporaryFolder.contains("/private/var/folders/ab/xyz/T/proj/main.c"))
    #expect(TemporaryFolder.contains("/var/folders/ab/xyz/T/proj/main.c"))
    #expect(TemporaryFolder.contains("/tmp/proj/main.c"))
    #expect(TemporaryFolder.contains("/private/tmp/proj/main.c"))
    #expect(!TemporaryFolder.contains("/Users/me/proj/main.c"))
    #expect(!TemporaryFolder.contains("/tmpfoo/main.c"), "only the folder itself, not a name that starts like it")
    #expect(!TemporaryFolder.contains("/Users/me/Library/Caches/proj/main.c"))
}

@Test
func theNoteIsForTheCFamilyOnlyBecauseThatIsWhatLosesItsFlags() {
    #expect(TemporaryFolder.note(path: "/tmp/p/a.c", isCFamily: true) == "temporary folder: C-family flags may be missing")
    #expect(TemporaryFolder.note(path: "/tmp/p/a.swift", isCFamily: false) == nil)
    #expect(TemporaryFolder.note(path: "/Users/me/p/a.c", isCFamily: true) == nil)
}

// MARK: A project below a folder

@Test
func aProjectBelowAFolderIsFoundAFewLevelsDownAndNotBeyond() throws {
    let tree = try Tree()
    try tree.make("one/lib", marker: "Package.swift")
    try tree.make("two/a/b/lib", marker: "Package.swift")
    try tree.make("three/a/b/c/d/lib", marker: "Package.swift")
    try tree.make("four/src", file: "a.swift")
    try tree.make("five/.hidden/lib", marker: "Package.swift")

    #expect(ProjectContexts.containsProject(below: tree.path("one")))
    #expect(ProjectContexts.containsProject(below: tree.path("two")), "three levels down")
    #expect(!ProjectContexts.containsProject(below: tree.path("three")), "deeper than the scan goes")
    #expect(!ProjectContexts.containsProject(below: tree.path("four")))
    #expect(!ProjectContexts.containsProject(below: tree.path("five")), "hidden folders are not looked into")
}

@Test
func theScanOfAFolderIsBounded() throws {
    let tree = try Tree()
    let wide = try tree.make("wide")
    for i in 0..<60 { try FileManager.default.createDirectory(atPath: wide + "/d\(i)", withIntermediateDirectories: true) }
    try tree.make("wide/d59", marker: "Package.swift")

    #expect(!ProjectContexts.containsProject(below: wide, limit: 20), "gives up at the limit rather than walk a whole disk")
    #expect(ProjectContexts.containsProject(below: wide, limit: 5000))
}

// MARK: The target of a file in the context

private func oneTargetLayout(root: String) -> PackageLayout {
    PackageLayout(targets: [PackageTarget(name: "App", kind: .executable, directory: root + "/Sources/App", sources: ["main.swift"])])
}

@MainActor @Test
func aContextCarriesTheTargetOfItsFileOnceThePackageLayoutIsKnown() throws {
    let tree = try Tree()
    let root = try tree.make("pkg", marker: "Package.swift")
    try tree.make("pkg/Sources/App", file: "main.swift")
    let file = root + "/Sources/App/main.swift"
    let contexts = ProjectContexts()
    #expect(try #require(contexts.context(forFile: file)).targetNames.isEmpty, "unknown until the layout is")

    contexts.setLayout(oneTargetLayout(root: root), forRoot: root)
    let context = try #require(contexts.context(forFile: file))
    #expect(context.target == "App" && context.targetNames == ["App"])
    #expect(try #require(contexts.context(forFile: root + "/Package.swift")).target == nil, "a file of no target has none")
}

@MainActor @Test
func settingALayoutChangesTheRevisionAndAnObserverHearsOnlyWhenTheLayoutDiffers() throws {
    let tree = try Tree()
    let root = try tree.make("pkg", marker: "Package.swift")
    let contexts = ProjectContexts()
    let start = contexts.revision
    var heard = 0
    contexts.subscribe { heard += 1 }

    contexts.setLayout(oneTargetLayout(root: root), forRoot: root)
    #expect(contexts.revision == start + 1 && heard == 1)
    contexts.setLayout(oneTargetLayout(root: root), forRoot: root)
    #expect(contexts.revision == start + 1 && heard == 1, "the same layout again changes nothing")
    contexts.setLayout(nil, forRoot: root)
    #expect(contexts.revision == start + 2 && heard == 2 && contexts.layout(forRoot: root) == nil)
    contexts.setLayout(nil, forRoot: root)
    #expect(contexts.revision == start + 2, "nothing to forget")
}

@MainActor @Test
func aLayoutBelongsToItsRootAndNotToAnother() throws {
    let tree = try Tree()
    let a = try tree.make("a", marker: "Package.swift")
    let b = try tree.make("b", marker: "Package.swift")
    try tree.make("a/Sources/App", file: "main.swift")
    try tree.make("b/Sources/App", file: "main.swift")
    let contexts = ProjectContexts()
    contexts.setLayout(oneTargetLayout(root: a), forRoot: a)

    #expect(contexts.context(forFile: a + "/Sources/App/main.swift")?.target == "App")
    #expect(contexts.context(forFile: b + "/Sources/App/main.swift")?.target == nil)
}

@MainActor @Test
func aContextCarriesHowItsTargetWasSettled() throws {
    let tree = try Tree()
    let root = try tree.make("pkg", marker: "Package.swift")
    try tree.make("pkg/Sources/App", file: "main.swift")
    let contexts = ProjectContexts()
    contexts.setLayout(oneTargetLayout(root: root), forRoot: root)

    #expect(contexts.context(forFile: root + "/Sources/App/main.swift")?.targetBasis == .listed)
    #expect(contexts.context(forFile: root + "/Sources/App/new.swift")?.targetBasis == .inferred)
    #expect(contexts.context(forFile: root + "/Package.swift")?.targetBasis == nil)
}

// MARK: Toolchain and configuration in the context

private let toolchain = Toolchain(swift: "/x/swift", sourceKitLSP: "/x/sourcekit-lsp", version: "Swift 6.4")

@MainActor @Test
func aContextKnowsNothingOfItsToolsUntilTheyAreSet() throws {
    let tree = try Tree()
    let root = try tree.make("pkg", marker: "Package.swift")
    let contexts = ProjectContexts()
    let context = try #require(contexts.context(forFile: root + "/Sources/a.swift"))

    #expect(context.environment == ProjectEnvironment() && context.environment.toolchain == nil && context.environment.configuration == .unknown)
}

@MainActor @Test
func theEnvironmentIsKeptPerRootAndShownInTheContextsOfItsFiles() throws {
    let tree = try Tree()
    let a = try tree.make("a", marker: "Package.swift")
    let b = try tree.make("b", marker: "Package.swift")
    let contexts = ProjectContexts()
    let environment = ProjectEnvironment(toolchain: toolchain, configuration: .selected("release"))
    contexts.setEnvironment(environment, forRoot: a)

    #expect(contexts.context(forFile: a + "/Sources/x.swift")?.environment == environment)
    #expect(contexts.context(forFile: b + "/Sources/x.swift")?.environment == ProjectEnvironment())
    #expect(contexts.environment(forRoot: a) == environment && contexts.environment(forRoot: b) == nil)
}

@MainActor @Test
func aChangedEnvironmentIsANewRevisionAndAnUnchangedOneIsNot() throws {
    let tree = try Tree()
    let root = try tree.make("pkg", marker: "Package.swift")
    let contexts = ProjectContexts()
    var heard = 0
    contexts.subscribe { heard += 1 }
    let release = ProjectEnvironment(toolchain: toolchain, configuration: .selected("release"))

    contexts.setEnvironment(release, forRoot: root)
    let revision = contexts.revision
    contexts.setEnvironment(release, forRoot: root)
    #expect(contexts.revision == revision && heard == 1, "the same environment again changes nothing")

    contexts.setEnvironment(ProjectEnvironment(toolchain: toolchain, configuration: .inherited("debug")), forRoot: root)
    #expect(contexts.revision == revision + 1 && heard == 2, "another configuration makes another context")
    let other = Toolchain(swift: "/y/swift", sourceKitLSP: "/y/sourcekit-lsp", version: "Swift 6.5")
    contexts.setEnvironment(ProjectEnvironment(toolchain: other, configuration: .inherited("debug")), forRoot: root)
    #expect(contexts.revision == revision + 2, "another toolchain makes another context")
}

@MainActor @Test
func aChangedEnvironmentDropsTheLayoutAnUnchangedOneKeepsIt() throws {
    let tree = try Tree()
    let root = try tree.make("pkg", marker: "Package.swift")
    let contexts = ProjectContexts()
    let first = ProjectEnvironment(toolchain: toolchain, configuration: .inherited("debug"))
    contexts.setEnvironment(first, forRoot: root)
    contexts.setLayout(oneTargetLayout(root: root), forRoot: root)

    contexts.setEnvironment(first, forRoot: root)
    #expect(contexts.layout(forRoot: root) != nil, "nothing changed: the layout is still the answer")
    contexts.setEnvironment(ProjectEnvironment(toolchain: toolchain, configuration: .selected("release")), forRoot: root)
    #expect(contexts.layout(forRoot: root) == nil, "made under another configuration: asked for again")

    contexts.setLayout(oneTargetLayout(root: root), forRoot: root)
    contexts.setEnvironment(ProjectEnvironment(toolchain: Toolchain(swift: "/y/swift", sourceKitLSP: "/y/s", version: "6.5"), configuration: .selected("release")), forRoot: root)
    #expect(contexts.layout(forRoot: root) == nil, "made by another toolchain: asked for again")
}

@MainActor @Test
func aChangedConfigurationFingerprintInvalidatesTheLayoutAndContext() throws {
    let tree = try Tree()
    let root = try tree.make("pkg", marker: "Package.swift")
    let contexts = ProjectContexts()
    var environment = ProjectEnvironment(toolchain: toolchain, configuration: .inherited("debug"), configurationFingerprint: "before")
    contexts.setEnvironment(environment, forRoot: root)
    contexts.setLayout(oneTargetLayout(root: root), forRoot: root)
    let before = try #require(contexts.context(forFile: root + "/Sources/App/main.swift"))

    environment.configurationFingerprint = "after"
    contexts.setEnvironment(environment, forRoot: root)

    let after = try #require(contexts.context(forFile: root + "/Sources/App/main.swift"))
    #expect(after.revision > before.revision && after != before)
    #expect(after.environment.configuration == before.environment.configuration)
    #expect(after.target == nil && contexts.layout(forRoot: root) == nil)

    contexts.setLayout(oneTargetLayout(root: root), forRoot: root)
    let revision = contexts.revision
    contexts.setEnvironment(environment, forRoot: root)
    #expect(contexts.revision == revision && contexts.layout(forRoot: root) != nil)
}
