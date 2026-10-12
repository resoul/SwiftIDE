import Foundation
import Darwin
import IDEApplication

extension GitCLI: GitCloning {
    /// Plain names only; never expose credential URLs in the presentation model.
    func remoteNames(at root: String) async throws -> [String] {
        let data = try await run(
            ["config", "--null", "--name-only", "--get-regexp", "^remote\\..*\\.url$"],
            at: root,
            accepted: [0, 1]
        )

        return try Array(Set(data.split(separator: 0).map {
            let key = try GitPorcelain.string(Data($0))

            return String(key.dropFirst(7).dropLast(4))
        })).sorted()
    }

    // Helpers from Git configuration and SSH agent/key files work without a terminal prompt.
    // The first slice uses OpenSSH batch mode; custom SSH wrappers and app login UI are later work.
    var networkOptions: [String] {
        [
            "-c",
            "gc.auto=0",
            "-c",
            "maintenance.auto=false",
            "-c",
            "credential.interactive=false",
            "-c",
            "core.sshCommand=ssh -oBatchMode=yes",
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.file.allow=always",
            "-c",
            "protocol.https.allow=always",
            "-c",
            "protocol.http.allow=always",
            "-c",
            "protocol.ssh.allow=always",
            "-c",
            "protocol.git.allow=always"
        ]
    }

    func fetch(remote: String, expected: GitSnapshot, output: @escaping @Sendable (String) -> Void) async throws {
        guard expected.remotes.contains(remote), !remote.hasPrefix("-"), !remote.contains("\0") else {
            throw GitInspectionError.failed("Select a configured remote and refresh before retrying")
        }

        _ = try await run(["check-ref-format", "refs/remotes/" + remote + "/probe"], at: expected.repository.root)
        let urls = try GitPorcelain.string(await run(
            ["remote", "get-url", "--all", remote],
            at: expected.repository.root
        ))
        for url in urls.split(separator: "\n") { try GitCloneRequest.validateSource(String(url)) }
        // Explicit destination protects local heads from a project's custom fetch refspec.
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
                remote,
                "+refs/heads/*:refs/remotes/" + remote + "/*"
            ],
            at: expected.repository.root,
            limit: 1_000_000,
            timeout: 300,
            output: output,
            network: true
        )
    }

    public func clone(_ request: GitCloneRequest, output: @escaping @Sendable (String) -> Void) async throws -> String {
        try request.validate()
        let parent = DocumentPath.canonical(request.parent)
        let destination = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(request.name).path
        let effective = try GitPorcelain.string(await run(["ls-remote", "--get-url", request.source], at: parent))
            .trimmingCharacters(in: .newlines)
        try GitCloneRequest.validateSource(effective)
        // Atomic exclusive mkdir refuses existing directories, files and symlinks (including dangling ones).
        try await GitMutationGate.shared.run(key: "clone:" + destination) {
            guard Darwin.mkdir(destination, 0o755) == 0 else {
                throw GitInspectionError.failed("Cannot create new destination folder: " + NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                ).localizedDescription)
            }

            // Keep any partial checkout on failure/cancellation; never recursively remove user-visible data.
            _ = try await run(
                networkOptions + [
                    "clone",
                    "--progress",
                    "--no-local",
                    "--no-recurse-submodules",
                    "--",
                    request.source,
                    destination
                ],
                at: parent,
                limit: 1_000_000,
                timeout: 300,
                output: output,
                network: true
            )
        }
        try Task.checkCancellation()
        let repository = try await repository(at: destination)
        guard repository.root == destination else {
            throw GitInspectionError.failed("Clone did not produce the requested worktree")
        }

        return destination
    }
}
