import Foundation

public enum GitIntegrationKind: String, Sendable {
    case merge, rebase, revert, am, other
    case cherryPick = "cherry-pick"
    public var supportsSkip: Bool { self == .rebase || self == .cherryPick || self == .revert || self == .am }
}

public struct GitIntegrationStatus: Equatable, Sendable {
    public let isEditingCommit: Bool
    public let keptEmptyHead: String?
    public let emptyAttemptParent: String?
    public let kind: GitIntegrationKind
    public let token: String
    public let originalHead: String?
    public let onto: String?
    public let stoppedCommit: String?
    public let detail: String

    public init(
        kind: GitIntegrationKind,
        token: String,
        originalHead: String?,
        onto: String? = nil,
        stoppedCommit: String? = nil,
        detail: String,
        isEditingCommit: Bool = false,
        keptEmptyHead: String? = nil,
        emptyAttemptParent: String? = nil
    ) {
        self.kind = kind
        self.isEditingCommit = isEditingCommit
        self.keptEmptyHead = keptEmptyHead
        self.emptyAttemptParent = emptyAttemptParent
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
    public let preserveMerges: Bool

    public init(
        repository: GitRepository,
        kind: GitIntegrationKind,
        head: String,
        branch: String,
        target: GitBranch,
        preserveMerges: Bool = false
    ) {
        self.repository = repository
        self.kind = kind
        self.head = head
        self.branch = branch
        self.target = target
        self.preserveMerges = preserveMerges
    }

    public var title: String { kind.rawValue.capitalized + " " + target.name + " · " + branch }
}

public struct GitConflictSide: Equatable, Sendable {
    public var previewText: String? {
        guard let text else { return nil }

        let value = text as NSString
        var end = min(value.length, 128_000)
        if end > 0, end < value.length, (0xD800...0xDBFF).contains(value.character(at: end - 1)),
           (0xDC00...0xDFFF).contains(value.character(at: end)) { end -= 1 }

        return value.substring(to: end)
    }
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

public enum GitConflictWorkingKind: String, Sendable { case file, symlink, directory, submodule, missing, oversized }

public struct GitConflict: Equatable, Sendable {
    public let workingKind: GitConflictWorkingKind
    public let diff3Reference: String?
    public let repository: GitRepository
    public let path: String
    public let sides: [GitConflictSide]
    public let indexToken: String
    public let workingToken: String
    public let workingText: String?
    public let workingExists: Bool
    public let markerSize: Int
    public let integration: GitIntegrationStatus?
    public var supportsResolution: Bool {
        sides.allSatisfy { ["100644", "100755", "120000", "160000"].contains($0.mode) }
    }

    public init(
        repository: GitRepository,
        path: String,
        sides: [GitConflictSide],
        indexToken: String,
        workingToken: String,
        workingText: String?,
        workingExists: Bool,
        markerSize: Int = 7,
        integration: GitIntegrationStatus? = nil,
        diff3Reference: String? = nil,
        workingKind: GitConflictWorkingKind = .file
    ) {
        self.repository = repository
        self.workingKind = workingKind
        self.diff3Reference = diff3Reference
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

public enum GitConflictResolution: Equatable, Sendable {
    case workingFile, workingFileAllowingLiteralMarkers, delete, restoreStage(Int)
    case indexStage(Int), indexDeleted
}

public protocol GitConflictReading: Sendable {
    func conflict(in snapshot: GitSnapshot, path: String) async throws -> GitConflict
}
