import Foundation
import IDEApplication

public struct GitCLI: GitInspecting {
    public let executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/git")) { self.executable = executable }

    func run(
        _ arguments: [String],
        at root: String,
        input: Data? = nil,
        limit: Int = 8_000_000,
        accepted: Set<Int32> = [0],
        timeout: TimeInterval = 15,
        output: (@Sendable (String) -> Void)? = nil,
        network: Bool = false,
        literalPaths: Bool = true
    ) async throws -> Data {
        let literal = arguments.first == "check-ignore" || !literalPaths ? [] : ["--literal-pathspecs"]
        let invocation = ["--no-optional-locks"] + literal + [
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "core.pager=cat",
            "-c",
            "color.ui=false",
            "-C",
            root
        ] + arguments
        let result = try await GitCommand.run(
            executable: executable,
            root: root,
            arguments: invocation,
            input: input,
            limit: limit,
            timeout: timeout,
            onOutput: output,
            network: network
        )
        guard accepted.contains(result.status) else {
            if result.error.contains("not a git repository") {
                throw GitInspectionError.unavailable("This folder is not in a Git repository")
            }

            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = message.count > 800
                ? String(message.prefix(160)) + "\n…\n" + String(message.suffix(640))
                : message
            throw GitInspectionError.failed(reason.isEmpty
                ? "Git command failed (exit \(result.status)); see action output"
                : "Git: " + reason)
        }

        return result.output
    }

    func repository(at root: String) async throws -> GitRepository {
        func value(_ arguments: [String]) async throws -> String {
            var text = try GitPorcelain.string(await run(arguments, at: root))
            if text.hasSuffix("\n") { text.removeLast() }
            guard text.hasPrefix("/") else {
                throw GitInspectionError.unavailable("Git worktree paths are unavailable")
            }

            return text
        }

        let top = try await value(["rev-parse", "--show-toplevel"])
        let directory = try await value(["rev-parse", "--absolute-git-dir"])
        let common = try await value(["rev-parse", "--path-format=absolute", "--git-common-dir"])

        return GitRepository(
            root: DocumentPath.canonical(top),
            gitDirectory: DocumentPath.canonical(directory),
            commonDirectory: DocumentPath.canonical(common)
        )
    }

    public func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        let repository = try await repository(at: projectRoot)
        // Capture HEAD before and after multi-command inspection; do not combine different checkouts.
        for _ in 0..<3 {
            try Task.checkCancellation()
            let operation = try integration(at: repository)
            let data = try await run(
                ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"],
                at: repository.root
            )
            let parsed = try GitPorcelain.status(data, repository: repository, branches: [], ignored: [:])
            let ignoredPaths = parsed.changes.filter { $0.decoration.ignoredReason != nil }.map(\.path)
            var reasons: [String: String] = [:]
            if !ignoredPaths.isEmpty {
                let input = Data((ignoredPaths.joined(separator: "\0") + "\0").utf8)
                let response = try await run(
                    ["check-ignore", "--stdin", "-z", "-v"],
                    at: repository.root,
                    input: input,
                    accepted: [0, 1]
                )
                let fields = try response.split(separator: 0).map { try GitPorcelain.string(Data($0)) }
                guard fields.count % 4 == 0 else { throw GitInspectionError.failed("Malformed Git ignore report") }

                for i in stride(from: 0, to: fields.count, by: 4) {
                    reasons[try GitPorcelain.path(fields[i + 3])] = "\(fields[i]):\(fields[i + 1]) · \(fields[i + 2])"
                }
            }

            let refs = try await branches(in: repository)
            let remotes = try await remoteNames(at: repository.root)
            let verification = try await run(
                ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"],
                at: repository.root
            )
            if verification == data, try integration(at: repository) == operation {
                return try GitPorcelain.status(
                    data,
                    repository: repository,
                    branches: refs,
                    ignored: reasons,
                    mutationToken: digest(data + Data((operation?.token ?? "").utf8)),
                    remotes: remotes,
                    integration: operation
                )
            }
        }

