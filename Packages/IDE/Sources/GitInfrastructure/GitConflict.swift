import Foundation
import Darwin
import IDEApplication

extension GitCLI: GitConflictReading {
    func conflictIndex(at root: String, path: String) async throws -> Data {
        try await run(
            ["ls-files", "--unmerged", "--stage", "-z", "--", try GitPorcelain.path(path)],
            at: root,
            limit: 64_000
        )
    }

    public func conflict(in snapshot: GitSnapshot, path: String) async throws -> GitConflict {
        guard snapshot.changes.contains(where: { $0.path == path && $0.decoration.isConflict }) else {
            throw GitInspectionError.failed("Select a current unmerged file")
        }

        let data = try await conflictIndex(at: snapshot.repository.root, path: path)
        var sides: [GitConflictSide] = []
        for entry in data.split(separator: 0) {
            let value = try GitPorcelain.string(Data(entry)), pair = value.split(
                separator: "\t",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pair.count == 2, pair[1] == path else {
                throw GitInspectionError.failed("Malformed conflict index entry")
            }

            let fields = pair[0].split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]), (1...3).contains(stage),
                  !sides.contains(where: { $0.stage == stage }) else {
                throw GitInspectionError.failed("Malformed conflict stage")
            }

            let oid = try GitPorcelain.oid(String(fields[1]))
            let blob: Data
            if fields[0] == "160000" { blob = Data() } else {
                blob = try await run(["cat-file", "blob", oid], at: snapshot.repository.root, limit: 1_000_000)
            }

            sides.append(.init(stage: stage, mode: String(fields[0]), oid: oid, text: text(blob), bytes: blob.count))
        }
        guard !sides.isEmpty else {
            throw GitInspectionError.failed("This file is no longer unmerged; reopen its conflict")
        }

        let working = try workingFile(in: snapshot.repository, path: path)
        let attributes = try GitPorcelain.string(await run(
            ["check-attr", "-z", "conflict-marker-size", "--", path],
            at: snapshot.repository.root
        ))
            .split(separator: "\0", omittingEmptySubsequences: false)
        let markerSize = attributes.count >= 3 ? Int(attributes[2]) ?? 7 : 7
        guard (1...4096).contains(markerSize),
              try await conflictIndex(at: snapshot.repository.root, path: path) == data,
              try await repository(at: snapshot.repository.root) == snapshot.repository,
              try integration(at: snapshot.repository) == snapshot.integration else {
            throw GitInspectionError.failed("Conflict changed while loading; reopen it")
        }

