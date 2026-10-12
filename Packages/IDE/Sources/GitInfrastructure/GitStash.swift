import Foundation
import IDEApplication

extension GitCLI: GitStashReading {
    // Stash passes no user pathspecs. Inheriting --literal-pathspecs breaks its internal clean -u/--all.
    public func stashes(in repository: GitRepository) async throws -> GitStashList {
        guard try await self.repository(at: repository.root) == repository else {
            throw GitInspectionError.failed("Repository changed while reading stashes")
        }

        let symbolic = try await run(["symbolic-ref", "--quiet", "refs/stash"], at: repository.root, accepted: [0, 1])
        guard symbolic.isEmpty else {
            throw GitInspectionError
                .failed("Symbolic refs/stash is unsupported; handle this repository with external Git")
        }

        let data = try await run(
            ["stash", "list", "-z", "--no-show-signature", "--max-count=201", "--format=%H%x00%gd%x00%at%x00%gs"],
            at: repository.root,
            limit: 512_000
        )
        let fields = try data.split(separator: 0, omittingEmptySubsequences: false).map {
            try GitPorcelain.string(Data($0))
        }
        guard data.isEmpty || fields.last == "" && (fields.count - 1) % 4 == 0 else {
            throw GitInspectionError.failed("Malformed Git stash list")
        }

        var entries: [GitStashEntry] = []
        if !data.isEmpty {
            for i in stride(from: 0, to: fields.count - 1, by: 4) {
                guard fields[i + 1] == "stash@{\(entries.count)}", let timestamp = TimeInterval(fields[i + 2]),
                      timestamp.isFinite else { throw GitInspectionError.failed("Malformed Git stash entry") }

                entries.append(.init(
                    selector: fields[i + 1],
                    oid: try GitPorcelain.oid(fields[i]),
                    date: Date(timeIntervalSince1970: timestamp),
                    message: fields[i + 3]
                ))
            }
        }

        return .init(entries: Array(entries.prefix(200)), token: digest(data), hasMore: entries.count > 200)
    }

