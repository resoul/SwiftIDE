import Foundation
import IDEApplication

extension GitCLI: GitManagementPlanning {
    public func planManagement(
        in snapshot: GitSnapshot,
        request: GitManagementRequest
    ) async throws -> GitManagementPlan {
        guard snapshot.integration == nil, !request.name.isEmpty, !request.name.hasPrefix("-"),
              request.name.utf8.count <= 1024, !request.name.contains("\0"), request.message.utf8.count <= 64_000,
              !request.message.contains("\0") else {
            throw GitInspectionError.failed("Finish the current operation and enter valid names.")
        }

        let root = snapshot.repository.root, name = request.name
        var oid: String?, url: String?
        let refs = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)%00"], at: root)
        let config = try await run(
            ["config", "--null", "--list", "--show-origin", "--show-scope"],
            at: root,
            limit: 512_000
        )
        switch request.kind {
        case .renameBranch, .deleteBranch:
            try await validateBranch(name, root: root)
            guard let branch = snapshot.branches.first(where: { !$0.isRemote && $0.name == name }) else {
                throw GitInspectionError.failed("Select an existing local branch.")
            }

            oid = branch.oid
            let pattern = "^branch\\." + NSRegularExpression.escapedPattern(for: name) + "\\."
            let localSettings = try await run(
                ["config", "--local", "--null", "--get-regexp", pattern],
                at: root,
                accepted: [0, 1]
            )
            let allSettings = try await run(["config", "--null", "--get-regexp", pattern], at: root, accepted: [0, 1])
            guard localSettings == allSettings else {
                throw GitInspectionError.failed("Inherited/worktree branch configuration requires external management.")
            }

            let worktrees = try await run(["worktree", "list", "--porcelain", "-z"], at: root, limit: 256_000)
            var owner: String?
            for item in worktrees.split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) {
                if item.hasPrefix("worktree ") { owner = DocumentPath.canonical(String(item.dropFirst(9))) }
                if item == "branch " + branch.reference,
                   request.kind == .deleteBranch || owner != root {
                    throw GitInspectionError
                        .failed("Branch is checked out in a worktree; close/switch its owner first.")
                }
            }
            if request.kind == .renameBranch {
                try await validateBranch(request.value, root: root)
                guard !snapshot.branches.contains(where: { $0.reference == "refs/heads/" + request.value }) else {
                    throw GitInspectionError.failed("The destination branch already exists.")
                }
            } else if !request.allowUnmerged {
                guard let head = snapshot.head else {
                    throw GitInspectionError.failed("No current commit for ancestry review.")
                }

                let merged = try await run(["branch", "--merged", head, "--format=%(refname)"], at: root)
                guard String(decoding: merged, as: UTF8.self).components(separatedBy: "\n").contains(branch.reference)
                else {
                    throw GitInspectionError
                        .failed("Branch has unmerged history. Explicitly allow deletion to proceed.")
                }
            }
        case .addRemote, .editRemote, .removeRemote, .deleteRemoteBranch, .deleteRemoteTag:
            _ = try await run(["check-ref-format", "refs/remotes/" + name + "/probe"], at: root)
            guard request.kind == .addRemote ? !snapshot.remotes.contains(name) : snapshot.remotes.contains(name) else {
                throw GitInspectionError.failed("Remote already exists or is missing; refresh.")
            }

            if request.kind == .addRemote || request.kind == .editRemote {
                try GitCloneRequest.validateSource(request.value)
            }

            if request.kind != .addRemote {
                let local = try await run(
                    ["config", "--local", "--null", "--get-all", "remote." + name + ".url"],
                    at: root,
                    accepted: [0, 1]
                )
                let all = try await run(
                    ["config", "--null", "--get-all", "remote." + name + ".url"],
                    at: root,
                    accepted: [0, 1]
                )
                guard local == all, local.split(separator: 0).count == 1 else {
                    throw GitInspectionError
                        .failed("Inherited/worktree or multiple remote URLs require external configuration.")
                }
            }

