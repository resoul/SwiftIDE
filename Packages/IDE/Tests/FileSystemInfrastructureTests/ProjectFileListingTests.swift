import FileSystemInfrastructure
import Foundation
import IDEApplication
import Testing

private func makeFolder(_ files: [String]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("listing-\(UUID().uuidString)")
    for file in files {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    return root.standardizedFileURL.path
}

private func git(_ root: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}

@Test
func aPlainFolderIsWalkedWithoutBuildAndVersionControlFolders() async throws {
    let root = try makeFolder(["a.swift", "Sources/b.swift", ".hidden", ".build/x.o", "node_modules/m/i.js"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let list = await FileSystemProjectFileLister().listFiles(under: root)
    #expect(list.paths == ["Sources/b.swift", "a.swift"] && !list.isTruncated)
}

@Test
func aGitFolderListsTrackedAndUnignoredFilesAndSkipsDeletedOnes() async throws {
    let root = try makeFolder(["a.swift", "gone.swift", "ignored.log", ".gitignore", "dir/b.swift"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data("*.log\n".utf8).write(to: URL(fileURLWithPath: root + "/.gitignore"))
    try git(root, ["init", "-q"])
    try git(root, ["add", "a.swift", "gone.swift", ".gitignore"])
    try FileManager.default.removeItem(atPath: root + "/gone.swift")
    let list = await FileSystemProjectFileLister().listFiles(under: root)
    #expect(list.paths == [".gitignore", "a.swift", "dir/b.swift"])
}

@Test
func theLimitTruncatesAndIsReported() async throws {
    let root = try makeFolder((0..<10).map { "f\($0).txt" })
    defer { try? FileManager.default.removeItem(atPath: root) }
    let list = await FileSystemProjectFileLister(limit: 4).listFiles(under: root)
    #expect(list.paths.count == 4 && list.isTruncated)
}
