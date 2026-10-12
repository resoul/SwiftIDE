import Foundation
import IDEApplication

extension GitCLI: GitTrackingPlanning {
    public func planTracking(in snapshot: GitSnapshot, request: GitTrackingRequest) async throws -> GitTrackingPlan {
        guard snapshot.integration == nil
        else { throw GitInspectionError.failed("Finish the current Git operation before changing tracking.") }

        let root = snapshot.repository.root
        try await validateBranch(request.name, root: root)
        var captured: [Data] = []

        func values(_ key: String, local: Bool = false) async throws -> [String] {
            let data = try await run(
                ["config"] + (local ? ["--local"] : []) + ["--null", "--get-all", key],
                at: root,
                limit: 64_000,
                accepted: [0, 1]
            )
            captured.append(Data((key + (local ? ":local" : ":effective") + "\0").utf8) + data)

            return try data.split(separator: 0).map { try GitPorcelain.string(Data($0)) }
        }

        let worktreeConfig = try await values("extensions.worktreeConfig")
        guard worktreeConfig.isEmpty || worktreeConfig.allSatisfy({ ["false", "no", "0"].contains($0.lowercased()) })
        else {
            throw GitInspectionError
                .failed("Per-worktree configuration requires an external tracking editor in this slice.")
        }

        let branchKey = "branch." + request.name
        let oldRemote = try await values(branchKey + ".remote")
        let oldMerge = try await values(branchKey + ".merge")
        let localRemote = try await values(branchKey + ".remote", local: true)
        let localMerge = try await values(branchKey + ".merge", local: true)
        guard oldRemote == localRemote, oldMerge == localMerge else {
            throw GitInspectionError.failed("Inherited branch tracking configuration must be adjusted externally.")
        }

        switch request {
        case .create(let name, _):
            guard !snapshot.branches.contains(where: { $0.reference == "refs/heads/" + name }), oldRemote.isEmpty,
                  oldMerge.isEmpty else {
                throw GitInspectionError.failed("A branch or tracking configuration already exists for this name.")
            }

        case .set(let branch, _), .remove(let branch):
            guard !branch.isRemote,
                  snapshot.branches.contains(branch)
            else { throw GitInspectionError.failed("Choose a current local branch.") }

            try await checkTrackingWorktree(branch.reference, repository: snapshot.repository)
        }
        var chosenRemote: String?, chosenSource: String?
        if let source = request.source {
            guard source.isRemote,
                  snapshot.branches.contains(source)
            else { throw GitInspectionError.failed("Choose a fetched remote branch.") }

            let symbolic = try await run(["symbolic-ref", "--quiet", source.reference], at: root, accepted: [0, 1])
            guard symbolic.isEmpty
            else { throw GitInspectionError.failed("Choose the actual remote branch, not its HEAD alias.") }

            _ = try GitPorcelain.oid(source.oid)
            var candidates: Set<TrackingMapping> = []
            for remote in snapshot.remotes.sorted() {
                let specs = try await values("remote." + remote + ".fetch")
                for spec in specs {
                    guard let remoteSource = trackingSource(spec, destination: source.reference),
                          !specs.contains(where: { $0.hasPrefix("^") && trackingMatch(
                              String($0.dropFirst()),
                              value: remoteSource
                          ) != nil }) else { continue }

                    candidates.insert(.init(remote: remote, source: remoteSource))
                }
            }
            guard candidates.count == 1, let mapping = candidates.first else {
                throw GitInspectionError
                    .failed("Remote ref has no unique supported fetch mapping; fix the mapping externally.")
            }

            _ = try await run(["check-ref-format", mapping.source], at: root)
            chosenRemote = mapping.remote
            chosenSource = mapping.source
        } else {
            guard !oldRemote.isEmpty || !oldMerge.isEmpty
            else { throw GitInspectionError.failed("This branch has no upstream configuration to remove.") }
        }

        guard try await repository(at: root) == snapshot.repository
        else { throw GitInspectionError.failed("Repository changed while reviewing tracking.") }

        let encoded = try JSONEncoder().encode(captured)

        return .init(
            repository: snapshot.repository,
            request: request,
            remote: chosenRemote,
            remoteSource: chosenSource,
            configurationToken: digest(encoded)
        )
    }

