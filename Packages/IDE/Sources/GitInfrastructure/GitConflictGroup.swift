import Foundation
import IDEApplication

extension GitCLI: GitConflictGrouping {
    public func conflictGroup(in snapshot: GitSnapshot, path: String) async throws -> GitConflictGroup? {
        guard let operation = snapshot.integration, let ours = snapshot.head,
              snapshot.changes.contains(where: { $0.path == path && $0.decoration.isConflict }) else { return nil }

        let base: String, theirs: String
        if operation.kind == .merge {
            let heads = try GitPorcelain.string(await run(
                ["rev-parse", "--verify", "MERGE_HEAD"],
                at: snapshot.repository.root
            ))
            .split(whereSeparator: \.isWhitespace)
            guard heads.count == 1 else { return nil }

            theirs = try GitPorcelain.oid(String(heads[0]))
            let ancestors = try GitPorcelain.string(await run(
                ["merge-base", "--all", ours, theirs],
                at: snapshot.repository.root
            ))
            .split(whereSeparator: \.isWhitespace)
            guard ancestors.count == 1 else { return nil }

            base = try GitPorcelain.oid(String(ancestors[0]))
        } else if operation.kind == .rebase || operation.kind == .cherryPick {
            guard let stopped = operation.stoppedCommit else { return nil }

            theirs = try GitPorcelain.oid(stopped)
            base = try GitPorcelain.oid(GitPorcelain.string(await run(
                ["rev-parse", "--verify", theirs + "^1"],
                at: snapshot.repository.root
            )).trimmingCharacters(in: .newlines))
        } else { return nil }

        var edges: [(String, String)] = []
        for target in [ours, theirs] {
            let fields = try await run(
                [
                    "diff",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--name-status",
                    "-z",
                    "--find-renames=50%",
                    "-l2000",
                    base,
                    target,
                    "--"
                ],
                at: snapshot.repository.root,
                limit: 256_000
            )
            .split(separator: 0).map { try GitPorcelain.string(Data($0)) }
            var index = 0
            while index < fields.count {
                let status = fields[index]
                let renamed = status.hasPrefix("R")
                let count = renamed || status.hasPrefix("C") ? 3 : 2
                guard index + count <= fields.count else {
                    throw GitInspectionError.failed("Malformed native rename report.")
                }

                if renamed {
                    edges.append((try GitPorcelain.path(fields[index + 1]), try GitPorcelain.path(fields[index + 2])))
                }

                index += count
            }
        }
        var connected: Set<String> = [path]
        var changed = true
        while changed {
            changed = false
            for (old, new) in edges where connected.contains(old) || connected.contains(new) {
                if connected.insert(old).inserted { changed = true }
                if connected.insert(new).inserted { changed = true }
            }
        }
        let data = try await run(
            ["ls-files", "--unmerged", "--stage", "-z"],
            at: snapshot.repository.root,
            limit: 1_000_000
        )
        var sides: [GitConflictIndexSide] = []
        for entry in data.split(separator: 0) {
            let pair = try GitPorcelain.string(Data(entry)).split(separator: "\t", maxSplits: 1)
            guard pair.count == 2 else { throw GitInspectionError.failed("Malformed unmerged entry.") }

            let fields = pair[0].split(separator: " "), path = try GitPorcelain.path(String(pair[1]))
            guard fields.count == 3, let stage = Int(fields[2]), (1...3).contains(stage) else {
                throw GitInspectionError.failed("Malformed unmerged stage.")
            }

            if connected.contains(path) {
                guard ["100644", "100755", "120000", "160000"].contains(String(fields[0])) else {
                    throw GitInspectionError.failed("Unsupported rename conflict mode.")
                }

                sides.append(.init(
                    path: path,
                    stage: stage,
                    mode: String(fields[0]),
                    oid: try GitPorcelain.oid(String(fields[1]))
                ))
            }
        }
        let paths = Set(sides.map(\.path)).sorted()
        guard paths.count > 1 else { return nil }

        guard paths.count <= 32 else { throw GitInspectionError.failed("Rename conflict group exceeds 32 paths.") }

        guard try integration(at: snapshot.repository) == operation else {
            throw GitInspectionError.failed("Operation changed while reading related paths.")
        }

        var token = data
        token.append(Data((base + "\n" + ours + "\n" + theirs + "\n" + operation.token).utf8))

        return .init(
            repository: snapshot.repository,
            paths: paths,
            sides: sides,
            token: digest(token),
            integration: operation
        )
    }

    func resolveGroup(
        _ group: GitConflictGroup,
        stage: Int,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        guard (1...3).contains(stage), group.repository == expected.repository,
              expected.integration == group.integration, let first = group.paths.first,
              try await conflictGroup(in: expected, path: first) == group else {
            throw GitInspectionError.failed("Related conflict paths changed; reopen their review.")
        }

        let transaction = try GitIndexTransaction(repository: expected.repository)
        defer { transaction.close() }
        guard let bytes = try indexBytes(expected.repository) else {
            throw GitInspectionError.failed("Index unavailable.")
        }

        try bytes.write(to: transaction.candidate)
        var record = ""
        let zero = String(repeating: "0", count: try GitPorcelain.oid(requireHead(expected)).count)
        for path in group.paths {
            let side = group.sides.first { $0.path == path && $0.stage == stage }
            record += (side.map { $0.mode + " " + $0.oid } ?? "0 " + zero) + "\t" + path + "\0"
        }
        _ = try await run(
            ["update-index", "-z", "--index-info"],
            at: expected.repository.root,
            input: Data(record.utf8),
            indexOverride: transaction.candidate.path
        )
        try Task.checkCancellation()
        let final = try await snapshot(at: expected.repository.root)
        guard final.mutationToken == expected.mutationToken, final.head == expected.head,
              final.branch == expected.branch, try await conflictGroup(in: final, path: first) == group else {
            throw GitInspectionError.failed("Related conflict changed before index publication.")
        }

        try transaction.publish()
        output("Resolved all reviewed related paths in one index publication. Working copies remain unchanged.\n")
    }

    private func requireHead(_ snapshot: GitSnapshot) throws -> String {
        guard let head = snapshot.head else { throw GitInspectionError.failed("Conflict has no HEAD.") }

        return head
    }
}