    func stash(_ plan: GitStashPlan, expected: GitSnapshot, output: @escaping @Sendable (String) -> Void) async throws {
        guard expected.repository == plan.repository, expected.head == plan.head, expected.branch == plan.branch,
              expected.integration == nil, !expected.changes.contains(where: { $0.decoration.isConflict }) else {
            throw GitInspectionError.failed("Checkout or Git operation changed; review Stash again")
        }

        let list = try await stashes(in: expected.repository)
        guard list.token == plan.listToken, plan.request.entry.map({ list.entries.contains($0) }) ?? true else {
            throw GitInspectionError.failed("Stash list changed; Refresh and Review again. Nothing was removed.")
        }

        switch plan.request {
        case .create(let message, let inclusion):
            guard message.utf8.count <= 16_000, !message.contains("\0") else {
                throw GitInspectionError.failed("Stash message must be at most 16 KB and contain no NUL")
            }

            guard !expected.changes.contains(where: { $0.submodule != "N..." }) else {
                throw GitInspectionError.failed("Stash cannot save changed submodule worktrees; handle them separately")
            }

            var arguments = ["stash", "push"]
            if inclusion == .untracked { arguments.append("--include-untracked") }
            if inclusion == .ignored { arguments.append("--all") }
            if !message.isEmpty { arguments += ["--message", message] }
            try await verifyStashCheckout(expected)
            _ = try await run(
                stashOptions + arguments,
                at: expected.repository.root,
                limit: 1_000_000,
                timeout: 120,
                output: output,
                literalPaths: false
            )
            let result = try await stashes(in: expected.repository)
            guard result.token != list.token else {
                throw GitInspectionError.failed("No stash was created: there were no eligible saved changes")
            }

            output("\nStash created; inspect Changes for anything Git left on disk.\n")
        case .apply(let entry, let restoreIndex), .pop(let entry, let restoreIndex):
            guard !expected.changes.contains(where: {
                !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty
            }) else {
                throw GitInspectionError
                    .failed("Apply/Pop requires a clean index and tracked files; commit or stash them first")
            }

            try await protectStashPaths(entry, snapshot: expected)
            try await verifyStashCheckout(expected)
            var arguments = ["stash", "apply"]
            if restoreIndex { arguments.append("--index") }
            arguments.append(try GitPorcelain.oid(entry.oid))
            output("Applying " + entry.selector + " @ " + entry.oid + "; the stash is retained until success.\n")
            do {
                _ = try await run(
                    stashOptions + arguments,
                    at: expected.repository.root,
                    limit: 1_000_000,
                    timeout: 120,
                    output: output,
                    literalPaths: false
                )
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw GitInspectionError.failed(
                    "Stash was not removed. Application may be partial; resolve conflicts in Changes.\n"
                        + error.localizedDescription
                )
            }
            try Task.checkCancellation()
            if case .pop = plan.request {
                output("\nApplication succeeded. Rechecking the stash list before removal…\n")
                do {
                    let result = try await snapshot(at: expected.repository.root)
                    guard result.repository == expected.repository, result.head == expected.head,
                          result.branch == expected.branch, result.integration == nil,
                          !result.changes.contains(where: { $0.decoration.isConflict }) else {
                        throw GitInspectionError.failed("Checkout changed after application; stash was retained")
                    }

                    try await dropStash(entry, list: list, repository: expected.repository, output: output)
                }
                catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw GitInspectionError.failed(
                        "Stash applied; removal failed or could not be confirmed. Refresh the list. "
                            + "Files were not rolled back.\n"
                            + error.localizedDescription
                    )
                }
            } else { output("\nStash applied and retained.\n") }
        case .drop(let entry):
            try await dropStash(entry, list: list, repository: expected.repository, output: output)
        }
    }

    private var stashOptions: [String] {
        [
            "-c",
            "gc.auto=0",
            "-c",
            "maintenance.auto=false",
            "-c",
            "submodule.recurse=false",
            "-c",
            "rerere.autoupdate=false",
            "-c",
            "stash.index=false"
        ]
    }

    private func verifyStashCheckout(_ expected: GitSnapshot) async throws {
        let fresh = try await snapshot(at: expected.repository.root)
        guard fresh.repository == expected.repository, fresh.mutationToken == expected.mutationToken,
              fresh.integration == expected.integration else {
            throw GitInspectionError.failed("Checkout changed during stash preflight; review again")
        }

        try Task.checkCancellation()
    }

    private func dropStash(
        _ entry: GitStashEntry,
        list: GitStashList,
        repository: GitRepository,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        let fresh = try await stashes(in: repository)
        guard fresh == list, fresh.entries.contains(entry) else {
            throw GitInspectionError.failed("Stash list changed; the reviewed entry was not removed")
        }

        try Task.checkCancellation()
        _ = try await run(
            stashOptions + ["stash", "drop", entry.selector],
            at: repository.root,
            limit: 1_000_000,
            timeout: 120,
            output: output,
            literalPaths: false
        )
    }

    /// Native apply protects tracked edits; also refuse untracked/ignored prefix collisions.
    private func protectStashPaths(_ entry: GitStashEntry, snapshot: GitSnapshot) async throws {
        let oid = try GitPorcelain.oid(entry.oid)
        let parents = try GitPorcelain.string(await run(
            ["rev-list", "--parents", "-n", "1", oid, "--"],
            at: snapshot.repository.root
        )).split(separator: " ")
        guard parents.count == 3 || parents.count == 4 else {
            throw GitInspectionError.failed("Selected object is not a supported stash commit")
        }

        let base = try GitPorcelain.oid(String(parents[1]))
        let index = try GitPorcelain.oid(String(parents[2]).trimmingCharacters(in: .newlines))
        var data = try await run(
            ["diff", "--name-only", "--no-renames", "-z", base, oid, "--"],
            at: snapshot.repository.root
        )
        data.append(try await run(
            ["diff", "--name-only", "--no-renames", "-z", base, index, "--"],
            at: snapshot.repository.root
        ))
        if parents.count == 4 {
            let extra = try GitPorcelain.oid(String(parents[3]).trimmingCharacters(in: .newlines))
            data.append(try await run(
                ["ls-tree", "--name-only", "-r", "-z", extra, "--"],
                at: snapshot.repository.root
            ))
        }

        let paths = try data.split(separator: 0).map {
            try GitPorcelain.path(GitPorcelain.string(Data($0))).lowercased()
        }
        for change in snapshot.changes where change.decoration.isUntracked || change.decoration.ignoredReason != nil {
            let path = change.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            guard !paths.contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }) else {
                throw GitInspectionError.failed("Stash may overwrite untracked/ignored path: " + change.path
                    + ". Move it outside the worktree before retrying.")
            }
        }
    }
}
