import Foundation
import IDEApplication

public struct ProjectDirectoryReader: ProjectDirectoryReading {
    public init() {}

    public func children(of path: String) async throws -> [ProjectFile] {
        let task = Task.detached(priority: .userInitiated) {
            // A directory may have been replaced by a link after its parent was listed.
            guard DocumentPath.canonical(path) == URL(fileURLWithPath: path).standardizedFileURL.path else {
                throw DirectoryReadError.linkedFolder
            }

            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            let entries = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: keys,
                options: []
            )

            return try entries.map { url in
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: Set(keys))
                // Foundation may spell /private/var as /var in returned URLs. Keep the caller's
                // directory identity for tree edges and resolve document identity separately.
                let entryPath = (path as NSString).appendingPathComponent(url.lastPathComponent)
                let linked = values.isSymbolicLink == true
                var directory: ObjCBool = false
                if linked { _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) }

                return ProjectFile(path: entryPath,
                                   isDirectory: values.isDirectory == true || directory.boolValue,
                                   isSymbolicLink: linked,
                                   resolvedPath: DocumentPath.canonical(entryPath))
            }
        }

        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private enum DirectoryReadError: LocalizedError {
    case linkedFolder
    var errorDescription: String? { "Linked folders are not expanded. Reveal this folder in Finder." }
}