            if request.kind.isNetwork {
                let ref = (request.kind == .deleteRemoteBranch ? "refs/heads/" : "refs/tags/") + request.value
                _ = try await run(["check-ref-format", ref], at: root)
                let addresses = String(
                    decoding: try await run(["remote", "get-url", "--push", "--all", name], at: root),
                    as: UTF8.self
                )
                .split(separator: "\n").map(String.init)
                guard addresses.count == 1 else {
                    throw GitInspectionError.failed("Choose a remote with one push address.")
                }

                let raw = addresses[0]
                url = !raw.hasPrefix("/") && !raw.contains(":") ? DocumentPath.canonical(root + "/" + raw) : raw
                try GitCloneRequest.validateSource(url!)
                let record = try await run(
                    networkOptions + ["ls-remote", "--refs", "--", url!, ref],
                    at: root,
                    limit: 16_000,
                    timeout: 60,
                    network: true
                )
                let entries = String(decoding: record, as: UTF8.self).split(separator: "\n")
                guard entries.count == 1, let hash = entries[0].split(separator: "\t").first else {
                    throw GitInspectionError.failed("Remote reference is missing or ambiguous.")
                }

                oid = try GitPorcelain.oid(String(hash))
            }
        case .createTag, .deleteTag:
            let reference = "refs/tags/" + name
            _ = try await run(["check-ref-format", reference], at: root)
            let existing = try await run(["show-ref", "--verify", "--hash", reference], at: root, accepted: [0, 1, 128])
            if request.kind == .deleteTag {
                oid = try GitPorcelain.oid(String(decoding: existing, as: UTF8.self).trimmingCharacters(in: .newlines))
            } else {
                guard existing.isEmpty else {
                    throw GitInspectionError.failed("Tag already exists; replacement is not implicit.")
                }

                let target = request.value.isEmpty ? snapshot.head : request.value
                guard let target else { throw GitInspectionError.failed("Create a commit before a tag.") }

                oid = try GitPorcelain.oid(target)
                oid = try GitPorcelain.oid(GitPorcelain.string(await run([
                    "rev-parse",
                    "--verify",
                    "--end-of-options",
                    (oid ?? "") + "^{commit}"
                ], at: root))
                    .trimmingCharacters(in: .newlines))
            }
        }
        let summary = request.kind.rawValue + "\nRepository: " + root + "\nName: " + name
            + (request.value.isEmpty ? "" : "\nValue: " + request.value)
            + (oid.map { "\nReviewed object: " + $0 } ?? "")
            +
            (url
                .map { "\nPush address: " + $0 + "\nDeletes only the reviewed remote object; no local files change."
                } ??
                "")
            + (request.allowUnmerged ? "\nUnmerged branch deletion explicitly allowed." : "")

        return .init(
            repository: snapshot.repository,
            request: request,
            token: digest(refs + config),
            oid: oid,
            url: url,
            summary: summary
        )
    }

    func manage(
        _ plan: GitManagementPlan,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        let fresh = try await planManagement(in: expected, request: plan.request)
        guard fresh == plan else { throw GitInspectionError.failed("References/configuration changed; Review again.") }

        let request = plan.request, root = expected.repository.root
        let object = plan.oid ?? "", address = plan.url ?? ""
        var arguments: [String], input: Data?
        switch request.kind {
        case .renameBranch: arguments = ["branch", "-m", request.name, request.value]
        case .deleteBranch:
            _ = try await run(["update-ref", "-d", "refs/heads/" + request.name, object], at: root, output: output)
            let pattern = "^branch\\." + NSRegularExpression.escapedPattern(for: request.name) + "\\."
            let settings = try await run(
                ["config", "--local", "--null", "--get-regexp", pattern],
                at: root,
                accepted: [0, 1]
            )
            if !settings.isEmpty {
                do { _ = try await run(["config", "--local", "--remove-section", "branch." + request.name], at: root) }
                catch {
                    throw GitInspectionError
                        .failed("Branch was deleted; configuration cleanup failed: " + error.localizedDescription)
                }
            }

            output("Deleted the reviewed branch object; working files/index unchanged.\n")

            return
        case .addRemote: arguments = ["remote", "add", "--", request.name, request.value]
        case .editRemote: arguments = ["remote", "set-url", "--", request.name, request.value]
        case .removeRemote: arguments = ["remote", "remove", request.name]
        case .createTag:
            arguments = ["-c", "tag.gpgSign=false", "tag", "--no-sign"]
            if !request.message.isEmpty {
                arguments += ["-a", "--file=-", "--cleanup=verbatim"]
                input = Data(request.message.utf8)
            }

            arguments += ["--", request.name, object]
        case .deleteTag: arguments = ["update-ref", "-d", "refs/tags/" + request.name, object]
        case .deleteRemoteBranch, .deleteRemoteTag:
            let ref = (request.kind == .deleteRemoteBranch ? "refs/heads/" : "refs/tags/") + request.value
            arguments = networkOptions + [
                "push",
                "--porcelain",
                "--progress",
                "--no-follow-tags",
                "--no-recurse-submodules",
                "--force-with-lease=" + ref + ":" + object,
                "--",
                address,
                ":" + ref
            ]
        }
        try Task.checkCancellation()
        _ = try await run(
            arguments,
            at: root,
            input: input,
            limit: 1_000_000,
            timeout: request.kind.isNetwork
                ? 300
                : 60,
            output: output,
            network: request.kind.isNetwork
        )
    }
}
