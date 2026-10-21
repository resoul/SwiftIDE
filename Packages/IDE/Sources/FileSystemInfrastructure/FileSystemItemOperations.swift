import Foundation
import IDEApplication

/// Renames, copies and trashes items inside one project folder.
public struct FileSystemItemOperations: ProjectItemOperating {
    private let root: String

    public init(root: String) { self.root = DocumentPath.canonical(root) }

    public func rename(_ path: String, to name: String) throws -> String {
        let newName = try ItemName.single(name)
        let (parent, current) = try locate(path)
        let target = (parent as NSString).appendingPathComponent(newName)
        if newName == current { return path }

        let manager = FileManager.default
        let sameFile = manager.fileExists(atPath: target)
            && (try? manager.attributesOfItem(atPath: target)[.systemFileNumber] as? Int)
            == (try? manager.attributesOfItem(atPath: path)[.systemFileNumber] as? Int)
        if manager.fileExists(atPath: target), !sameFile { throw NewEntryError.alreadyExists(newName) }

        do {
            if sameFile {
                // A change of letter case only: the name is the same file on a case-insensitive
                // volume, so go through a temporary name.
                let temporary = (parent as NSString).appendingPathComponent(".rename-\(UUID().uuidString)")
                try manager.moveItem(atPath: path, toPath: temporary)
                do { try manager.moveItem(atPath: temporary, toPath: target) } catch {
                    try? manager.moveItem(atPath: temporary, toPath: path)
                    throw error
                }
            } else {
                try manager.moveItem(atPath: path, toPath: target)
            }
        } catch {
            throw NewEntryError.failed(error.localizedDescription)
        }

        return target
    }

    public func duplicate(_ path: String, as name: String) throws -> String {
        let newName = try ItemName.single(name)
        let (parent, _) = try locate(path)
        let target = (parent as NSString).appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: target) else { throw NewEntryError.alreadyExists(newName) }

        do { try FileManager.default.copyItem(atPath: path, toPath: target) } catch {
            throw NewEntryError.failed(error.localizedDescription)
        }

        return target
    }

    public func trash(_ path: String) throws {
        _ = try locate(path)
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } catch {
            throw NewEntryError.failed(error.localizedDescription)
        }
    }

    public func move(_ path: String, into directory: String) throws -> String {
        let (parent, name) = try locate(path)
        let destination = try checkedDestination(directory, for: path)
        if DocumentPath.canonical(parent) == destination { return path }

        let target = (directory as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target) else { throw NewEntryError.alreadyExists(name) }

        do { try FileManager.default.moveItem(atPath: path, toPath: target) } catch {
            throw NewEntryError.failed(error.localizedDescription)
        }

        return target
    }

    public func copy(_ path: String, into directory: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, (try? FileManager.default.attributesOfItem(atPath: path)) != nil else {
            throw NewEntryError.failed("“\(name)” no longer exists.")
        }

        _ = try checkedDestination(directory, for: path)
        let taken = { FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent($0)) }
        let finalName = taken(name) ? ItemName.copyName(of: name, taken: taken) : name
        let target = (directory as NSString).appendingPathComponent(finalName)
        do { try FileManager.default.copyItem(atPath: path, toPath: target) } catch {
            throw NewEntryError.failed(error.localizedDescription)
        }

        return target
    }

    /// The canonical folder to put `source` in: inside the project, an existing folder, and not
    /// the source itself or anything under it.
    private func checkedDestination(_ directory: String, for source: String) throws -> String {
        let destination = DocumentPath.canonical(directory)
        guard destination == root || destination.hasPrefix(root + "/") else { throw NewEntryError.outsideProject }

        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination, isDirectory: &isFolder), isFolder.boolValue else {
            throw NewEntryError.notAFolder
        }

        let item = DocumentPath.canonical(source)
        if destination == item || destination.hasPrefix(item + "/") { throw NewEntryError.intoItself }

        return destination
    }

    /// The folder `path` is in and its own name, after checking that it is an existing item
    /// strictly inside the project (a link out of the project does not count as inside).
    private func locate(_ path: String) throws -> (parent: String, name: String) {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let canonicalParent = DocumentPath.canonical(parent)
        guard canonicalParent == root || canonicalParent.hasPrefix(root + "/") else {
            throw (DocumentPath.canonical(path) == root ? NewEntryError.isProjectFolder : NewEntryError.outsideProject)
        }

        guard (try? FileManager.default.attributesOfItem(atPath: path)) != nil else {
            throw NewEntryError.failed("“\(name)” no longer exists.")
        }

        return (parent, name)
    }
}
