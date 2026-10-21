import FileSystemInfrastructure
import Foundation
import IDEApplication
import Testing

private func folder(_ files: [String] = []) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("create-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for file in files {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    return root.standardizedFileURL.path
}

@Test
func aNameIsASlashSeparatedPathOfUsableParts() throws {
    #expect(try NewEntryName.parts(of: " Sources/App/Main.swift ") == ["Sources", "App", "Main.swift"])
    #expect(throws: NewEntryError.emptyName) { try NewEntryName.parts(of: "  ") }
    for bad in ["../x", "a//b", "a/./b", "a:b", "/abs"] {
        #expect(throws: NewEntryError.self, "\(bad)") { try NewEntryName.parts(of: bad) }
    }
}

@Test
func aFileAndAFolderAreCreatedInsideAFolderAndNeverOverwritten() throws {
    let root = try folder(["old.txt"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let creator = FileSystemEntryCreator(root: root)
    let file = try creator.create(.file, named: "New.swift", in: root)
    #expect(file == root + "/New.swift" && FileManager.default.fileExists(atPath: file))
    #expect((try? Data(contentsOf: URL(fileURLWithPath: file)))?.isEmpty == true)
    let directory = try creator.create(.folder, named: "Sub", in: root)
    var isFolder: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder) && isFolder.boolValue)
    #expect(throws: NewEntryError.alreadyExists("old.txt")) { try creator.create(.file, named: "old.txt", in: root) }
    #expect(throws: NewEntryError.alreadyExists("Sub")) { try creator.create(.folder, named: "Sub", in: root) }
}

@Test
func aSwiftFileGetsItsExtensionAndAnImportButAPlainFileIsLeftAsTyped() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let creator = FileSystemEntryCreator(root: root)
    let swift = try creator.create(.swiftFile, named: "Sources/Model", in: root)
    #expect(swift == root + "/Sources/Model.swift")
    #expect(try String(contentsOfFile: swift, encoding: .utf8) == "import Foundation\n")
    #expect(try creator.create(.swiftFile, named: "Done.swift", in: root) == root + "/Done.swift")
    #expect(try creator.create(.swiftFile, named: "Data.helper", in: root) == root + "/Data.helper")
    let plain = try creator.create(.file, named: "Notes", in: root)
    #expect(plain == root + "/Notes" && (try? Data(contentsOf: URL(fileURLWithPath: plain)))?.isEmpty == true)
    #expect(throws: NewEntryError.alreadyExists("Model.swift")) {
        try creator.create(.swiftFile, named: "Sources/Model", in: root)
    }
    #expect(NewEntryKind.swiftFile.fileName(forTyped: "Name.") == "Name.")
    #expect(NewEntryKind.file.fileName(forTyped: "Name") == "Name")
}

@Test
func aTypedPathCreatesTheFoldersInBetweenAndReusesExistingOnes() throws {
    let root = try folder(["Sources/a.swift"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let creator = FileSystemEntryCreator(root: root)
    let path = try creator.create(.file, named: "Sources/App/Deep/Main.swift", in: root)
    #expect(path == root + "/Sources/App/Deep/Main.swift" && FileManager.default.fileExists(atPath: path))
    #expect(throws: NewEntryError.alreadyExists("a.swift")) {
        try creator.create(.file, named: "a.swift/inner.swift", in: root + "/Sources")
    }
}

@Test
func nothingIsCreatedOutsideTheProjectOrInsideAFile() throws {
    let root = try folder(["file.txt"])
    let other = try folder()
    defer {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: other)
    }
    let creator = FileSystemEntryCreator(root: root)
    #expect(throws: NewEntryError.outsideProject) { try creator.create(.file, named: "x", in: other) }
    #expect(throws: NewEntryError.notAFolder) { try creator.create(.file, named: "x", in: root + "/file.txt") }
    try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: other)
    #expect(throws: NewEntryError.outsideProject) { try creator.create(.file, named: "x", in: root + "/link") }
    #expect(!FileManager.default.fileExists(atPath: other + "/x"))
}

@Test @MainActor
func theModelCreatesShowsAndSelectsTheNewItem() async throws {
    let root = try folder(["a.txt"])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let model = ProjectFiles(root: root, reader: ProjectDirectoryReader(), creator: FileSystemEntryCreator(root: root))
    model.expand(model.root)
    for _ in 0..<300 where model.state(of: model.root) != .loaded { try await Task.sleep(for: .milliseconds(10)) }
    let path = try model.create(.file, named: "Deep/New.swift", in: model.root)
    #expect(model.selection == path && model.expanded.contains(model.root + "/Deep"))
    for _ in 0..<300 where !model.children(of: model.root + "/Deep").contains(where: { $0.path == path }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.children(of: model.root).map(\.name).contains("Deep"))
    #expect(model.children(of: model.root + "/Deep").map(\.name) == ["New.swift"])
    #expect(throws: NewEntryError.outsideProject) { try model.create(.file, named: "x", in: "/elsewhere") }
    model.stop()
    #expect(throws: NewEntryError.self) {
        try ProjectFiles(root: root, reader: ProjectDirectoryReader()).create(.file, named: "x", in: root)
    }
}
