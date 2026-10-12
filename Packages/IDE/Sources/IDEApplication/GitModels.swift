import Foundation

public struct GitRepository: Equatable, Sendable {
    public let root: String
    public let gitDirectory: String
    public let commonDirectory: String

    public init(root: String, gitDirectory: String, commonDirectory: String) {
        self.root = root
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
    }

    public func absolutePath(_ relative: String) -> String { root + "/" + relative }
}

public struct GitChange: Equatable, Sendable {
    public let path: String
    public let previousPath: String?
    public let decoration: FileDecoration
    public let submodule: String

    public init(path: String, previousPath: String? = nil, decoration: FileDecoration, submodule: String = "N...") {
        self.path = path
        self.previousPath = previousPath
        self.decoration = decoration
        self.submodule = submodule
    }
}

public struct GitBranch: Equatable, Sendable {
    public let reference: String
    public let oid: String
    public let upstream: String
    public var isRemote: Bool { reference.hasPrefix("refs/remotes/") }
    public var name: String { String(reference.dropFirst(isRemote ? 13 : 11)) }

    public init(reference: String, oid: String, upstream: String = "") {
        self.reference = reference
        self.oid = oid
        self.upstream = upstream
    }
}

public struct GitSnapshot: Equatable, Sendable {
    public let repository: GitRepository
    public let branch: String?
    public let head: String?
    public let upstream: String?
    public let ahead: Int?
    public let behind: Int?
    public let changes: [GitChange]
    public let branches: [GitBranch]
    public let remotes: [String]
    public let mutationToken: String?
    public let integration: GitIntegrationStatus?
    public let capturedAt: Date
    public var headDescription: String {
        if let branch { return head == nil ? branch + " (unborn)" : branch }

        return "Detached · " + (head.map { String($0.prefix(8)) } ?? "unknown")
    }

    public init(
        repository: GitRepository,
        branch: String?,
        head: String?,
        upstream: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        changes: [GitChange],
        branches: [GitBranch] = [],
        mutationToken: String? = nil,
        remotes: [String] = [],
        integration: GitIntegrationStatus? = nil,
        capturedAt: Date = .now
    ) {
        self.repository = repository
        self.branch = branch
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.branches = branches
        self.mutationToken = mutationToken
        self.remotes = remotes
        self.capturedAt = capturedAt
        self.integration = integration
    }

    /// Fold changed descendants without reading directories. Ignored ancestors never colour their parent.
    public var decorations: [String: FileDecoration] {
        decorations(exclusionReason: { _ in nil })
    }

    public func decorations(exclusionReason: (String) -> String?) -> [String: FileDecoration] {
        var direct: [String: FileDecoration] = [:]
        var descendants: [String: [FileDecoration]] = [:]
        for change in changes {
            let path = repository.absolutePath(change.path)
            var decoration = change.decoration
            decoration.exclusionReason = exclusionReason(path)
            direct[path] = decoration
            var parent = (path as NSString).deletingLastPathComponent
            while parent == repository.root || parent.hasPrefix(repository.root + "/") {
                descendants[parent, default: []].append(decoration)
                if parent == repository.root { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for change in changes {
            guard let previous = change.previousPath else { continue }

            let path = repository.absolutePath(previous)
            let renamed = FileDecoration(index: "R")
            if direct[path] == nil { direct[path] = renamed }
            var parent = (path as NSString).deletingLastPathComponent
            while parent == repository.root || parent.hasPrefix(repository.root + "/") {
                descendants[parent, default: []].append(renamed)
                if parent == repository.root { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for (path, values) in descendants {
            let aggregate = FileDecoration.aggregate(values)
            if var current = direct[path] {
                current.isConflict = current.isConflict || aggregate.isConflict
                current.isMixed = current.isMixed || aggregate.isMixed
                current.isUntracked = current.isUntracked || aggregate.isUntracked
                if current.index.isEmpty { current.index = aggregate.index }
                if current.worktree.isEmpty { current.worktree = aggregate.worktree }
                direct[path] = current
            } else { direct[path] = aggregate }
        }

        return direct
    }
}

public struct GitCommit: Equatable, Sendable {
    public let oid: String
    public let parents: [String]
    public let author: String
    public let date: Date
    public let subject: String

    public init(oid: String, parents: [String], author: String, date: Date, subject: String) {
        self.oid = oid
        self.parents = parents
        self.author = author
        self.date = date
        self.subject = subject
    }
}

public struct GitHistoryPage: Sendable {
    public let commits: [GitCommit]
    public let hasMore: Bool

    public init(commits: [GitCommit], hasMore: Bool) { self.commits = commits; self.hasMore = hasMore }
}

public struct GitCommitFile: Equatable, Sendable {
    public let path: String
    public let previousPath: String?
    public let status: String

    public init(path: String, previousPath: String? = nil, status: String) {
        self.path = path; self.previousPath = previousPath; self.status = status
    }
}

public enum GitComparison: Equatable, Sendable {
    case index(GitChange), worktree(GitChange), untracked(GitChange)
    case commit(GitCommit, GitCommitFile)
    public var path: String {
        switch self {
        case .index(let c), .worktree(let c), .untracked(let c): c.path
        case .commit(_, let f): f.path
        }
    }
    public var title: String {
        switch self {
        case .index: "Index ↔ HEAD · " + path
        case .worktree(let change):
            (change.decoration.isConflict ? "Unmerged working tree · " : "Disk ↔ index · ") + path
        case .untracked: "Untracked on disk · " + path
        case .commit(let c, _): String(c.oid.prefix(8)) + " ↔ first parent · " + path
        }
    }
}

public protocol GitInspecting: Sendable {
    func snapshot(at projectRoot: String) async throws -> GitSnapshot
    func history(in repository: GitRepository, revision: String, offset: Int, count: Int) async throws -> GitHistoryPage
    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile]
    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String
}

public enum GitInspectionError: Error, Equatable, Sendable, LocalizedError {
    case unavailable(String), failed(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let reason), .failed(let reason): reason }
    }
}
