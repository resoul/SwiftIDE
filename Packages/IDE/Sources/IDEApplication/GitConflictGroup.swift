import Foundation

public struct GitConflictIndexSide: Equatable, Sendable {
    public let path: String
    public let stage: Int
    public let mode: String
    public let oid: String

    public init(path: String, stage: Int, mode: String, oid: String) {
        self.path = path
        self.stage = stage
        self.mode = mode
        self.oid = oid
    }
}

public struct GitConflictGroup: Equatable, Sendable {
    public let repository: GitRepository
    public let paths: [String]
    public let sides: [GitConflictIndexSide]
    public let token: String
    public let integration: GitIntegrationStatus

    public init(
        repository: GitRepository,
        paths: [String],
        sides: [GitConflictIndexSide],
        token: String,
        integration: GitIntegrationStatus
    ) {
        self.repository = repository
        self.paths = paths
        self.sides = sides
        self.token = token
        self.integration = integration
    }

    public func summary(stage: Int) -> String {
        paths.map { path in
            let side = sides.first { $0.path == path && $0.stage == stage }

            return path + " → " + (side.map { $0.mode + " " + $0.oid } ?? "deleted from index")
        }.joined(separator: "\n")
    }
}

public protocol GitConflictGrouping: Sendable {
    func conflictGroup(in snapshot: GitSnapshot, path: String) async throws -> GitConflictGroup?
}
