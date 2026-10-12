import Foundation
import IDEApplication

/// Reentrant actor admits different repositories, but never two writes to shared Git metadata.
actor GitMutationGate {
    static let shared = GitMutationGate()
    private var active: Set<String> = []

    func run(key: String, operation: @Sendable () async throws -> Void) async throws {
        guard active.insert(key).inserted else {
            throw GitInspectionError.failed("Another Git action is running for this repository")
        }

        defer { active.remove(key) }
        try Task.checkCancellation()
        try await operation()
    }
}

extension GitCLI: GitMutating {
    public func perform(
        _ action: GitLocalAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        try await GitMutationGate.shared.run(key: expected.repository.commonDirectory) {
            let current = try await snapshot(at: expected.repository.root)
            guard current.repository == expected.repository,
                  let token = expected.mutationToken, current.mutationToken == token else {
                throw GitInspectionError.failed("Repository changed since review; refresh and retry the action")
            }

            try Task.checkCancellation()
            var arguments: [String]
            var input: Data?
            switch action {
            case .repositoryOperation(let plan):
                try await repositoryOperation(plan, expected: current, output: output)

                return
            case .resolveConflictGroup(let group, let stage):
                try await resolveGroup(group, stage: stage, expected: current, output: output)

                return
            case .interactiveRebase(let plan):
                try await interactiveRebase(plan, expected: current, output: output)

                return
            case .manage(let plan):
                try await manage(plan, expected: current, output: output)

                return
            case .partial(let selection):
                try await partial(selection, expected: current, output: output)

                return
            case .stash(let plan):
                try await stash(plan, expected: current, output: output)

                return
            case .tracking(let plan):
                try await tracking(plan, expected: current, output: output)

                return
            case .integrate, .continueIntegration, .abortIntegration, .skipRebase, .keepEmptyRebase:
                try await integrate(action, expected: current, output: output)

                return
            case .resolveConflict(let conflict, let resolution):
                try await resolve(conflict, as: resolution, expected: current, output: output)

                return
            case .pull(let plan):
                try await pull(plan, expected: current, output: output)

                return
            case .push(let plan):
                try await push(plan, expected: current, output: output)

                return
            case .fetch(let remote):
                try await fetch(remote: remote, expected: current, output: output)

                return
            case .stage(let change), .unstage(let change):
                guard expected.changes.contains(change), !change.decoration.isConflict,
                      change.decoration.ignoredReason == nil else {
                    throw GitInspectionError.failed("Select a current changed file")
                }

                var paths = [try GitPorcelain.path(change.path)]
                if let previous = change.previousPath { paths.append(try GitPorcelain.path(previous)) }
                if case .stage = action {
                    arguments = ["add", "--all", "--"] + paths
                } else {
                    guard !change.decoration.index.isEmpty || change.decoration.isConflict else {
                        throw GitInspectionError.failed("This file has no staged changes")
                    }

                    if let head = current.head {
                        arguments = ["restore", "--source=" + (try GitPorcelain.oid(head)), "--staged", "--"] + paths
                    } else {
                        // No HEAD to restore from; remove index entries only, keeping every disk byte.
                        arguments = ["rm", "--cached", "--force", "--ignore-unmatch", "--"] + paths
                    }
                }
            case .commit(let message):
                guard current.integration == nil else {
                    throw GitInspectionError.failed("Use Continue for the current Git operation")
                }

                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 64_000,
                      !message.contains("\0") else {
                    throw GitInspectionError.failed("Enter a nonempty commit message (up to 64 KB)")
                }

                guard current.changes.contains(where: { !$0.decoration.index.isEmpty }),
                      !current.changes.contains(where: { $0.decoration.isConflict }) else {
                    throw GitInspectionError.failed("Commit needs staged changes and no unresolved conflicts")
                }

                arguments = ["commit", "--file=-", "--cleanup=verbatim"]
                input = Data(message.utf8)
            case .createBranch(let name):
                try await validateBranch(name, root: current.repository.root)
                guard let head = current.head else {
                    throw GitInspectionError.failed("Create the first commit before creating another branch")
                }

                arguments = ["branch", "--no-track", name, try GitPorcelain.oid(head)]
            case .switchBranch(let branch):
                guard current.integration == nil else {
                    throw GitInspectionError.failed("Finish or abort the current Git operation before switching")
                }

                guard !branch.isRemote, branch.reference.hasPrefix("refs/heads/"),
                      current.branches.contains(branch) else {
                    throw GitInspectionError
                        .failed("Select a current local branch; remote refs are available for inspection")
                }

                try await validateBranch(branch.name, root: current.repository.root)
                // Never force, merge, stash, guess a remote branch or recurse into submodules.
                arguments = ["switch", "--no-guess", "--no-recurse-submodules", "--", branch.name]
            }
            _ = try await run(
                ["-c", "gc.auto=0", "-c", "maintenance.auto=false"] + arguments,
                at: current.repository.root,
                input: input,
                limit: 1_000_000,
                timeout: 120,
                output: output
            )
        }
    }

    func validateBranch(_ name: String, root: String) async throws {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.hasPrefix("-"), !name.contains("\0") else {
            throw GitInspectionError.failed("Enter a valid branch name")
        }

        do { _ = try await run(["check-ref-format", "refs/heads/" + name], at: root) }
        catch let error as GitInspectionError {
            if case .failed = error { throw GitInspectionError.failed("Invalid branch name") }
            throw error
        }
    }
}