        throw GitInspectionError.failed("Repository changed during refresh; refresh Git again")
    }

    private func branches(in repository: GitRepository) async throws -> [GitBranch] {
        let data = try await run(
            [
                "for-each-ref",
                "--sort=refname",
                "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)%00",
                "refs/heads",
                "refs/remotes"
            ],
            at: repository.root
        )

        return try data.split(separator: 10).map { record in
            let fields = try record.split(separator: 0, omittingEmptySubsequences: false).map {
                try GitPorcelain.string(Data($0))
            }
            guard fields.count == 6, fields[0].hasPrefix("refs/heads/") || fields[0].hasPrefix("refs/remotes/") else {
                throw GitInspectionError.failed("Malformed Git branch report")
            }

            return GitBranch(
                reference: fields[0],
                oid: try GitPorcelain.oid(fields[1]),
                upstream: fields[2],
                upstreamRemote: fields[3],
                upstreamSource: fields[4]
            )
        }
    }

    public func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage {
        let revision = try GitPorcelain.oid(revision), count = max(1, min(100, count))
        let data = try await run(
            [
                "log",
                "--no-show-signature",
                "--no-decorate",
                "-z",
                "--format=%H%x00%P%x00%an%x00%at%x00%s",
                "--max-count=\(count + 1)",
                "--skip=\(max(0, offset))",
                revision,
                "--"
            ],
            at: repository.root
        )
        let fields = try data.split(separator: 0, omittingEmptySubsequences: false).map {
            try GitPorcelain.string(Data($0))
        }
        if data.isEmpty { return GitHistoryPage(commits: [], hasMore: false) }
        guard fields.last == "", (fields.count - 1) % 5 == 0 else {
            throw GitInspectionError.failed("Malformed Git history")
        }

        var commits: [GitCommit] = []
        for i in stride(from: 0, to: fields.count - 1, by: 5) {
            guard let timestamp = TimeInterval(fields[i + 3]) else {
                throw GitInspectionError.failed("Invalid commit timestamp")
            }

            commits.append(.init(
                oid: try GitPorcelain.oid(fields[i]),
                parents: try fields[i + 1].split(separator: " ").map { try GitPorcelain.oid(String($0)) },
                author: fields[i + 2],
                date: Date(timeIntervalSince1970: timestamp),
                subject: fields[i + 4]
            ))
        }

        return GitHistoryPage(commits: Array(commits.prefix(count)), hasMore: commits.count > count)
    }

    public func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] {
        let oid = try GitPorcelain.oid(commit.oid)
        let arguments: [String]
        if let first = commit.parents.first {
            arguments = [
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--name-status",
                "-z",
                "-M",
                try GitPorcelain.oid(first),
                oid,
                "--"
            ]
        } else {
            arguments = ["diff-tree", "--root", "--no-commit-id", "--name-status", "-z", "-r", "-M", oid, "--"]
        }

        return try GitPorcelain.commitFiles(await run(arguments, at: repository.root))
    }

    public func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String {
        let path = try GitPorcelain.path(comparison.path)
        let options = ["--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--unified=3"]
        var arguments: [String], paths = [path], accepted: Set<Int32> = [0]
        switch comparison {
        case .stash(let entry):
            arguments = ["stash", "show", "--patch", "--include-untracked"] + options + [
                try GitPorcelain.oid(entry.oid)
            ]
        case .index(let change):
            if let previous = change.previousPath { paths.append(try GitPorcelain.path(previous)) }
            arguments = ["diff", "--cached"] + options + ["--"] + paths
        case .worktree(let change):
            if let previous = change.previousPath { paths.append(try GitPorcelain.path(previous)) }
            arguments = ["diff"] + options + ["--"] + paths
        case .untracked:
            arguments = ["diff", "--no-index"] + options + ["--", "/dev/null", repository.absolutePath(path)]
            accepted = [0, 1]
        case .commit(let commit, let file):
            if let previous = file.previousPath { paths.append(try GitPorcelain.path(previous)) }
            if let first = commit.parents.first {
                arguments = ["diff"] + options + [try GitPorcelain.oid(first), try GitPorcelain.oid(commit.oid), "--"] +
                    paths
            } else {
                arguments = ["show", "--format=", "--no-show-signature"] + options + [
                    try GitPorcelain.oid(commit.oid),
                    "--"
                ] + paths
            }
        }
        let data = try await run(arguments, at: repository.root, limit: 512_000, accepted: accepted)
        guard let text = String(data: data, encoding: .utf8) else {
            return "This diff uses an unsupported text encoding; a text preview is unavailable."
        }

        return text
    }
}
