import Foundation
import IDEApplication

extension GitCLI {
    var integrationOptions: [String] {
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
                  expected.branches.contains(plan.target), (plan.kind == .merge || plan.kind == .rebase) else {
                throw GitInspectionError.failed("Branch or Git operation changed; review again")
            }

            guard !expected.changes
                .contains(where: {
                    !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty || $0.decoration.isConflict
                }) else {
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
                guard merges == "0" || plan.preserveMerges else {
                    throw GitInspectionError
                        .failed("This range contains merge commits; review with Preserve merge topology enabled")
                }

                arguments = [
                    "rebase",
                    "--merge",
                    "--no-autosquash",
                    "--no-autostash",
                    plan.preserveMerges ? "--rebase-merges=no-rebase-cousins" : "--no-rebase-merges",
                    "--no-update-refs",
                    "--no-fork-point",
                    "--no-rerere-autoupdate",
                    "--reapply-cherry-picks",
                    "--keep-empty",
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

                arguments = ["commit", "--file=-", "--cleanup=verbatim"]
                input = Data(message.utf8)
            } else if reviewed.kind != .rebase {
                guard expected.changes.contains(where: { !$0.decoration.index.isEmpty && !$0.decoration.isConflict })
                    || reviewed.stoppedCommit == nil else {
                    throw GitInspectionError.failed("No staged replay result. Choose explicit Skip or Abort.")
                }

                try await protectUntracked(
                    expected,
                    target: try requireOID(reviewed.stoppedCommit ?? expected.head),
                    replayOriginal: nil
                )
                arguments = [reviewed.kind.rawValue, "--continue"]
            } else {
                var kept = reviewed.keptEmptyHead == expected.head
                if let parent = reviewed.emptyAttemptParent, parent != expected.head {
                    try await verifyKeptEmpty(expected, parent: parent, stopped: try requireOID(reviewed.stoppedCommit))
                    kept = true
                }

                guard reviewed.stoppedCommit == nil || reviewed.isEditingCommit || kept || expected.changes
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
            try await protectUntracked(
                expected,
                target: try requireOID(reviewed.originalHead ?? expected.head),
                replayOriginal: nil
            )
            arguments = [reviewed.kind.rawValue, "--abort"]
        case .skipRebase(let reviewed):
            try verifyOperation(reviewed, expected: expected)
            guard reviewed.kind.supportsSkip else {
                throw GitInspectionError.failed("This operation does not support Skip")
            }

            try await protectUntracked(
                expected,
                target: try requireOID(reviewed.onto ?? reviewed.stoppedCommit ?? expected.head),
                replayOriginal: reviewed.originalHead
            )
            arguments = [reviewed.kind.rawValue, "--skip"]
        case .keepEmptyRebase(let reviewed):
            try verifyOperation(reviewed, expected: expected)
            guard reviewed.kind == .rebase, !reviewed.isEditingCommit, reviewed.keptEmptyHead != expected.head,
                  reviewed.emptyAttemptParent == nil || reviewed.emptyAttemptParent == expected.head,
                  let stopped = reviewed.stoppedCommit,
                  !expected.changes
                  .contains(where: {
                      !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty || $0.decoration.isConflict
                  }) else {
                throw GitInspectionError
                    .failed("Keep empty requires a clean empty replay, not an edit stop or staged result.")
            }

            try await protectUntracked(
                expected,
                target: try requireOID(reviewed.onto),
                replayOriginal: reviewed.originalHead
            )
            let verification = try await snapshot(at: expected.repository.root)
            guard verification.head == expected.head, verification.branch == expected.branch,
                  verification.mutationToken == expected.mutationToken,
                  verification.integration == expected.integration,
                  let parent = expected.head else { throw GitInspectionError.failed("Replay changed; review again.") }

            let markerURL = URL(fileURLWithPath: expected.repository.gitDirectory + "/swiftide-kept-empty")
            let prefix = (reviewed.originalHead ?? "") + "\n" + stopped + "\n"
            try Data((prefix + parent + "\npending").utf8).write(to: markerURL, options: .atomic)
            _ = try await run(
                integrationOptions + ["commit", "--allow-empty", "--reuse-message=" + (try GitPorcelain.oid(stopped))],
                at: expected.repository.root,
                limit: 1_000_000,
                timeout: 120,
                output: output
            )
            let head = try GitPorcelain.string(await run(
                ["rev-parse", "--verify", "HEAD"],
                at: expected.repository.root
            ))
            .trimmingCharacters(in: .newlines)
            let marker = (reviewed.originalHead ?? "") + "\n" + stopped + "\n" + (try GitPorcelain.oid(head))
            let afterCommit = try await snapshot(at: expected.repository.root)
            try await verifyKeptEmpty(afterCommit, parent: parent, stopped: stopped)
            try Data(marker.utf8).write(to: markerURL, options: .atomic)
            try Task.checkCancellation()
            _ = try await run(
                integrationOptions + ["rebase", "--continue"],
                at: expected.repository.root,
                limit: 1_000_000,
                timeout: 120,
                output: output
            )
            if try integration(at: expected.repository) == nil {
                try? FileManager.default.removeItem(atPath: expected.repository.gitDirectory + "/swiftide-kept-empty")
            }

            return
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
        if try integration(at: expected.repository) == nil {
            try? FileManager.default.removeItem(atPath: expected.repository.gitDirectory + "/swiftide-kept-empty")
        }
    }

    private func requireOID(_ value: String?) throws -> String {
        guard let value else {
            throw GitInspectionError.failed("Git operation has no original/target commit to review")
        }

        return try GitPorcelain.oid(value)
    }

    private func verifyKeptEmpty(_ snapshot: GitSnapshot, parent: String, stopped: String) async throws {
        guard let head = snapshot.head else { throw GitInspectionError.failed("Empty replay has no resulting commit.") }

        let parents = try GitPorcelain.string(await run(
            ["rev-list", "--parents", "-n", "1", head],
            at: snapshot.repository.root
        ))
        .split(whereSeparator: \.isWhitespace).map(String.init)
        let tree = try await run(
            ["show", "--no-show-signature", "-s", "--format=%T", head],
            at: snapshot.repository.root
        )
        let parentTree = try await run(
            ["show", "--no-show-signature", "-s", "--format=%T", parent],
            at: snapshot.repository.root
        )
        let format = "--format=%an%x00%ae%x00%at%x00%B"
        let actual = try await run(["show", "--no-show-signature", "-s", format, head], at: snapshot.repository.root)
        let original = try await run(
            ["show", "--no-show-signature", "-s", format, stopped],
            at: snapshot.repository.root
        )
        guard parents == [head, parent], tree == parentTree, actual == original else {
            throw GitInspectionError
                .failed("Empty-commit attempt changed history/content; inspect the actual commit before recovery.")
        }
    }

    private func verifyOperation(_ reviewed: GitIntegrationStatus, expected: GitSnapshot) throws {
        guard reviewed.kind != .other, expected.integration == reviewed else {
            throw GitInspectionError.failed("Git operation changed; review its current state")
        }
    }

    /// Git rebase/reset can overwrite ignored paths. Protect every path touched by this checkout/replay.
    func protectUntracked(_ snapshot: GitSnapshot, target: String, replayOriginal: String?) async throws {
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
                    [
                        "diff-tree",
                        "--stdin",
                        "--root",
                        "--diff-merges=separate",
                        "--no-commit-id",
                        "--name-only",
                        "--no-renames",
                        "-r",
                        "-z"
                    ],
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
