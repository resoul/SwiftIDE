import Foundation
import IDEApplication
import Testing
@testable import LanguageInfrastructure

// MARK: The toolchain

private func resolver(_ answers: [String: String], failing: Set<String> = []) -> XcodeToolchainResolver {
    XcodeToolchainResolver { executable, arguments in
        let key = ([executable.path] + arguments).joined(separator: " ")
        if failing.contains(key) { throw BoundedProcess.Failure.failed("exit 1") }

        return answers[key] ?? ""
    }
}

private let found = [
    "/usr/bin/xcrun --find swift": "/X/usr/bin/swift\n",
    "/usr/bin/xcrun --find sourcekit-lsp": "/X/usr/bin/sourcekit-lsp\n",
    "/X/usr/bin/swift --version": "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)\nTarget: arm64-apple-macosx27.0.0\n",
]

@Test
func theToolchainIsTheTwoToolsAndTheVersionTheSwiftReports() async {
    let toolchain = await resolver(found).resolve()

    #expect(toolchain == Toolchain(
        swift: "/X/usr/bin/swift",
        sourceKitLSP: "/X/usr/bin/sourcekit-lsp",
        version: "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"
    ))
}

@Test
func aToolchainWhoseAnyQuestionFailsOrIsAnsweredWithNothingIsUnknown() async {
    for key in found.keys {
        #expect(await resolver(found, failing: [key]).resolve() == nil, "\(key) fails")
        var empty = found
        empty[key] = "\n"
        #expect(await resolver(empty).resolve() == nil, "\(key) says nothing")
    }
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")))
func theRealXcodeToolchainIsFoundAndItsServerIsTheOneXcrunFinds() async throws {
    guard let toolchain = await XcodeToolchainResolver().resolve() else {
        Issue.record("no toolchain on this machine")

        return
    }

    #expect(FileManager.default.isExecutableFile(atPath: toolchain.swift) && FileManager.default.isExecutableFile(atPath: toolchain.sourceKitLSP))
    #expect(toolchain.version.contains("Swift"), Comment(rawValue: toolchain.version))
}

// MARK: The configuration files

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("config-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    return home
}

private func write(_ text: String, to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

@Test
func theUsersFilesAreReadInTheDocumentedOrderFromLowestPriorityToHighest() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try write("{\"a\":1}", to: home.path + "/.sourcekit-lsp/config.json")
    try write("{\"b\":1}", to: home.path + "/Library/Application Support/org.swift.sourcekit-lsp/config.json")
    try write("{\"c\":1}", to: home.path + "/xdg/sourcekit-lsp/config.json")

    let files = SourceKitConfigurationFiles(home: home.path, xdgConfigHome: home.path + "/xdg").userFiles()
    #expect(files == [.present(Data("{\"a\":1}".utf8)), .present(Data("{\"b\":1}".utf8)), .present(Data("{\"c\":1}".utf8))])
}

@Test
func aFileThatIsNotThereIsAbsentAndOneThatCannotBeReadIsSaidToBeUnreadable() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(SourceKitConfigurationFiles(home: home.path, xdgConfigHome: nil).userFiles() == [.absent, .absent], "no XDG place when none is set")

    let path = home.path + "/.sourcekit-lsp/config.json"
    try write("{}", to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
    #expect(SourceKitConfigurationFiles(home: home.path, xdgConfigHome: nil).userFiles()[0] == .unreadable)
}

@Test
func theProjectsFileIsTheOneInItsSourcekitLspFolder() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let files = SourceKitConfigurationFiles(home: home.path, xdgConfigHome: nil)
    #expect(files.projectFile(root: home.path) == .absent)

    try write("{\"x\":1}", to: home.path + "/.sourcekit-lsp/config.json")
    #expect(files.projectFile(root: home.path) == .present(Data("{\"x\":1}".utf8)))
}

@Test
func aConfigurationFileIsKnownByItsNameAndItsFolderAndAProjectsFileByItsRootToo() {
    #expect(SourceKitConfigurationFiles.isConfigurationFile("/w/pkg/.sourcekit-lsp/config.json"))
    #expect(!SourceKitConfigurationFiles.isConfigurationFile("/w/pkg/config.json"))
    #expect(!SourceKitConfigurationFiles.isConfigurationFile("/w/pkg/.sourcekit-lsp/other.json"))
    #expect(SourceKitConfigurationFiles.isProjectFile("/w/pkg/.sourcekit-lsp/config.json", root: "/w/pkg"))
    #expect(!SourceKitConfigurationFiles.isProjectFile("/w/other/.sourcekit-lsp/config.json", root: "/w/pkg"), "another project's file")
    #expect(!SourceKitConfigurationFiles.isProjectFile("/w/pkg/Sources/.sourcekit-lsp/config.json", root: "/w/pkg"), "only the root's own")
}
