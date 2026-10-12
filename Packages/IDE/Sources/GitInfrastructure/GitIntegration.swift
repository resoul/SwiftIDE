import Foundation
import IDEApplication

extension GitCLI {
    private var integrationOptions: [String] {
        [
            "-c",
            "gc.auto=0",
            "-c",
            "maintenance.auto=false",
            "-c",
            "core.editor=/usr/bin/true",
            "-c",
            "sequence.editor=/usr/bin/false",
            "-c",
            "merge.autostash=false",
            "-c",
            "rebase.autostash=false",
            "-c",
            "rerere.autoupdate=false",
            "-c",
            "submodule.recurse=false"
        ]
    }

    func integrate(
        _ action: GitAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        var arguments: [String], input: Data?
        switch action {
        case .integrate(let plan):
            guard expected.repository == plan.repository, expected.integration == nil, expected.head == plan.head,
                  expected.branch == plan.branch,
                  expected.branches.contains(plan.target), plan.kind != .other else {
                      throw GitInspectionError.failed("Branch or Git operation changed; review again")
                  }

            guard !expected.changes
                .contains(where: {
                !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty || $0.decoration.isConflict }) else {
                throw GitInspectionError
                    .failed(
                        "Merge/Rebase requires clean tracked files and index; commit changes first. No stash was made."
                    )
            }

            let target = try GitPorcelain.oid(plan.target.oid)
            try await protectUntracked(expected, target: target, replayOriginal: plan.kind == .rebase ? plan.head : nil)
            if plan.kind == .merge {
                arguments = [
                    "merge",
                    "--no-ff",
                    "--no-commit",
                    "--no-edit",
                    "--no-autostash",
                    "--no-overwrite-ignore",
                    "--no-rerere-autoupdate",
                    "--",
                    target
                ]
            } else {
                let merges = try GitPorcelain.string(await run(
                    ["rev-list", "--count", "--min-parents=2", target + ".." + (try GitPorcelain.oid(plan.head))],
                    at: expected.repository.root
                )).trimmingCharacters(in: .newlines)
                guard merges == "0" else {
                    throw GitInspectionError
                        .failed("This range contains merge commits; topology-preserving rebase is not supported yet")
                }

                arguments = [
                    "rebase",
                    "--merge",
                    "--no-autosquash",
                    "--no-autostash",
                    "--no-rebase-merges",
                    "--no-update-refs",
                    "--no-fork-point",
                    "--no-rerere-autoupdate",
                    "--reapply-cherry-picks",
                    "--empty=stop",
                    target
                ]
            }
        case .continueIntegration(let reviewed, let message):
            try verifyOperation(reviewed, expected: expected)
            guard !expected.changes.contains(where: { $0.decoration.isConflict }) else {
                throw GitInspectionError.failed("Resolve all unmerged files before Continue")
            }

            if reviewed.kind == .merge {
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 64_000,
                      !message.contains("\0") else {
                    throw GitInspectionError.failed("Enter a merge commit message (up to 64 KB)")
                }

                arguments = ["commit", "--file=-", "--cleanup=verbatim"]; input = Data(message.utf8)
            } else {
                guard reviewed.stoppedCommit == nil || expected.changes
                    .contains(where: { !$0.decoration.index.isEmpty && !$0.decoration.isConflict }) else {
                    throw GitInspectionError
                        .failed(
                            """
                            The stopped replay has no staged result. Use explicit Skip or Abort; Continue will not \
                            silently drop it.
                            """
                        )
                }

                try await protectUntracked(
                    expected,
                    target: try requireOID(reviewed.onto),
                    replayOriginal: reviewed.originalHead
                )
                arguments = ["rebase", "--continue"]
            }
        case .abortIntegration(let reviewed):
            try verifyOperation(reviewed, expected: expected)
            try await protectUntracked(expected, target: try requireOID(reviewed.originalHead), replayOriginal: nil)
            arguments = [reviewed.kind.rawValue, "--abort"]
        case .skipRebase(let reviewed):
            try verifyOperation(reviewed, expected: expected)
            guard reviewed.kind == .rebase else {
                throw GitInspectionError.failed("Only a stopped rebase commit can be skipped")
            }

            try await protectUntracked(
                expected,
                target: try requireOID(reviewed.onto),
                replayOriginal: reviewed.originalHead
            )
            arguments = ["rebase", "--skip"]
        default: throw GitInspectionError.failed("Unsupported integration action")
        }
        let verification = try await snapshot(at: expected.repository.root)
        guard verification.repository == expected.repository, verification.head == expected.head,
              verification.branch == expected.branch,
              verification.mutationToken == expected.mutationToken,
              verification.integration == expected.integration else {
            throw GitInspectionError.failed("Repository changed during integration preflight; review again")
        }

        if case .integrate(let plan) = action, !verification.branches.contains(plan.target) {
            throw GitInspectionError.failed("Target branch moved during preflight; review again")
        }

        try Task.checkCancellation()
        _ = try await run(
            integrationOptions + arguments,
            at: expected.repository.root,
            input: input,
            limit: 1_000_000,
            timeout: 120,
            output: output
        )
    }

    private func requireOID(_ value: String?) throws -> String {
        guard let value else {
            throw GitInspectionError.failed("Git operation has no original/target commit to review")
        }

        return try GitPorcelain.oid(value)
    }

    private func verifyOperation(_ reviewed: GitIntegrationStatus, expected: GitSnapshot) throws {
        guard reviewed.kind != .other, expected.integration == reviewed else {
            throw GitInspectionError.failed("Git operation changed; review its current state")
        }
    }

    /// Git rebase/reset can overwrite ignored paths. Protect every path touched by this checkout/replay.
    private func protectUntracked(_ snapshot: GitSnapshot, target: String, replayOriginal: String?) async throws {
        let untracked = snapshot.changes.filter { $0.decoration.isUntracked || $0.decoration.ignoredReason != nil }
        guard !untracked.isEmpty, let head = snapshot.head else { return }

        var touched = try await run(
            ["diff", "--name-only", "--no-renames", "-z", try GitPorcelain.oid(head), target, "--"],
            at: snapshot.repository.root
        )
        if let replayOriginal {
            let commits = try await run(
                ["rev-list", target + ".." + (try GitPorcelain.oid(replayOriginal))],
                at: snapshot.repository.root,
                limit: 128_000
            )
            if !commits.isEmpty {
                touched.append(try await run(
                    ["diff-tree", "--stdin", "--root", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z"],
                    at: snapshot.repository.root,
                    input: commits
                ))
            }
        }

        let paths = try touched.split(separator: 0).map {
            try GitPorcelain.path(GitPorcelain.string(Data($0))).lowercased()
        }
            + snapshot.changes.filter { !$0.decoration.isUntracked && $0.decoration.ignoredReason == nil }.map {
                $0.path.lowercased()
            }
        for change in untracked {
            let path = change.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            guard !paths.contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }) else {
                throw GitInspectionError
                    .failed("Untracked/ignored path may be overwritten: " + change
                    .path + ". Move it outside the worktree before retrying.")
            }
        }
    }
}
