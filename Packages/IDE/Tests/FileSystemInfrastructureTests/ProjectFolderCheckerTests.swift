import FileSystemInfrastructure
import Foundation
import IDEApplication
import Testing

struct ProjectFolderCheckerTests {
    @Test func rootsAreCanonicalAndNoManifestOrDirectoryTreeIsRead() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-folder-check-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project space")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "fatalError(\"Must never run\")".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let checker = ProjectFolderChecker()
        #expect(await checker.check(path: alias.path + "/.") == .available(canonicalPath: root.path))
        #expect(await checker.check(path: base.appendingPathComponent("missing").path) == .missing)
        #expect(await checker.check(path: root.appendingPathComponent("Package.swift").path) == .missing)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".build").path))
    }

    @Test func unreadableRootDoesNotBecomeAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-folder-denied-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        let result = await ProjectFolderChecker().check(path: root.path)
        guard case .unavailable = result else { Issue.record("expected unavailable, got \(result)"); return }
    }
}