        return .init(
            repository: snapshot.repository,
            path: path,
            sides: sides,
            indexToken: digest(data),
            workingToken: working.token,
            workingText: working.data.flatMap(text),
            workingExists: working.data != nil,
            markerSize: markerSize,
            integration: snapshot.integration
        )
    }

    func text(_ data: Data) -> String? {
        guard !data.contains(0), var value = String(data: data, encoding: .utf8) else { return nil }

        if value.hasPrefix("\u{feff}") { value.removeFirst() }

        return value
    }

    func workingFile(
        in repository: GitRepository,
        path: String
    ) throws -> (data: Data?, token: String, permissions: Int?) {
        _ = try GitPorcelain.path(path)
        var current = repository.root
        for component in path.split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw GitInspectionError.unavailable("Symlink conflicts require an external resolver")
                }
            } else if errno != ENOENT { throw GitInspectionError.failed("Cannot inspect conflict path") }
        }
        var info = stat()
        guard lstat(current, &info) == 0 else { return (nil, "missing", nil) }

        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw GitInspectionError.unavailable("Directory/submodule conflicts require an external resolver")
        }

        let descriptor = open(current, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GitInspectionError.failed("Cannot read working conflict file") }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GitInspectionError.failed("Working conflict file changed before reading")
        }

        let data = try handle.read(upToCount: 8_000_001) ?? Data()
        guard data.count <= 8_000_000 else {
            throw GitInspectionError.unavailable("Conflict result exceeds the 8 MB limit")
        }

        return (data, digest(data) + ":" + String(info.st_mode), Int(info.st_mode & 0o777))
    }

    func resolve(
        _ conflict: GitConflict,
        as resolution: GitConflictResolution,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        guard conflict.repository == expected.repository, conflict.supportsResolution,
              conflict.integration == expected.integration,
              digest(try await conflictIndex(at: expected.repository.root, path: conflict.path)) == conflict.indexToken
              else {
            throw GitInspectionError.failed("Conflict stages or operation changed; reopen the conflict")
        }

        let fresh = try await self.conflict(in: expected, path: conflict.path)
        guard fresh.supportsResolution, fresh.indexToken == conflict.indexToken else {
            throw GitInspectionError.failed("Conflict type changed; reopen it")
        }

        let working = try workingFile(in: expected.repository, path: conflict.path)
        let path = try GitPorcelain.path(conflict.path)
        switch resolution {
        case .workingFile:
            guard let data = working.data else {
                throw GitInspectionError.failed("The working file is missing; choose deletion or restore a side")
            }

            try rejectMarkers(data, size: fresh.markerSize)
            // Stage the inspected bytes, not a later worktree read. Git still applies configured clean filters.
            let oid = try GitPorcelain.oid(GitPorcelain.string(await run(
                ["hash-object", "-w", "--stdin", "--path=" + path],
                at: expected.repository.root,
                input: data,
                timeout: 120,
                output: output
            )).trimmingCharacters(in: .newlines))
            let staged = try await run(["cat-file", "blob", oid], at: expected.repository.root, limit: 8_000_000)
            try rejectMarkers(staged, size: fresh.markerSize)
            guard digest(try await conflictIndex(at: expected.repository.root, path: path)) == conflict.indexToken,
                  try integration(at: expected.repository) == conflict.integration else {
                      throw GitInspectionError.failed("Conflict changed before staging; reopen it")
                  }

            let filemode = try GitPorcelain.string(await run(
                ["config", "--bool", "--get", "core.filemode"],
                at: expected.repository.root,
                accepted: [0, 1]
            )).trimmingCharacters(in: .newlines)
            let mode = filemode == "false"
                ? (fresh.sides.first { $0.stage == 2 }?.mode ?? fresh.sides.first { $0.stage == 3 }?.mode ?? "100644")
                : ((working.permissions ?? 0) & 0o100 != 0 ? "100755" : "100644")
            _ = try await run(
                ["update-index", "--add", "--cacheinfo", mode + "," + oid + "," + path],
                at: expected.repository.root,
                limit: 1_000_000,
                timeout: 120,
                output: output
            )
        case .delete:
            guard working.token == conflict.workingToken else {
                throw GitInspectionError.failed("Working file changed since review; reopen before deletion")
            }

            _ = try await run(
                ["rm", "--force", "--", path],
                at: expected.repository.root,
                limit: 1_000_000,
                timeout: 120,
                output: output
            )
        case .restoreStage(let stage):
            guard let side = fresh.sides.first(where: { $0.stage == stage }),
                  working.token == conflict.workingToken else {
                throw GitInspectionError.failed("Working file changed since review; reopen before restoring a side")
            }

            let data = try await run(
                ["cat-file", "blob", try GitPorcelain.oid(side.oid)],
                at: expected.repository.root,
                limit: 1_000_000
            )
            guard try workingFile(in: expected.repository, path: path).token == working.token else {
                throw GitInspectionError.failed("Working file changed before restore")
            }

            try Task.checkCancellation()
            let destination = URL(fileURLWithPath: expected.repository.absolutePath(path))
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            let inherited = try working
                .permissions ??
                (FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int ?? 0o600)
            let executable = side.mode == "100755" ? ((inherited & 0o444) >> 2) : 0
            try FileManager.default.setAttributes(
                [.posixPermissions: (inherited & ~0o111) | executable],
                ofItemAtPath: destination.path
            )
            output("Restored stage \(stage) blob to " + path + "; still unmerged.\n")
            // Restoring a side is not marking it resolved: the unmerged index remains intact.
        }
    }
    private func rejectMarkers(_ data: Data, size: Int) throws {
        if let text = text(data) {
            let prefixes = ["<", "=", ">", "|"].map { String(repeating: $0, count: size) }
            guard !text.split(whereSeparator: \.isNewline)
                .contains(where: { line in prefixes.contains { line.hasPrefix($0) } }) else {
                throw GitInspectionError.failed("Conflict markers remain in the saved/filtered result")
            }
        }
    }

}
