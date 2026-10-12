import Foundation
import IDEApplication

extension GitCLI: GitRepositoryOperationPlanning {
    public func planRepositoryOperation(in snapshot: GitSnapshot, request: GitRepositoryOperationRequest) async throws
        -> GitRepositoryOperationPlan {
        guard snapshot.integration == nil, let head = snapshot.head, !request.value.isEmpty,
              request.value.utf8.count <= 4096, !request.value.contains("\0"), !request.value.hasPrefix("-") else {
            throw GitInspectionError.failed("Enter a valid path, revision or remote while no Git operation is active.")
        }

        let root = snapshot.repository.root
        var target: String?, url: String?, name: String?, details: String
        var fingerprint = try await run(["ls-files", "--stage", "-z"], at: root, limit: 8_000_000)
        fingerprint.append(try await run(
            ["diff", "--binary", "--no-ext-diff", "--no-textconv", "--no-renames", "--"],
            at: root,
            limit: 8_000_000
        ))
        fingerprint.append(try await run(
            ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--no-renames", "--"],
            at: root,
            limit: 8_000_000
        ))
        fingerprint.append(try await run(
            ["config", "--null", "--list", "--show-origin", "--show-scope"],
            at: root,
            limit: 1_000_000
        ))
        switch request.kind {
        case .discard:
            let path = try GitPorcelain.path(request.value)
            guard let change = snapshot.changes.first(where: { $0.path == path }),
                  !change.decoration.isUntracked, change.decoration.ignoredReason == nil,
                  !change.decoration.isConflict, change.submodule == "N...", !change.decoration.worktree.isEmpty else {
                throw GitInspectionError
                    .failed(
                        """
                        Choose one tracked file with saved worktree changes. Untracked/submodule files are not \
                        discarded.
                        """
                    )
            }

            target = path
            _ = try workingFile(in: snapshot.repository, path: path, allowSpecial: true)
            details = """
            Replace saved worktree bytes of “\(path)” with its INDEX version. Staged changes remain. \
            Saved edits are lost; unsaved buffers require Save/Cancel and a new review if saved bytes change.
            """
        case .resetSoft, .resetMixed, .resetHard, .cherryPick, .revert:
            guard snapshot.branch != nil else { throw GitInspectionError.failed("Choose a committed local branch.") }

            let oid = try GitPorcelain.oid(GitPorcelain.string(await run(
                ["rev-parse", "--verify", "--end-of-options", request.value + "^{commit}"],
                at: root
            )).trimmingCharacters(in: .newlines))
            target = oid
            if request.kind == .cherryPick || request.kind == .revert {
                guard !snapshot.changes.contains(where: {
                    !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty || $0.decoration.isConflict
                }) else {
                    throw GitInspectionError
                        .failed("Replay needs a clean index and tracked files. Commit changes first.")
                }

                let parents = try GitPorcelain.string(await run(
                    ["show", "--no-show-signature", "-s", "--format=%P", oid],
                    at: root
                ))
                .split(whereSeparator: \.isWhitespace)
                guard parents.count > 1 ? (1...parents.count).contains(request.mainline) : request.mainline == 0 else {
                    throw GitInspectionError
                        .failed("Merge commits require an explicit valid mainline parent; linear commits use 0.")
                }

                details = """
                Replay exactly \(oid); mainline parent: \(request.mainline). \
                Conflicts pause for Resolve/Continue/Skip/Abort. Nothing is pushed.
                """
            } else {
                details = "Move current branch from " + head + " to " + oid + ". "
                    + (request.kind == .resetSoft
                        ? "Index and disk stay unchanged."
                        : request.kind == .resetMixed
                            ? "Index is replaced; disk stays unchanged. Staged content may be lost."
                            :
                            """
                            Index and tracked disk files are replaced. Saved changes may be lost. \
                            Untracked/ignored collisions are refused. Unsaved buffers require Save/Cancel and \
                            another review if bytes change.
                            """)
            }
        case .fetch:
            guard snapshot.remotes.contains(request.value) else {
                throw GitInspectionError.failed("Choose a known remote.")
            }

            let urls = try GitPorcelain.string(await run(["remote", "get-url", "--all", request.value], at: root))
                .split(separator: "\n").map(String.init)
            guard urls.count == 1, let value = urls.first else {
                throw GitInspectionError.failed("One fetch address is required.")
            }

            url = resolvedAddress(value, root: root)
            try GitCloneRequest.validateSource(url!)
            let advertised = try await run(
                networkOptions + ["ls-remote", "--refs", "--heads", "--", url!],
                at: root,
                limit: 1_000_000,
                timeout: 60,
                network: true
            )
            fingerprint.append(advertised)
            let refs = try await run(
                ["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/remotes/" + request.value + "/"],
                at: root
            )
            fingerprint.append(refs)
            details = "Fetch heads from " + url! + " into refs/remotes/" + request.value + "/. "
                + (request.prune ? "Prune missing branches only in that remote namespace. " : "No pruning. ")
                + (request.tags
                    ? """
                    Then fetch tags separately without pruning/overwriting existing tags; partial results are \
                    possible.
                    """
                    : "No tags.")
        case .addSubmodule:
            let path = try GitPorcelain.path(request.value)
            try validateSubmodulePath(path, root: root)
            guard !FileManager.default.fileExists(atPath: root + "/" + path),
                  (try? FileManager.default.attributesOfItem(atPath: root + "/" + path)) == nil,
                  !snapshot.changes.contains(where: { !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty
                          || $0.decoration.isConflict
                  }) else {
                throw GitInspectionError.failed("Adding a submodule requires a new path and clean tracked files/index.")
            }

            let address = resolvedAddress(request.url, root: root)
            guard !request.url.isEmpty else { throw GitInspectionError.failed("Enter the submodule repository URL.") }

            try GitCloneRequest.validateSource(address)
            url = address
            let advertised = try GitPorcelain.string(await run(
                networkOptions + ["ls-remote", "--", address, "HEAD"],
                at: root,
                limit: 64_000,
                timeout: 60,
                network: true
            ))
            let lines = advertised.split(separator: "\n")
            guard lines.count == 1, let line = lines.first else {
                throw GitInspectionError.failed("Submodule remote has no unique HEAD.")
            }

            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1] == "HEAD" else {
                throw GitInspectionError.failed("Malformed submodule HEAD.")
            }

            target = try GitPorcelain.oid(String(fields[0]))
            fingerprint.append(Data(advertised.utf8))
            details = "Clone " + address + " into “" + path + "” at reviewed remote HEAD " + (target ?? "")
                + ". Native Git stages .gitmodules and the gitlink; nothing is committed. "
                + "Partial cloning/staging may remain after failure/cancellation."
        case .updateSubmodule, .syncSubmodule, .deinitSubmodule, .removeSubmodule:
            let path = try GitPorcelain.path(request.value)
            try validateSubmodulePath(path, root: root)
            guard !path.contains("\n"), !path.contains("\r"), path != ".", !path.hasPrefix(".git/") else {
                throw GitInspectionError.failed("Enter an exact submodule path.")
            }

            let listing = try GitPorcelain.string(await run(["ls-files", "--stage", "-z", "--", path], at: root))
            let records = listing.split(separator: "\0")
            guard records.count == 1, let record = records.first else {
                throw GitInspectionError.failed("Select one stage-0 gitlink.")
            }

            let pair = record.split(separator: "\t", maxSplits: 1), fields = pair.first?.split(separator: " ") ?? []
            guard pair.count == 2, pair[1] == path, fields.count == 3, fields[0] == "160000", fields[2] == "0" else {
                throw GitInspectionError.failed("Select one resolved submodule pointer.")
            }

            target = try GitPorcelain.oid(String(fields[1]))
            let modules = try await run(
                ["config", "--file=.gitmodules", "--null", "--get-regexp", "^submodule\\..*\\.path$"],
                at: root
            )
            fingerprint.append(modules)
            for record in modules.split(separator: 0) {
                let parts = try GitPorcelain.string(Data(record)).split(separator: "\n", maxSplits: 1)
                if parts.count == 2, parts[1] == path {
                    guard name == nil else { throw GitInspectionError.failed("Submodule mapping is ambiguous.") }

                    name = String(parts[0].dropFirst(10).dropLast(5))
                }
            }
            guard let module = name, !module.isEmpty, !module.contains("\n"), !module.contains("\0") else {
                throw GitInspectionError.failed("Submodule has no unique .gitmodules mapping.")
            }

            let configured = try await run(
                ["config", "--get", "submodule." + module + ".url"],
                at: root,
                accepted: [0, 1]
            )
            let source = configured.isEmpty || request.kind == .syncSubmodule
                ? try await run(["config", "--file=.gitmodules", "--get", "submodule." + module + ".url"], at: root)
                : configured
            let value = try GitPorcelain.string(source).trimmingCharacters(in: .newlines)
            // Relative URLs depend on superproject remote rules. Require a concrete address for review.
            guard ![.updateSubmodule, .syncSubmodule].contains(request.kind)
                || value.hasPrefix("/") || value.contains(":") else {
                throw GitInspectionError.failed("Resolve relative submodule URLs to a concrete reviewed address first.")
            }

            url = value
            if request.kind == .updateSubmodule || request.kind == .syncSubmodule {
                try GitCloneRequest.validateSource(value)
            }

            var walk = URL(fileURLWithPath: root)
            for component in path.split(separator: "/") {
                walk.appendPathComponent(String(component))
                if let attributes = try? FileManager.default.attributesOfItem(atPath: walk.path),
                   attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw GitInspectionError.failed("Submodule path crosses a symlink; refuse checkout.")
                }
            }
            if FileManager.default.fileExists(atPath: root + "/" + path + "/.git") {
                let nested = try await repository(at: root + "/" + path)
                guard nested.root == DocumentPath.canonical(root + "/" + path) else {
                    throw GitInspectionError.failed("Unexpected nested worktree.")
                }

                let nestedSnapshot = try await self.snapshot(at: nested.root)
                guard nestedSnapshot.integration == nil,
                      request.kind == .syncSubmodule || nestedSnapshot.changes.isEmpty else {
                    throw GitInspectionError
                        .failed(
                            """
                            Submodule has tracked, untracked or ignored contents to preserve. Commit/move them \
                            before update.
                            """
                        )
                }

                fingerprint.append(Data((nestedSnapshot.head ?? "").utf8))
            } else if let contents = try? FileManager.default.contentsOfDirectory(atPath: root + "/" + path),
                      !contents.isEmpty {
                throw GitInspectionError
                    .failed("Uninitialized submodule directory contains files; move them before initialization.")
            }

