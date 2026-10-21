import Foundation
import IDEApplication

/// Creates new files and folders inside one project folder. It never overwrites, never leaves the
/// folder (a symbolic link out of it does not count as inside) and creates the folders a typed
/// path passes through.
public struct FileSystemEntryCreator: ProjectEntryCreating {
    private let root: String

    public init(root: String) { self.root = DocumentPath.canonical(root) }

    public func create(_ kind: NewEntryKind, named name: String, in directory: String) throws -> String {
        var parts = try NewEntryName.parts(of: name)
        if kind != .folder { parts[parts.count - 1] = kind.fileName(forTyped: parts[parts.count - 1]) }

        let base = DocumentPath.canonical(directory)
        guard base == root || base.hasPrefix(root + "/") else { throw NewEntryError.outsideProject }

        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base, isDirectory: &isFolder), isFolder.boolValue else {
            throw NewEntryError.notAFolder
        }

        let manager = FileManager.default
        var current = directory
        for (index, part) in parts.enumerated() {
            current = (current as NSString).appendingPathComponent(part)
            let isLast = index == parts.count - 1
            var exists: ObjCBool = false
            let present = manager.fileExists(atPath: current, isDirectory: &exists)
            do {
                if isLast {
                    guard !present else { throw NewEntryError.alreadyExists(part) }

                    guard DocumentPath.canonical((current as NSString).deletingLastPathComponent)
                        .hasPrefix(root) else { throw NewEntryError.outsideProject }

                    if kind == .folder {
                        try manager.createDirectory(atPath: current, withIntermediateDirectories: false)
                    } else if !manager.createFile(atPath: current, contents: kind.initialContents) {
                        throw NewEntryError.failed("the file could not be written")
                    }
                } else if present {
                    guard exists.boolValue else { throw NewEntryError.alreadyExists(part) }

                    guard DocumentPath.canonical(current).hasPrefix(root) else { throw NewEntryError.outsideProject }
                } else {
                    try manager.createDirectory(atPath: current, withIntermediateDirectories: false)
                }
            } catch let error as NewEntryError {
                throw error
            } catch {
                throw NewEntryError.failed(error.localizedDescription)
            }
        }

        return current
    }
}
