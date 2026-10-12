import Foundation
import IDEApplication

extension GitCLI: GitInteractiveRebasePlanning {
    public func planInteractiveRebase(
        in snapshot: GitSnapshot,
        target: GitBranch
    ) async throws -> GitInteractiveRebasePlan {
        guard snapshot.integration == nil, let head = snapshot.head, let branch = snapshot.branch,
              snapshot.branches.contains(target), target.reference != "refs/heads/" + branch else {
            throw GitInspectionError.failed("Choose another known branch while no Git operation is active.")
        }

        let range = try GitPorcelain.oid(target.oid) + ".." + GitPorcelain.oid(head)
        let oids = try GitPorcelain.string(await run(
            ["rev-list", "--reverse", "--topo-order", "--max-count=201", range],
            at: snapshot.repository.root
        )).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !oids.isEmpty, oids.count <= 200 else {
            throw GitInspectionError.failed("Choose a nonempty range of at most 200 commits.")
        }

        var commits: [GitCommit] = []
        for oid in oids {
            try Task.checkCancellation()
            let bytes = try await run(
                ["show", "--no-show-signature", "-s", "--format=%H%x00%P%x00%an%x00%at%x00%s", oid],
                at: snapshot.repository.root,
                limit: 128_000
            )
            let fields = try GitPorcelain.string(bytes).trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard fields.count == 5, let time = TimeInterval(fields[3]) else {
                throw GitInspectionError.failed("Commit metadata cannot be reviewed.")
            }

            let parents = fields[1].split(separator: " ").map(String.init)
            guard parents.count <= 1 else {
                throw GitInspectionError
                    .failed("Interactive reorder supports linear commits. Use Preserve merge topology for this range.")
            }

            commits.append(.init(
                oid: try GitPorcelain.oid(fields[0]),
                parents: parents,
                author: fields[2],
                date: Date(timeIntervalSince1970: time),
                subject: fields[4]
            ))
        }
        let current = try await self.snapshot(at: snapshot.repository.root)
        guard current.head == head, current.branch == branch, current.mutationToken == snapshot.mutationToken,
              current.branches.contains(target), current.integration == nil else {
            throw GitInspectionError.failed("History moved during review; refresh and try again.")
        }

        return .init(
            source: .init(
                repository: snapshot.repository,
                kind: .rebase,
                head: head,
                branch: branch,
                target: target
            ),
            commits: commits,
            token: digest(Data(oids.joined(separator: "\n").utf8))
        )
    }

    func interactiveRebase(
        _ plan: GitInteractiveRebasePlan,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        if let reason = plan.validation { throw GitInspectionError.failed(reason) }
        let current = try await planInteractiveRebase(in: expected, target: plan.source.target)
        guard current.source == plan.source, current.commits == plan.commits, current.token == plan.token,
              !expected.changes.contains(where: {
                  !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty || $0.decoration.isConflict
              }) else {
            throw GitInspectionError.failed("Interactive plan changed or tracked files are dirty; review again.")
        }

        try await protectUntracked(expected, target: plan.source.target.oid, replayOriginal: plan.source.head)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftide-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let todo = directory.appendingPathComponent("todo"), editor = directory.appendingPathComponent("editor")
        let text = try plan.steps.map { step in
            step.action.rawValue + " " + (try GitPorcelain.oid(step.commit.oid)) + "\n"
        }.joined()
        try Data(text.utf8).write(to: todo, options: .withoutOverwriting)

        func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

        let helper = "#!/bin/sh\nexec /bin/cp " + shellQuote(todo.path) + " \"$1\"\n"
        try Data(helper.utf8).write(to: editor, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        let final = try await snapshot(at: expected.repository.root)
        guard final.mutationToken == expected.mutationToken, final.head == plan.source.head,
              final.branch == plan.source.branch, final.integration == nil,
              final.branches.contains(plan.source.target) else {
            throw GitInspectionError.failed("Repository changed during preflight; review again.")
        }

        try Task.checkCancellation()
        _ = try await run(
            integrationOptions + [
                "-c",
                "sequence.editor=" + shellQuote(editor.path),
                "-c",
                "rebase.missingCommitsCheck=error",
                "rebase",
                "--interactive",
                "--merge",
                "--no-autosquash",
                "--no-autostash",
                "--no-rebase-merges",
                "--no-update-refs",
                "--no-fork-point",
                "--no-rerere-autoupdate",
                "--reapply-cherry-picks",
                "--keep-empty",
                "--empty=stop",
                plan.source.target.oid
            ],
            at: expected.repository.root,
            limit: 1_000_000,
            timeout: 120,
            output: output
        )
    }
}