    func tracking(
        _ plan: GitTrackingPlan,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        guard expected.repository == plan.repository
        else { throw GitInspectionError.failed("Repository changed; review tracking again.") }

        let current = try await planTracking(in: expected, request: plan.request)
        guard current == plan else { throw GitInspectionError.failed("Tracking configuration changed; Review again.") }

        try Task.checkCancellation()
        let root = expected.repository.root
        if let source = plan.request.source {
            let oid = try GitPorcelain.string(await run(
                ["rev-parse", "--verify", "--end-of-options", source.reference + "^{commit}"],
                at: root
            )).trimmingCharacters(in: .newlines)
            guard oid == source.oid else { throw GitInspectionError.failed("Fetched branch moved; Review again.") }
        }

        if case .set(let branch, _) = plan.request { try await verifyTrackingBranch(
            branch,
            repository: expected.repository
        ) }

        if case .remove(let branch) = plan.request { try await verifyTrackingBranch(
            branch,
            repository: expected.repository
        ) }

        if case .create(_, let source) = plan.request {
            // Create at the reviewed immutable object, independent of concurrent ref movement.
            _ = try await run(
                ["branch", "--no-track", "--", plan.request.name, try GitPorcelain.oid(source.oid)],
                at: root,
                timeout: 120,
                output: output
            )
        }

        do {
            try Task.checkCancellation()
            if let source = plan.request.source {
                _ = try await run(
                    [
                        "-c",
                        "branch.autoSetupRebase=never",
                        "branch",
                        "--set-upstream-to=" + source.reference,
                        "--",
                        plan.request.name
                    ],
                    at: root,
                    timeout: 120,
                    output: output
                )
            } else {
                _ = try await run(
                    ["branch", "--unset-upstream", "--", plan.request.name],
                    at: root,
                    timeout: 120,
                    output: output
                )
            }

            // Verify what Git actually configured, rather than treating exit status as the full result.
            let remote = try GitPorcelain.string(await run(
                ["config", "--get", "branch." + plan.request.name + ".remote"],
                at: root,
                accepted: [0, 1]
            )).trimmingCharacters(in: .newlines)
            let merge = try GitPorcelain.string(await run(
                ["config", "--get-all", "branch." + plan.request.name + ".merge"],
                at: root,
                accepted: [0, 1]
            )).trimmingCharacters(in: .newlines)
            guard remote == (plan.remote ?? ""), merge == (plan.remoteSource ?? "") else {
                throw GitInspectionError
                    .failed(
                        "Upstream settings differ from the reviewed plan; refresh and inspect the actual configuration."
                    )
            }

            if case .create(_, let source) = plan.request {
                let created = GitBranch(reference: "refs/heads/" + plan.request.name, oid: source.oid)
                try await verifyTrackingBranch(created, repository: expected.repository)
            }
        } catch {
            if case .create = plan.request, !(error is CancellationError), !Task.isCancelled {
                throw GitInspectionError
                    .failed("The local branch was created, but tracking could not be confirmed. It was retained. " +
                        error.localizedDescription)
            }

            throw error
        }
    }

    private func checkTrackingWorktree(_ reference: String, repository: GitRepository) async throws {
        let data = try await run(["worktree", "list", "--porcelain", "-z"], at: repository.root, limit: 256_000)
        var root: String?
        for field in data.split(separator: 0) {
            let text = try GitPorcelain.string(Data(field))
            if text.hasPrefix("worktree ") { root = DocumentPath.canonical(String(text.dropFirst(9))) }
            if text == "branch " + reference, root != repository.root {
                throw GitInspectionError
                    .failed("This branch is open in another worktree; change tracking from its owning workspace.")
            }
        }
    }

    private func verifyTrackingBranch(_ branch: GitBranch, repository: GitRepository) async throws {
        let oid = try GitPorcelain.string(await run(
            ["rev-parse", "--verify", "--end-of-options", branch.reference + "^{commit}"],
            at: repository.root
        )).trimmingCharacters(in: .newlines)
        guard oid == branch.oid else { throw GitInspectionError.failed("Local branch moved; Review again.") }

        try await checkTrackingWorktree(branch.reference, repository: repository)
    }

    private func trackingSource(_ spec: String, destination: String) -> String? {
        let value = spec.hasPrefix("+") ? String(spec.dropFirst()) : spec
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0].hasPrefix("refs/heads/"), let match = trackingMatch(
            parts[1],
            value: destination
        ) else { return nil }

        let sourceParts = parts[0].split(separator: "*", omittingEmptySubsequences: false)
        if sourceParts.count == 1, !parts[1].contains("*") { return parts[0] }
        guard sourceParts.count == 2, parts[1].contains("*") else { return nil }

        return String(sourceParts[0]) + match + String(sourceParts[1])
    }

    private func trackingMatch(_ pattern: String, value: String) -> String? {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return pattern == value ? "" : nil }
        guard parts.count == 2, value.hasPrefix(parts[0]), value.hasSuffix(parts[1]),
              value.count >= parts[0].count + parts[1].count else { return nil }

        return String(value.dropFirst(parts[0].count).dropLast(parts[1].count))
    }
}

private struct TrackingMapping: Hashable {
    let remote: String
    let source: String
}
