import Darwin
import Foundation
import IDEApplication

public struct ProjectFolderChecker: ProjectFolderChecking {
    public init() {}

    public func check(path: String) async -> ProjectFolderAvailability {
        await Task.detached(priority: .utility) { () -> ProjectFolderAvailability in
            let root = DocumentPath.canonical(path)
            guard let directory = opendir(root) else {
                let code = errno

                return code == ENOENT || code == ENOTDIR ? .missing : .unavailable(String(cString: strerror(code)))
            }

            closedir(directory)
            guard access(root, X_OK) == 0 else { return .unavailable("This folder cannot be accessed.") }

            return .available(canonicalPath: root)
        }.value
    }
}
