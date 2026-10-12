import Foundation

public enum GitIntegrationKind: String, Sendable { case merge, rebase, other }

public struct GitIntegrationStatus: Equatable, Sendable {
    public let kind: GitIntegrationKind
    public let token: String
    public let originalHead: String?
    public let onto: String?
    public let stoppedCommit: String?
    public let detail: String

    public init(kind: GitIntegrationKind, token: String, originalHead: String?, onto: String? = nil, stoppedCommit: String? = nil, detail: String) {
        self.kind = kind
        self.token = token
        self.originalHead = originalHead
        self.onto = onto
        self.stoppedCommit = stoppedCommit
        self.detail = detail
    }
}

public struct GitIntegrationPlan: Equatable, Sendable {
    public let repository: GitRepository
    public let kind: GitIntegrationKind
    public let head: String
    public let branch: String
    public let target: GitBranch

    public init(repository: GitRepository, kind: GitIntegrationKind, head: String, branch: String, target: GitBranch) {
        self.repository = repository
        self.kind = kind
        self.head = head
        self.branch = branch
        self.target = target
    }

    public var title: String { kind.rawValue.capitalized + " " + target.name + " · " + branch }
}

public struct GitConflictSide: Equatable, Sendable {
    public let stage: Int
    public let mode: String
    public let oid: String
    public let text: String?
    public let bytes: Int

    public init(stage: Int, mode: String, oid: String, text: String?, bytes: Int) {
        self.stage = stage
        self.mode = mode
        self.oid = oid
        self.text = text
        self.bytes = bytes
    }
}

public struct GitConflict: Equatable, Sendable {
    public let repository: GitRepository
    public let path: String
    public let sides: [GitConflictSide]
    public let indexToken: String
    public let workingToken: String
    public let workingText: String?
    public let workingExists: Bool
    public let markerSize: Int
    public let integration: GitIntegrationStatus?
    public var supportsResolution: Bool { sides.allSatisfy { $0.mode == "100644" || $0.mode == "100755" } }

    public init(
        repository: GitRepository,
        path: String,
        sides: [GitConflictSide],
        indexToken: String,
        workingToken: String,
        workingText: String?,
        workingExists: Bool,
        markerSize: Int = 7,
        integration: GitIntegrationStatus? = nil
    ) {
        self.repository = repository
        self.path = path
        self.sides = sides
        self.indexToken = indexToken
        self.workingToken = workingToken
        self.workingText = workingText
        self.workingExists = workingExists
        self.markerSize = markerSize
        self.integration = integration
    }
}

public enum GitConflictResolution: Equatable, Sendable { case workingFile, delete, restoreStage(Int) }

public protocol GitConflictReading: Sendable {
    func conflict(in snapshot: GitSnapshot, path: String) async throws -> GitConflict
}
