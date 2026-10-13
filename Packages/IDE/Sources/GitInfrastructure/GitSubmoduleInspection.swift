import Foundation
import IDEApplication

extension GitCLI {
    /// Parent status does not report ignored contents or paused operations inside nested gitlinks.
    func inspectSubmoduleCheckouts(
        at root: String,
        requireClean: Bool,
        visited: inout Set<String>
    ) async throws -> Data {
        try Task.checkCancellation()
        let nested = try await repository(at: root)
        guard nested.root == DocumentPath.canonical(root), visited.count < 256,
              visited.insert(nested.gitDirectory).inserted else {
            throw GitInspectionError.failed("Nested submodule tree is ambiguous or exceeds the 256-checkout limit.")
        }

        let snapshot = try await self.snapshot(at: nested.root)
        guard snapshot.integration == nil, !requireClean || snapshot.changes.isEmpty else {
            throw GitInspectionError.failed(
                "Nested submodule has an active operation or tracked, untracked or ignored data to preserve: "
                    + nested.root
            )
        }

        let configuration = try await run(
            ["config", "--null", "--list", "--show-origin", "--show-scope"],
            at: nested.root,
            limit: 1_000_000
        )
        var fingerprint = Data((nested.root + "\0" + (snapshot.head ?? "") + "\0" + digest(configuration) + "\0").utf8)
        let index = try await run(["ls-files", "--stage", "-z"], at: nested.root)
        for record in index.split(separator: 0) {
            try Task.checkCancellation()
            let pair = try GitPorcelain.string(Data(record)).split(separator: "\t", maxSplits: 1)
            let fields = pair.first?.split(separator: " ") ?? []
            guard pair.count == 2, fields.count == 3 else {
                throw GitInspectionError.failed("Malformed nested submodule index.")
            }

            guard fields[0] == "160000" else { continue }

            guard fields[2] == "0"
            else { throw GitInspectionError.failed("Nested submodule has an unresolved gitlink.") }

            let path = try GitPorcelain.path(String(pair[1]))
            try validateSubmodulePath(path, root: nested.root)
            let child = nested.root + "/" + path
            if FileManager.default.fileExists(atPath: child + "/.git") {
                fingerprint.append(try await inspectSubmoduleCheckouts(
                    at: child,
                    requireClean: requireClean,
                    visited: &visited
                ))
            } else if let attributes = try? FileManager.default.attributesOfItem(atPath: child) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      try FileManager.default.contentsOfDirectory(atPath: child).isEmpty else {
                    throw GitInspectionError
                        .failed("Uninitialized nested submodule contains data to preserve: " + child)
                }
            }
        }

        return fingerprint
    }

    /// Bind the configuration of an initialized checkout or reused native cache to Review.
    func inspectSubmoduleFetchSource(
        in parent: GitRepository,
        path: String,
        name: String,
        reviewedURL: String
    ) async throws -> Data {
        let directory = try await submoduleGitDirectory(in: parent, path: path, name: name)
        let options = directory.map { ["--git-dir=" + $0] } ?? []
        let effective = try GitPorcelain.string(await run(
            options + ["ls-remote", "--get-url", "--", reviewedURL],
            at: parent.root
        )).trimmingCharacters(in: .newlines)
        guard effective == reviewedURL else {
            throw GitInspectionError
                .failed("Submodule configuration rewrites the reviewed URL; resolve it before Update.")
        }

        let configuration = try await run(
            options + ["config", "--null", "--list", "--show-origin", "--show-scope"],
            at: parent.root,
            limit: 1_000_000
        )

        return Data(((directory ?? "new") + "\0" + digest(configuration)).utf8)
    }

    /// Fetch only the reviewed object from the reviewed URL; never invoke the child's default remote.
    func fetchSubmoduleCommit(
        _ plan: GitRepositoryOperationPlan,
        output: @escaping @Sendable (String) -> Void
    ) async throws -> Bool {
        guard let target = plan.target, let url = plan.url, let name = plan.submoduleName else {
            throw GitInspectionError.failed("No reviewed submodule commit/address.")
        }

        guard let directory = try await submoduleGitDirectory(
            in: plan.repository,
            path: plan.request.value,
            name: name
        ) else { return false }

        let object = try GitPorcelain.oid(target)
        let options = ["--git-dir=" + directory]
        let present = try await run(
            options + ["rev-parse", "--verify", "--quiet", "--end-of-options", object + "^{commit}"],
            at: plan.repository.root,
            accepted: [0, 1, 128]
        )
        if !present.isEmpty { return false }

        _ = try await inspectSubmoduleFetchSource(
            in: plan.repository,
            path: plan.request.value,
            name: name,
            reviewedURL: url
        )

        _ = try await run(
            options + networkOptions + [
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
                object
            ],
            at: plan.repository.root,
            limit: 1_000_000,
            timeout: 300,
            output: output,
            network: true
        )

        return true
    }

    func submoduleGitDirectory(in parent: GitRepository, path: String, name: String) async throws -> String? {
        let checkout = parent.root + "/" + path
        if FileManager.default.fileExists(atPath: checkout + "/.git") {
            let nested = try await repository(at: checkout)
            guard nested.root == DocumentPath.canonical(checkout) else {
                throw GitInspectionError.failed("Unexpected nested worktree.")
            }

            return nested.gitDirectory
        }

        let name = try GitPorcelain.path(name)
        let candidate = try GitPorcelain.string(await run(
            ["rev-parse", "--path-format=absolute", "--git-path", "modules/" + name],
            at: parent.root
        )).trimmingCharacters(in: .newlines)
        guard FileManager.default.fileExists(atPath: candidate) else { return nil }

        guard DocumentPath.canonical(candidate).hasPrefix(parent.commonDirectory + "/modules/") else {
            throw GitInspectionError.failed("Submodule cache points outside native module metadata.")
        }

        return candidate
    }

    /// Initialization changes the selected gitlink's checkout status and registration, but must
    /// preserve the parent index and every saved tracked byte outside submodule checkouts.
    func submoduleInitializationToken(in parent: GitRepository) async throws -> String {
        var bytes = try indexBytes(parent) ?? Data()
        bytes.append(try await run(
            ["diff", "--binary", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=all", "--"],
            at: parent.root
        ))

        return digest(bytes)
    }

    /// A clone without checkout reports missing tracked files. New user contents, an edited
    /// index or a paused operation are not part of initialization.
    func verifyFreshSubmoduleCheckout(at root: String) async throws {
        let snapshot = try await self.snapshot(at: root)
        guard snapshot.repository.root == DocumentPath.canonical(root), snapshot.integration == nil else {
            throw GitInspectionError.failed("Fresh submodule checkout changed during initialization.")
        }

        for change in snapshot.changes {
            guard !change.decoration.isUntracked, change.decoration.ignoredReason == nil,
                  !change.decoration.isConflict,
                  ["", "D"].contains(change.decoration.index),
                  ["", "D"].contains(change.decoration.worktree),
                  !FileManager.default.fileExists(atPath: snapshot.repository.absolutePath(change.path)) else {
                throw GitInspectionError.failed("Fresh submodule contains data to preserve: " + change.path)
            }
        }
    }
}
