import Foundation
import FileSystemInfrastructure
import IDEApplication
import Testing

struct ProjectDirectoryReaderTests {
    @Test func listingIncludesHiddenEntriesAndLinksButDoesNotWalkThem() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SwiftIDE-tree-\(UUID())").resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root.appendingPathComponent(".build/deeper"), withIntermediateDirectories: true)
        try "text".write(to: root.appendingPathComponent("a name\nwith newline.txt"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("cycle").path, withDestinationPath: root.path)
        let entries = try await ProjectDirectoryReader().children(of: root.path)
        #expect(Set(entries.map(\.name)) == [".build", "cycle", "a name\nwith newline.txt"])
        #expect(entries.allSatisfy { ($0.path as NSString).deletingLastPathComponent == root.path })
        let link = try #require(entries.first { $0.name == "cycle" })
        #expect(link.isDirectory && link.isSymbolicLink && !link.canExpand)
        #expect(link.resolvedPath == root.path)
        do {
            _ = try await ProjectDirectoryReader().children(of: link.path)
            Issue.record("a replaced/linked directory must not be followed")
        } catch {
            #expect(error.localizedDescription.contains("Linked folders"))
        }
    }

    @Test func missingFolderProducesAnErrorRatherThanAnEmptyListing() async {
        do {
            _ = try await ProjectDirectoryReader().children(of: "/private/tmp/SwiftIDE-missing-\(UUID())")
            Issue.record("missing folder must fail")
        } catch { #expect(!(error is CancellationError)) }
    }
}
