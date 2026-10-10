import Foundation

public enum BuildSystem: String, Sendable, Equatable {
    case swiftPM, xcode, bazel, compilationDatabase
    /// A folder with none of the markers: files in it are served one by one.
    case none
}

/// The project a document belongs to: where its root is, what builds it, and the revision of the
/// set of opened folders it was made at, so that a consumer can tell that the context it holds is
/// not the current one. It also holds the target of the file, the toolchain and the build
/// configuration, which a change of makes an earlier answer stale (ADR-034).
public struct ProjectContext: Equatable, Sendable {
    public let root: String
    public let buildSystem: BuildSystem
    /// Chosen by the user with File ▸ Open Folder, as opposed to found by walking up from a file.
    public let isExplicit: Bool
    public let revision: Int
    /// The names of the targets that hold the file: none while the package's layout is unknown (or
    /// when no target does), one normally, more than one when the file is ambiguous.
    public let targetNames: [String]
    /// Whether the package lists the file or the target is a guess from the file's place; nil with no target.
    public let targetBasis: MembershipBasis?
    /// The tools and the build configuration the project's server is run with; unknown until a
    /// server for the project has started.
    public let environment: ProjectEnvironment

    /// The file's target when it is settled.
    public var target: String? { targetNames.count == 1 ? targetNames[0] : nil }
}

/// The folders the user opened, and the context of a file given them. An opened folder takes priority
/// over the nearest `Package.swift`: a nested package does not silently change the workspace.
@MainActor
public final class ProjectContexts {
    public private(set) var openedFolders: [String] = []
    /// Grows each time the set of opened folders changes.
    public private(set) var revision = 0
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var layouts: [String: PackageLayout] = [:]
    private var environments: [String: ProjectEnvironment] = [:]

    public init() {}

    // MARK: Package layouts

    public func layout(forRoot root: String) -> PackageLayout? { layouts[DocumentPath.canonical(root)] }

    /// Keeps what `swift package describe` said about the package at `root` (nil forgets it). A change
    /// is a new revision of the context: what a file's target is may have changed with it.
    public func setLayout(_ layout: PackageLayout?, forRoot root: String) {
        let canonical = DocumentPath.canonical(root)
        guard layouts[canonical] != layout else { return }

        layouts[canonical] = layout
        changed()
    }

    // MARK: Environment

    public func environment(forRoot root: String) -> ProjectEnvironment? { environments[DocumentPath.canonical(root)] }

    /// Keeps the tools and the build configuration the project at `root` is served with. A change
    /// is a new revision, and drops the package's layout: what it says of the targets was made by
    /// the earlier tools and under the earlier configuration, and is asked for again.
    public func setEnvironment(_ environment: ProjectEnvironment, forRoot root: String) {
        let canonical = DocumentPath.canonical(root)
        guard environments[canonical] != environment else { return }

        environments[canonical] = environment
        layouts[canonical] = nil
        changed()
    }

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
            return makeContext(root: root, buildSystem: Self.buildSystem(ofFolder: root), isExplicit: true, file: file)
        }

        guard let package = PackageRootLocator.root(forFile: file) else { return nil }

        return makeContext(root: package.path, buildSystem: .swiftPM, isExplicit: false, file: file)
    }

    private func makeContext(root: String, buildSystem: BuildSystem, isExplicit: Bool, file: String) -> ProjectContext {
        let membership = layouts[root]?.membership(of: file) ?? .none

        return ProjectContext(
            root: root,
            buildSystem: buildSystem,
            isExplicit: isExplicit,
            revision: revision,
            targetNames: membership.names,
            targetBasis: membership.basis,
            environment: environments[root] ?? ProjectEnvironment()
        )
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
}
