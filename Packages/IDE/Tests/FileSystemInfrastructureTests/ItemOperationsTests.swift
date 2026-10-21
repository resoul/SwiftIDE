import FileSystemInfrastructure
import Foundation
import IDEApplication
import Testing

private func folder(_ files: [String]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("items-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for file in files {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(file.utf8).write(to: url)
    }

    return root.standardizedFileURL.path
}

@Test
func aCopyNameKeepsTheExtensionAndCountsUpWhenTaken() {
    #expect(ItemName.copyName(of: "Main.swift") == "Main copy.swift")
    #expect(ItemName.copyName(of: "Notes") == "Notes copy")
    #expect(ItemName.copyName(of: ".env") == ".env copy")
    #expect(ItemName.copyName(of: "a.tar.gz") == "a.tar copy.gz")
    let taken: Set = ["Main copy.swift", "Main copy 2.swift"]
    #expect(ItemName.copyName(of: "Main.swift") { taken.contains($0) } == "Main copy 3.swift")
}

@Test
func anExistingItemTakesOneSimpleName() throws {
    #expect(try ItemName.single(" New.swift ") == "New.swift")
    for bad in ["", "a/b", "..", "a:b"] { #expect(throws: NewEntryError.self, "\(bad)") { try ItemName.single(bad) } }
}

@Test
func renameMovesTheItemKeepsItsContentAndRefusesAnExistingName() throws {
    let root = try folder(["a.txt", "b.txt", "dir/inner.txt"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let items = FileSystemItemOperations(root: root)
    let renamed = try items.rename(root + "/a.txt", to: "c.txt")
    #expect(renamed == root + "/c.txt" && !FileManager.default.fileExists(atPath: root + "/a.txt"))
    #expect(try String(contentsOfFile: renamed, encoding: .utf8) == "a.txt")
    #expect(throws: NewEntryError.alreadyExists("b.txt")) { try items.rename(root + "/c.txt", to: "b.txt") }
    #expect(try items.rename(root + "/b.txt", to: "b.txt") == root + "/b.txt")
    let folder = try items.rename(root + "/dir", to: "moved")
    #expect(FileManager.default.fileExists(atPath: folder + "/inner.txt"))
}

@Test
func aChangeOfLetterCaseOnlyIsAllowed() throws {
    let root = try folder(["readme.md"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let renamed = try FileSystemItemOperations(root: root).rename(root + "/readme.md", to: "README.md")
    #expect(renamed == root + "/README.md")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["README.md"])
}

@Test
func duplicateCopiesAFileOrAFolderNextToItAndNeverOverwrites() throws {
    let root = try folder(["a.txt", "dir/inner.txt"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let items = FileSystemItemOperations(root: root)
    let copy = try items.duplicate(root + "/a.txt", as: "a copy.txt")
    #expect(try String(contentsOfFile: copy, encoding: .utf8) == "a.txt" && FileManager.default
        .fileExists(atPath: root + "/a.txt"))
    let folderCopy = try items.duplicate(root + "/dir", as: "dir copy")
    #expect(FileManager.default.fileExists(atPath: folderCopy + "/inner.txt"))
    #expect(throws: NewEntryError.alreadyExists("a copy.txt")) {
        try items.duplicate(root + "/a.txt", as: "a copy.txt")
    }
}

@Test
func nothingOutsideTheProjectOrTheProjectItselfOrAMissingItemIsChanged() throws {
    let root = try folder(["a.txt"])
    let other = try folder(["x.txt"])
    defer {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: other)
    }
    let items = FileSystemItemOperations(root: root)
    #expect(throws: NewEntryError.outsideProject) { try items.rename(other + "/x.txt", to: "y.txt") }
    #expect(throws: NewEntryError.isProjectFolder) { try items.rename(root, to: "renamed") }
    #expect(throws: NewEntryError.isProjectFolder) { try items.trash(root) }
    #expect(throws: NewEntryError.outsideProject) { try items.trash(other + "/x.txt") }
    #expect(throws: NewEntryError.self) { try items.duplicate(root + "/missing.txt", as: "m") }
    try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: other)
    #expect(throws: NewEntryError.outsideProject) { try items.rename(root + "/link/x.txt", to: "z.txt") }
    #expect(FileManager.default.fileExists(atPath: other + "/x.txt"))
}

@Test
func moveGoesIntoAFolderKeepsTheNameAndRefusesTakenNamesAndItself() throws {
    let root = try folder(["a.txt", "dir/a.txt", "dir/sub/x.txt", "other/y.txt"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let items = FileSystemItemOperations(root: root)
    #expect(try items.move(root + "/other/y.txt", into: root + "/dir") == root + "/dir/y.txt")
    #expect(FileManager.default.fileExists(atPath: root + "/dir/y.txt") && !FileManager.default
        .fileExists(atPath: root + "/other/y.txt"))
    #expect(throws: NewEntryError.alreadyExists("a.txt")) { try items.move(root + "/a.txt", into: root + "/dir") }
    #expect(try items.move(root + "/dir/a.txt", into: root + "/dir") == root + "/dir/a.txt", "already there")
    #expect(throws: NewEntryError.intoItself) { try items.move(root + "/dir", into: root + "/dir/sub") }
    #expect(throws: NewEntryError.intoItself) { try items.move(root + "/dir", into: root + "/dir") }
    #expect(throws: NewEntryError.notAFolder) { try items.move(root + "/a.txt", into: root + "/dir/a.txt") }
    #expect(throws: NewEntryError.isProjectFolder) { try items.move(root, into: root + "/dir") }
}

@Test
func copyTakesFilesFromAnywhereIntoTheProjectAndNeverOverwrites() throws {
    let root = try folder(["a.txt", "dir/inner.txt"])
    let outside = try folder(["from.txt", "tree/leaf.txt"])
    defer {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: outside)
    }
    let items = FileSystemItemOperations(root: root)
    #expect(try items.copy(outside + "/from.txt", into: root) == root + "/from.txt")
    #expect(
        try items.copy(outside + "/from.txt", into: root) == root + "/from copy.txt",
        "a taken name gets a copy name"
    )
    #expect(try items.copy(root + "/a.txt", into: root + "/dir") == root + "/dir/a.txt")
    let tree = try items.copy(outside + "/tree", into: root)
    #expect(FileManager.default.fileExists(atPath: tree + "/leaf.txt") && FileManager.default
        .fileExists(atPath: outside + "/tree/leaf.txt"))
    #expect(throws: NewEntryError.intoItself) { try items.copy(root + "/dir", into: root + "/dir") }
    #expect(throws: NewEntryError.outsideProject) { try items.copy(root + "/a.txt", into: outside) }
    #expect(throws: NewEntryError.self) { try items.copy(outside + "/missing.txt", into: root) }
    #expect(try String(contentsOfFile: root + "/a.txt", encoding: .utf8) == "a.txt")
}
