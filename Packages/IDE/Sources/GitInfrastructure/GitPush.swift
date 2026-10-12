import Foundation
import IDEApplication

extension GitCLI: GitPushPlanning, GitForcePushPlanning {
    public func planForcePush(
        in snapshot: GitSnapshot,
        branch: GitBranch,
        remote: String,
        destination: String
    ) async throws -> GitPushPlan {
        let basic = try await planPush(in: snapshot, branch: branch, remote: remote, destination: destination)
        let ref = "refs/heads/" + destination
        let data = try await run(
            networkOptions + ["ls-remote", "--refs", "--", basic.url, ref],
            at: snapshot.repository.root,
            limit: 64_000,
            timeout: 60,
            network: true
        )
        let lines = try GitPorcelain.string(data).split(separator: "\n")
        guard lines.count <= 1 else { throw GitInspectionError.failed("Remote destination is ambiguous.") }

        var lease = ""
        if let line = lines.first {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1] == ref else { throw GitInspectionError.failed("Malformed remote ref.") }

            lease = try GitPorcelain.oid(String(fields[0]))
        }

        return .init(
            repository: basic.repository,
            branch: basic.branch,
            remote: basic.remote,
            destination: basic.destination,
            url: basic.url,
            lease: lease
        )
    }

    public func planPush(
        in snapshot: GitSnapshot,
        branch: GitBranch,
        remote: String,
        destination: String
    ) async throws -> GitPushPlan {
        guard !branch.isRemote, branch.reference.hasPrefix("refs/heads/"), snapshot.branches.contains(branch),
              snapshot.remotes.contains(remote), !remote.hasPrefix("-"), !remote.contains("\0"),
              !destination.isEmpty, !destination.hasPrefix("-"), destination.utf8.count <= 1024,
              !destination.contains("\0") else {
            throw GitInspectionError.failed("Choose an existing local branch, a remote and a valid destination branch")
        }

        _ = try GitPorcelain.oid(branch.oid)
        _ = try await run(["check-ref-format", branch.reference], at: snapshot.repository.root)
        do { _ = try await run(["check-ref-format", "refs/heads/" + destination], at: snapshot.repository.root) }
        catch let error as GitInspectionError {
            if case .failed = error { throw GitInspectionError.failed("Enter a valid destination branch name") }
            throw error
        }
        _ = try await run(["check-ref-format", "refs/remotes/" + remote + "/probe"], at: snapshot.repository.root)
        let urls = try GitPorcelain.string(await run(
            ["remote", "get-url", "--push", "--all", remote],
            at: snapshot.repository.root
        ))
        .split(separator: "\n").map(String.init)
        guard urls.count == 1, let rawURL = urls.first else {
            throw GitInspectionError
                .failed("This remote has multiple push addresses; choose a remote with one push address")
        }

        let url = !rawURL.hasPrefix("/") && !rawURL.contains(":")
            ? DocumentPath.canonical(snapshot.repository.root + "/" + rawURL)
            : rawURL
        try GitCloneRequest.validateSource(url)
        let identity = try await repository(at: snapshot.repository.root)
        guard identity == snapshot.repository else {
            throw GitInspectionError.failed("Repository changed while reviewing Push")
        }

        return .init(repository: identity, branch: branch, remote: remote, destination: destination, url: url)
    }

    func push(_ plan: GitPushPlan, expected: GitSnapshot, output: @escaping @Sendable (String) -> Void) async throws {
        guard plan.repository == expected.repository, expected.branches.contains(plan.branch) else {
            throw GitInspectionError.failed("Source branch changed since review; refresh and review Push again")
        }

        let current = try await plan.lease == nil
            ? planPush(in: expected, branch: plan.branch, remote: plan.remote, destination: plan.destination)
            : planForcePush(in: expected, branch: plan.branch, remote: plan.remote, destination: plan.destination)
        guard current == plan else {
            throw GitInspectionError.failed("Push address changed since review; review Push again")
        }

        try Task.checkCancellation()
        // Freeze the reviewed source and address. Never use push.default, custom mappings or mirror mode.
        let forceOptions = plan.lease.map { ["--force-with-lease=refs/heads/" + plan.destination + ":" + $0] }
            ?? ["--no-force-with-lease"]
        _ = try await run(
            networkOptions + [
                "-c",
                "push.autoSetupRemote=false",
                "-c",
                "push.followTags=false",
                "push",
                "--porcelain",
                "--progress",
                "--no-force",
                "--no-force-if-includes",
                "--no-follow-tags",
                "--no-recurse-submodules",
            ] + forceOptions + [
                "--",
                plan.url,
                (try GitPorcelain.oid(plan.branch.oid)) + ":refs/heads/" + plan
                    .destination
            ],
            at: expected.repository.root,
            limit: 1_000_000,
            timeout: 300,
            output: output,
            network: true
        )
    }
}
