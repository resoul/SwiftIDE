import Foundation
import IDEApplication

/// Lists the files of a project folder. In a Git working tree Git itself says which files count
/// (tracked ones and untracked ones that are not ignored); elsewhere the folder is walked, leaving
/// out version-control and build folders. Neither follows symbolic links.
public struct FileSystemProjectFileLister: ProjectFileLister {
    public static let defaultLimit = 100_000
    static let skippedFolders: Set<String> = [
        ".git",
        ".build",
        "node_modules",
        "DerivedData",
        ".swiftpm",
        ".svn",
        ".hg"
    ]

    private let limit: Int
    private let gitPath: String

    public init(limit: Int = FileSystemProjectFileLister.defaultLimit, gitPath: String = "/usr/bin/git") {
        self.limit = limit
        self.gitPath = gitPath
    }

    public func listFiles(under root: String) async -> ProjectFileList {
        let limit = limit, gitPath = gitPath
        let task = Task.detached(priority: .userInitiated) {
            if let list = Self.gitListing(of: root, limit: limit, gitPath: gitPath) { return list }

            return Self.walk(root, limit: limit)
        }

        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func gitListing(of root: String, limit: Int, gitPath: String) -> ProjectFileList? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root + "/.git", isDirectory: &isDirectory),
              FileManager.default.isExecutableFile(atPath: gitPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Read until the pipe closes so a big listing cannot fill it and block git.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !Task.isCancelled else { return nil }

        var seen = Set<String>()
        var paths: [String] = []
        var truncated = false
        for slice in data.split(separator: 0) {
            guard let path = String(data: slice, encoding: .utf8), seen.insert(path).inserted else { continue }

            // `--cached` also lists files deleted in the working tree; a path that is not a file
            // here cannot be opened.
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &isFolder), !isFolder.boolValue
            else { continue }

            if paths.count == limit {
                truncated = true
                break
            }

            paths.append(path)
        }

        return ProjectFileList(paths: paths.sorted(), isTruncated: truncated)
    }

    static func walk(_ root: String, limit: Int) -> ProjectFileList {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return ProjectFileList(paths: []) }

        var paths: [String] = []
        let prefix = base.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            if Task.isCancelled { break }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }

                continue
            }

            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }

            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }

            if paths.count == limit { return ProjectFileList(paths: paths.sorted(), isTruncated: true) }

            paths.append(String(full.dropFirst(prefix.count)))
        }

        return ProjectFileList(paths: paths.sorted())
    }
}
