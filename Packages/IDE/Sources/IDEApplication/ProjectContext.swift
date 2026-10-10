import Foundation

public enum BuildSystem: String, Sendable, Equatable {
    case swiftPM, xcode, bazel, compilationDatabase
    /// A folder with none of the markers: files in it are served one by one.
    case none
}

/// The project a document belongs to: where its root is, what builds it, and the revision of the
/// set of opened folders it was made at, so that a consumer can tell that the context it holds is
/// not the current one. (The target, configuration and toolchain join it with the target choice.)
public struct ProjectContext: Equatable, Sendable {
    public let root: String
    public let buildSystem: BuildSystem
    /// Chosen by the user with File ▸ Open Folder, as opposed to found by walking up from a file.
    public let isExplicit: Bool
    public let revision: Int
}

/// The folders the user opened, and the context of a file given them. An opened folder takes priority
/// over the nearest `Package.swift`: a nested package does not silently change the workspace.
@MainActor
public final class ProjectContexts {
    public private(set) var openedFolders: [String] = []
    /// Grows each time the set of opened folders changes.
    public private(set) var revision = 0
    private var observers: [UUID: @MainActor () -> Void] = [:]

    public init() {}

    // MARK: Folders

    public func open(folder: String) {
        let canonical = DocumentPath.canonical(folder)
        guard !openedFolders.contains(canonical) else { return }

        openedFolders.append(canonical)
        changed()
    }

    public func close(folder: String) {
        let canonical = DocumentPath.canonical(folder)
        guard let index = openedFolders.firstIndex(of: canonical) else { return }

        openedFolders.remove(at: index)
        changed()
    }

    private func changed() {
        revision += 1
        for observer in Array(observers.values) { observer() }
    }

    @discardableResult
    public func subscribe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    // MARK: Contexts

    /// The context of a file: the innermost opened folder that holds it, else the nearest package
    /// above it, else none.
    public func context(forFile path: String) -> ProjectContext? {
        let file = DocumentPath.canonical(path)
        let holding = openedFolders.filter { file.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        if let root = holding.max(by: { $0.count < $1.count }) {
            return ProjectContext(root: root, buildSystem: Self.buildSystem(ofFolder: root), isExplicit: true, revision: revision)
        }

        guard let package = PackageRootLocator.root(forFile: file) else { return nil }

        return ProjectContext(root: package.path, buildSystem: .swiftPM, isExplicit: false, revision: revision)
    }

    /// What the server at `root` is dealing with: an opened folder is looked into, any other root
    /// was found by its `Package.swift`.
    public func buildSystem(forRoot root: String) -> BuildSystem {
        let canonical = DocumentPath.canonical(root)

        return openedFolders.contains(canonical) ? Self.buildSystem(ofFolder: canonical) : .swiftPM
    }

    /// An opened folder with no project in it and none a few levels below: its files get the
    /// server's own default settings. Anything else is not claimed to be fallback.
    public func isWithoutProject(root: String) -> Bool {
        let canonical = DocumentPath.canonical(root)

        return openedFolders.contains(canonical)
            && Self.buildSystem(ofFolder: canonical) == .none
            && !Self.containsProject(below: canonical)
    }

    /// Whether a project lies a few levels below the folder. SourceKit-LSP rooted at a folder without
    /// a project of its own still finds a package below it (ADR-028), so such a folder is not called
    /// one of fallback settings. The scan is bounded in depth and in entries, and skips hidden folders.
    public nonisolated static func containsProject(
        below folder: String,
        maxDepth: Int = 3,
        limit: Int = 5000,
        fileManager: FileManager = .default
    ) -> Bool {
        var level = [folder]
        var seen = 0
        for _ in 0..<maxDepth {
            var next: [String] = []
            for directory in level {
                for name in (try? fileManager.contentsOfDirectory(atPath: directory)) ?? [] where !name.hasPrefix(".") {
                    seen += 1
                    if seen > limit { return false }

                    let path = (directory as NSString).appendingPathComponent(name)
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

                    if buildSystem(ofFolder: path, fileManager: fileManager) != .none { return true }

                    next.append(path)
                }
            }
            level = next
        }

        return false
    }

    /// By the markers in the folder. When there are several, the order is fixed (SwiftPM, Bazel, Xcode,
    /// compilation database) and not guessed from anything else: a mixed folder is for the user to sort out.
    public nonisolated static func buildSystem(ofFolder folder: String, fileManager: FileManager = .default) -> BuildSystem {
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) }

        if exists("Package.swift") { return .swiftPM }

        if exists("MODULE.bazel") { return .bazel }

        let entries = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        if entries.contains(where: { $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcodeproj") }) { return .xcode }

        if exists("compile_commands.json") { return .compilationDatabase }

        return .none
    }
}

/// The system's temporary folders. A package there gets no flags for its C-family files from the
/// server (ADR-026), and the cause is not known, so the user is told and nothing is moved.
public enum TemporaryFolder {
    private static let prefixes = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]

    public static func contains(_ path: String) -> Bool {
        prefixes.contains { path.hasPrefix($0) }
    }

    /// The words for the window subtitle, or nil when there is nothing to say.
    public static func note(path: String, isCFamily: Bool) -> String? {
        guard isCFamily, contains(path) else { return nil }

        return "temporary folder: C-family flags may be missing"
    }
}
