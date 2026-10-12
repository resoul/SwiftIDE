import Foundation

public enum GitAction: Equatable, Sendable {
    case integrate(GitIntegrationPlan)
    case continueIntegration(GitIntegrationStatus, String)
    case abortIntegration(GitIntegrationStatus), skipRebase(GitIntegrationStatus)
    case resolveConflict(GitConflict, GitConflictResolution)
    case fetch(String)
    case push(GitPushPlan)
    case pull(GitPullPlan)
    case stage(GitChange), unstage(GitChange)
    case commit(String), createBranch(String), switchBranch(GitBranch)

    public var title: String {
        switch self {
        case .integrate(let plan): plan.title
        case .continueIntegration(let status, _): "Continue " + status.kind.rawValue
        case .abortIntegration(let status): "Abort " + status.kind.rawValue
        case .skipRebase: "Skip current rebase commit"
        case .resolveConflict(_, let resolution): resolution == .workingFile ? "Mark saved result resolved" : resolution == .delete ? "Resolve as deleted" : "Restore conflict side on disk"
        case .pull(let plan): plan.title
        case .push(let plan): plan.title
        case .fetch(let remote): "Fetch " + remote
        case .stage: "Stage whole file"
        case .unstage: "Unstage whole file"
        case .commit: "Commit staged changes"
        case .createBranch: "Create branch at HEAD"
        case .switchBranch(let branch): "Switch to " + branch.name
        }
    }
    public var changesCheckout: Bool {
        switch self { case .switchBranch, .pull, .integrate, .continueIntegration, .abortIntegration, .skipRebase, .resolveConflict: true; default: false }
    }
}

/// Compatibility name for the original local action API.
public typealias GitLocalAction = GitAction

public enum GitOperationState: Equatable, Sendable {
    case idle, preparing, running, cancelling, succeeded, cancelled
    case failed(String)
    public var isBusy: Bool { self == .preparing || self == .running || self == .cancelling }
    public var explanation: String {
        switch self {
        case .idle: ""
        case .preparing: "Checking open documents…"
        case .running: "Git is running…"
        case .cancelling: "Stopping Git…"
        case .succeeded: "Completed"
        case .cancelled: "Cancelled; changes already made are not rolled back."
        case .failed(let reason): reason
        }
    }
}

public protocol GitMutating: Sendable {
    func perform(_ action: GitLocalAction, expected: GitSnapshot, output: @escaping @Sendable (String) -> Void) async throws
}

/// Save or cancel only: checkout never implicitly discards an editor buffer.
@MainActor
public final class GitCheckoutDocuments {
    public enum Decision { case save, cancel }
    private let documents: () -> [DocumentSession]
    private let prompt: (DocumentSession) async -> Decision
    private let save: (DocumentSession) async -> Bool

    public init(documents: @escaping () -> [DocumentSession], prompt: @escaping (DocumentSession) async -> Decision, save: @escaping (DocumentSession) async -> Bool) {
        self.documents = documents; self.prompt = prompt; self.save = save
    }

    public static func contains(_ document: DocumentSession, root: String) -> Bool {
        !document.isUntitled && (document.path == root || document.path.hasPrefix(root + "/"))
    }
    public func prepare(root: String) async -> Bool {
        let affected = documents().filter { Self.contains($0, root: root) }
        for document in affected {
            guard !Task.isCancelled, !document.isComposing else { return false }

            if document.isDirty {
                guard await prompt(document) == .save, !Task.isCancelled,
                      await save(document), !document.isDirty else { return false }
            }
        }

        return !Task.isCancelled && documents().filter { Self.contains($0, root: root) }.allSatisfy { !$0.isDirty && !$0.isComposing }
    }
}
