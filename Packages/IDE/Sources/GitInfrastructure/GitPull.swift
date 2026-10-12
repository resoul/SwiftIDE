import Foundation
import IDEApplication

extension GitCLI: GitPullPlanning {
    public func planPull(in snapshot: GitSnapshot, remote: String, source: String) async throws -> GitPullPlan {
        guard let name = snapshot.branch, let head = snapshot.head,
              let branch = snapshot.branches.first(where: { !$0.isRemote && $0.name == name && $0.oid == head }),
              snapshot.remotes.contains(remote), !remote.hasPrefix("-"), !remote.contains("\0"),
              !source.isEmpty, !source.hasPrefix("-"), source.utf8.count <= 1024, !source.contains("\0") else {
            throw GitInspectionError
                .failed("Pull needs a current committed local branch, one remote and a valid source branch")
        }

        _ = try await run(["check-ref-format", "refs/remotes/" + remote + "/" + source], at: snapshot.repository.root)
        do { _ = try await run(["check-ref-format", "refs/heads/" + source], at: snapshot.repository.root) }
        catch let error as GitInspectionError {
            if case .failed = error { throw GitInspectionError.failed("Enter a valid remote source branch name") }
            throw error
        }
        let urls = try GitPorcelain.string(await run(
            ["remote", "get-url", "--all", remote],
            at: snapshot.repository.root
        )).split(separator: "\n").map(String.init)
        guard urls.count == 1, let rawURL = urls.first else {
            throw GitInspectionError.failed("Pull requires a remote with one fetch address")
        }

        let url = !rawURL.hasPrefix("/") && !rawURL.contains(":")
            ? DocumentPath.canonical(snapshot.repository.root + "/" + rawURL)
            : rawURL
        try GitCloneRequest.validateSource(url)
        guard try await repository(at: snapshot.repository.root) == snapshot.repository else {
            throw GitInspectionError.failed("Repository changed while reviewing Pull")
        }

        return .init(repository: snapshot.repository, branch: branch, remote: remote, source: source, url: url)
    }

    func pull(_ plan: GitPullPlan, expected: GitSnapshot, output: @escaping @Sendable (String) -> Void) async throws {
        guard plan.repository == expected.repository, expected.branch == plan.branch.name,
              expected.head == plan.branch.oid,
              expected.branches.contains(plan.branch) else {
            throw GitInspectionError.failed("Current branch changed since review; review Pull again")
        }

        guard try await planPull(in: expected, remote: plan.remote, source: plan.source) == plan else {
            throw GitInspectionError.failed("Fetch address changed since review; review Pull again")
        }

        try ensurePullAllowed(expected)
        let ref = "refs/remotes/" + plan.remote + "/" + plan.source
        // Fetch one reviewed head through its URL: neither configured mappings nor pushurl apply.
        _ = try await run(
            networkOptions + [
                "fetch",
                "--progress",
                "--refmap=",
                "--no-tags",
                "--no-prune",
                "--no-prune-tags",
                "--no-recurse-submodules",
                "--no-write-fetch-head",
                "--",
                plan.url,
                "+refs/heads/" + plan.source + ":" + ref
            ],
            at: expected.repository.root,
            limit: 1_000_000,
            timeout: 300,
            output: output,
            network: true
        )
        try Task.checkCancellation()
        let target = try GitPorcelain.oid(GitPorcelain.string(await run(
            ["rev-parse", "--verify", ref],
            at: expected.repository.root
        )).trimmingCharacters(in: .newlines))
        let fresh = try await snapshot(at: expected.repository.root)
        guard fresh.repository == expected.repository, fresh.head == expected.head, fresh.branch == expected.branch,
              fresh.changes == expected.changes else {
            throw GitInspectionError.failed("Local checkout changed during Fetch; review Pull again")
        }

        try ensurePullAllowed(fresh)
        if let head = fresh.head {
            let counts = try GitPorcelain.string(await run(
                ["rev-list", "--left-right", "--count", head + "..." + target],
                at: fresh.repository.root
            ))
            .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard counts.count == 2 else { throw GitInspectionError.failed("Cannot determine branch divergence.") }

            if counts[0] > 0, counts[1] > 0 {
                throw GitInspectionError.pullDiverged(.init(
                    repository: fresh.repository,
                    head: head,
                    target: .init(reference: ref, oid: target)
                ))
            }
        }

        try Task.checkCancellation()
        _ = try await run(
            [
                "-c",
                "gc.auto=0",
                "-c",
                "maintenance.auto=false",
                "-c",
                "merge.autostash=false",
                "-c",
                "submodule.recurse=false",
                "merge",
                "--ff-only",
                "--no-autostash",
                "--no-overwrite-ignore",
                "--no-edit",
                "--no-stat",
                "--no-log",
                "--",
                target
            ],
            at: expected.repository.root,
            limit: 1_000_000,
            timeout: 120,
            output: output
        )
    }

    private func ensurePullAllowed(_ snapshot: GitSnapshot) throws {
        guard !snapshot.changes
            .contains(where: {
                !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty || $0.decoration.isConflict
            }) else {
            throw GitInspectionError
                .failed(
                    """
                    Pull needs a clean index and tracked files; commit your changes first. Nothing was stashed or \
                    discarded.
                    """
                )
        }

        let markers = [
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "rebase-merge",
            "rebase-apply",
            "sequencer",
            "BISECT_LOG"
        ]
        guard !markers
            .contains(where: { FileManager.default.fileExists(atPath: snapshot.repository.gitDirectory + "/" + $0) })
        else {
            throw GitInspectionError
                .failed("Finish the existing merge, rebase, cherry-pick, revert or bisect before Pull")
        }
    }
}