            if request.kind == .removeSubmodule {
                guard !snapshot.changes
                    .contains(where: { !$0.decoration.index.isEmpty || !$0.decoration.worktree.isEmpty
                            || $0.decoration.isConflict
                    }) else {
                    throw GitInspectionError.failed("Commit parent changes before removing a submodule.")
                }

                details = "Remove clean submodule checkout “" + path + "” and stage its gitlink/.gitmodules "
                    + "deletion. Git objects are kept for recovery; nothing is committed."
            } else if request.kind == .deinitSubmodule {
                details = "Remove the clean local checkout “" + path + "” and unregister its local "
                    + "configuration. Parent gitlink/.gitmodules and Git objects stay intact."
            } else {
                details = request.kind == .syncSubmodule
                    ? "Update local submodule URL configuration from .gitmodules: " + module + " → " + value
                        + ". No checkout/network."
                    : "Initialize/update only “" + path + "” to gitlink " + (target ?? "") + " from " + value
                        + ". Explicit native checkout; no force, recursion or custom update commands."
            }
        }
        let current = try await self.snapshot(at: root)
        guard current.head == snapshot.head, current.branch == snapshot.branch,
              current.mutationToken == snapshot.mutationToken, current.integration == nil else {
            throw GitInspectionError.failed("Repository changed during review.")
        }

        return .init(
            repository: snapshot.repository,
            request: request,
            head: head,
            branch: snapshot.branch,
            target: target,
            url: url,
            submoduleName: name,
            token: digest(fingerprint),
            summary: root + "\n" + details
        )
    }

    func repositoryOperation(
        _ plan: GitRepositoryOperationPlan,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        guard expected.repository == plan.repository,
              try await planRepositoryOperation(in: expected, request: plan.request) == plan else {
            throw GitInspectionError.failed("Reviewed content, configuration or remote state changed; review again.")
        }

        let kind = plan.request.kind, root = expected.repository.root
        var options = integrationOptions, arguments: [String]
        var network = false
        switch kind {
        case .discard:
            guard let path = plan.target else { throw GitInspectionError.failed("No reviewed path.") }

            arguments = ["restore", "--worktree", "--", path]
        case .resetSoft, .resetMixed, .resetHard:
            guard let target = plan.target else { throw GitInspectionError.failed("No reviewed commit.") }

            if kind == .resetHard { try await protectUntracked(expected, target: target, replayOriginal: nil) }
            arguments = [
                "reset",
                kind == .resetSoft ? "--soft" : kind == .resetMixed ? "--mixed" : "--hard",
                target,
                "--"
            ]
        case .cherryPick, .revert:
            guard let target = plan.target else { throw GitInspectionError.failed("No reviewed commit.") }

            try await protectUntracked(expected, target: target, replayOriginal: nil)
            if kind == .revert {
                let parents = try GitPorcelain.string(await run(
                    ["show", "--no-show-signature", "-s", "--format=%P", target],
                    at: root
                ))
                .split(whereSeparator: \.isWhitespace).map(String.init)
                let index = max(0, plan.request.mainline - 1)
                if parents.indices.contains(index) {
                    try await protectUntracked(expected, target: parents[index], replayOriginal: nil)
                }
            }

            arguments = [kind == .cherryPick ? "cherry-pick" : "revert", "--no-edit", "--no-rerere-autoupdate"]
                + (plan.request.mainline > 0 ? ["--mainline", String(plan.request.mainline)] : []) + [target]
        case .fetch:
            guard let url = plan.url else { throw GitInspectionError.failed("No reviewed address.") }

            options = networkOptions
            network = true
            arguments = [
                "fetch",
                "--progress",
                "--refmap=",
                "--no-tags",
                "--no-prune-tags",
                plan.request.prune ? "--prune" : "--no-prune",
                "--no-recurse-submodules",
                "--no-write-fetch-head",
                "--",
                url,
                "+refs/heads/*:refs/remotes/" + plan.request.value + "/*"
            ]
        case .updateSubmodule:
            guard let url = plan.url, let name = plan.submoduleName else {
                throw GitInspectionError.failed("No reviewed submodule.")
            }

            options = networkOptions + ["-c", "submodule.recurse=false", "-c", "submodule." + name + ".url=" + url]
            network = true
            arguments = ["submodule", "update", "--init", "--checkout", "--", plan.request.value]
        case .syncSubmodule:
            arguments = ["submodule", "sync", "--", plan.request.value]
        case .addSubmodule:
            guard let url = plan.url else { throw GitInspectionError.failed("No reviewed address.") }

            options = networkOptions + ["-c", "submodule.recurse=false"]
            network = true
            arguments = ["submodule", "add", "--", url, plan.request.value]
        case .deinitSubmodule:
            arguments = ["submodule", "deinit", "--", plan.request.value]
        case .removeSubmodule:
            arguments = ["rm", "--", plan.request.value]

        }
        let final = try await snapshot(at: root)
        guard final.head == expected.head, final.branch == expected.branch,
              final.mutationToken == expected.mutationToken else {
            throw GitInspectionError.failed("Checkout changed before execution.")
        }

        try Task.checkCancellation()
        _ = try await run(
            options + arguments,
            at: root,
            limit: 1_000_000,
            timeout: network ? 300 : 120,
            output: output,
            network: network
        )
        if kind == .addSubmodule, let target = plan.target {
            let nested = try await snapshot(at: root + "/" + plan.request.value)
            guard nested.head == target else {
                throw GitInspectionError
                    .failed(
                        """
                        Submodule was added at a moved remote HEAD. Inspect actual checkout/index; partial \
                        changes remain.
                        """
                    )
            }
        }

        if kind == .fetch, plan.request.tags, let url = plan.url {
            try Task.checkCancellation()
            output("Head fetch completed. Fetching tags separately; existing tags are not overwritten or pruned.\n")
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
                    url,
                    "refs/tags/*:refs/tags/*"
                ],
                at: root,
                limit: 1_000_000,
                timeout: 300,
                output: output,
                network: true
            )
        }
    }

    private func validateSubmodulePath(_ path: String, root: String) throws {
        guard !path.contains("\n"), !path.contains("\r"), path != ".", path != ".git", path != ".gitmodules",
              !path.hasPrefix(".git/") else { throw GitInspectionError.failed("Enter an exact submodule path.") }

        var walk = URL(fileURLWithPath: root)
        for component in path.split(separator: "/") {
            walk.appendPathComponent(String(component))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: walk.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw GitInspectionError.failed("Submodule path crosses a symlink.")
            }
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/.gitmodules"),
           attributes[.type] as? FileAttributeType != .typeRegular {
            throw GitInspectionError.failed(".gitmodules must be a regular file.")
        }
    }

    private func resolvedAddress(_ value: String, root: String) -> String {
        !value.hasPrefix("/") && !value.contains(":") ? DocumentPath.canonical(root + "/" + value) : value
    }
}
