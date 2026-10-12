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
            let blob: Data, size: Int
            if fields[0] == "160000" {
                blob = Data()
                size = 0
            } else {
                let number = try GitPorcelain.string(await run(["cat-file", "-s", oid], at: snapshot.repository.root))
                    .trimmingCharacters(in: .newlines)
                guard let bytes = Int(number), bytes >= 0 else {
                    throw GitInspectionError.failed("Malformed blob size.")
                }

                size = bytes
                blob = bytes <= 8_000_000
                    ? try await run(["cat-file", "blob", oid], at: snapshot.repository.root, limit: 8_000_000)
                    : Data()
            }

            sides.append(.init(
                stage: stage,
                mode: String(fields[0]),
                oid: oid,
                text: fields[0] == "160000"
                    ? "Gitlink commit: " + oid
                    : size > 8_000_000 ? nil : text(blob),
                bytes: size
            ))
        }
        guard !sides.isEmpty else {
            throw GitInspectionError.failed("This file is no longer unmerged; reopen its conflict")
        }

        let working = try workingFile(in: snapshot.repository, path: path, allowSpecial: true)
        let kind: GitConflictWorkingKind = sides.contains(where: { $0.mode == "160000" }) && (working.data == nil)
            ? .submodule
            : working.token.hasPrefix("link:")
                ? .symlink
                : working.token.hasPrefix("directory:")
                    ? .directory
                    : working.token.hasPrefix("oversized:") ? .oversized : working.data == nil ? .missing : .file
        let attributes = try GitPorcelain.string(await run(
            ["check-attr", "-z", "conflict-marker-size", "--", path],
            at: snapshot.repository.root
        ))
        .split(separator: "\0", omittingEmptySubsequences: false)
        let markerSize = attributes.count >= 3 ? Int(attributes[2]) ?? 7 : 7
        var reference: String?
        if (1...4096).contains(markerSize), sides.count == 3, sides.allSatisfy({
            $0.text != nil && ($0.mode == "100644" || $0.mode == "100755")
        }),
            let ours = sides.first(where: { $0.stage == 2 }), let base = sides.first(where: { $0.stage == 1 }),
            let theirs = sides.first(where: { $0.stage == 3 }) {
            let merged = try? await run(
                [
                    "merge-file",
                    "-p",
                    "--object-id",
                    "--diff3",
                    "--marker-size=\(markerSize)",
                    ours.oid,
                    base.oid,
                    theirs.oid
                ],
                at: snapshot.repository.root,
                limit: 8_000_000,
                accepted: Set(0...127)
            )
            reference = merged.flatMap(text)
        }

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
            workingText: kind == .file ? working.data.flatMap(text) : nil,
            workingExists: kind != .missing,
            markerSize: markerSize,
            integration: snapshot.integration,
            diff3Reference: reference,
            workingKind: kind
        )
    }

    func text(_ data: Data) -> String? {
        guard !data.contains(0), var value = String(data: data, encoding: .utf8) else { return nil }

        if value.hasPrefix("\u{feff}") { value.removeFirst() }

        return value
    }

    func workingFile(
        in repository: GitRepository,
        path: String,
        allowSpecial: Bool = false
    ) throws -> (data: Data?, token: String, permissions: Int?) {
        _ = try GitPorcelain.path(path)
        var current = repository.root
        for component in path.split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK || (allowSpecial && current == repository.absolutePath(path))
                else {
                    throw GitInspectionError.unavailable("Symlink conflicts require an external resolver")
                }
            } else if errno != ENOENT { throw GitInspectionError.failed("Cannot inspect conflict path") }
        }
        var info = stat()
        guard lstat(current, &info) == 0 else { return (nil, "missing", nil) }

        if allowSpecial, info.st_mode & S_IFMT == S_IFLNK {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: current)
            let data = Data(target.utf8)
            guard data.count <= 8192 else { throw GitInspectionError.failed("Symlink target exceeds preview bounds.") }

            return (data, "link:" + digest(data), nil)
        }

        if allowSpecial, info.st_mode & S_IFMT == S_IFDIR {
            return (nil, "directory:\(info.st_dev):\(info.st_ino)", Int(info.st_mode & 0o777))
        }

        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw GitInspectionError.unavailable("Directory/submodule conflicts require an external resolver")
        }

        let descriptor = open(current, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GitInspectionError.failed("Cannot read working conflict file") }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GitInspectionError.failed("Working conflict file changed before reading")
        }

        let data = try handle.read(upToCount: 8_000_001) ?? Data()
        if data.count > 8_000_000, allowSpecial {
            return (
                nil,
                "oversized:\(info.st_dev):\(info.st_ino):\(info.st_size):"
                    + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)",
                Int(info.st_mode & 0o777)
            )
        }

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

        let working = try workingFile(in: expected.repository, path: conflict.path, allowSpecial: true)
        let path = try GitPorcelain.path(conflict.path)
        switch resolution {
        case .indexStage(let stage):
            guard let side = fresh.sides.first(where: { $0.stage == stage }) else {
                throw GitInspectionError.failed("Selected stage is absent; choose an explicit deletion instead.")
            }

            try await resolveIndex(conflict, expected: expected, mode: side.mode, oid: side.oid, output: output)
        case .indexDeleted:
            let empty = try GitPorcelain.string(await run(
                ["hash-object", "--stdin"],
                at: expected.repository.root,
                input: Data()
            ))
            .trimmingCharacters(in: .newlines)
            try await resolveIndex(
                conflict,
                expected: expected,
                mode: "0",
                oid: String(repeating: "0", count: empty.count),
                output: output
            )
        case .workingFile, .workingFileAllowingLiteralMarkers:
            guard fresh.workingKind == conflict.workingKind else {
                throw GitInspectionError.failed("Working entry type changed; reopen before marking it resolved.")
            }

            guard fresh.workingKind != .directory, fresh.workingKind != .submodule else {
                throw GitInspectionError
                    .failed("Choose an index-only stage/pointer resolution; nested contents are kept.")
            }

            guard let data = working.data else {
                throw GitInspectionError.failed("The working file is missing; choose deletion or restore a side")
            }

            if fresh.workingKind != .symlink { try rejectMarkers(
                data,
                size: fresh.markerSize,
                allowingLiteral: resolution == .workingFileAllowingLiteralMarkers
            ) }

            // Stage the inspected bytes, not a later worktree read. Git still applies configured clean filters.
            let oid = try GitPorcelain.oid(GitPorcelain.string(await run(
                ["hash-object", "-w", "--stdin"] + (fresh.workingKind == .symlink ? [] : ["--path=" + path]),
                at: expected.repository.root,
                input: data,
                timeout: 120,
                output: output
            )).trimmingCharacters(in: .newlines))
            let staged = try await run(["cat-file", "blob", oid], at: expected.repository.root, limit: 8_000_000)
            if fresh.workingKind != .symlink { try rejectMarkers(
                staged,
                size: fresh.markerSize,
                allowingLiteral: resolution == .workingFileAllowingLiteralMarkers
            ) }

            guard digest(try await conflictIndex(at: expected.repository.root, path: path)) == conflict.indexToken,
                  try integration(at: expected.repository) == conflict.integration else {
                throw GitInspectionError.failed("Conflict changed before staging; reopen it")
            }

            let filemode = try GitPorcelain.string(await run(
                ["config", "--bool", "--get", "core.filemode"],
                at: expected.repository.root,
                accepted: [0, 1]
            )).trimmingCharacters(in: .newlines)
            let mode = fresh.workingKind == .symlink
                ? "120000"
                : filemode == "false"
                    ? (fresh.sides.first { $0.mode == "100644" || $0.mode == "100755" }?.mode ?? "100644")
                    : ((working.permissions ?? 0) & 0o100 != 0 ? "100755" : "100644")
            _ = try await run(
                ["update-index", "--add", "--cacheinfo", mode + "," + oid + "," + path],
                at: expected.repository.root,
                limit: 1_000_000,
                timeout: 120,
                output: output
            )
        case .delete:
            guard fresh.workingKind != .directory, fresh.workingKind != .submodule else {
                throw GitInspectionError.failed("Use index-only deletion to preserve directory/submodule contents.")
            }

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
                  working.token == conflict.workingToken, side.mode != "160000", fresh.workingKind != .directory else {
                throw GitInspectionError.failed("Working file changed since review; reopen before restoring a side")
            }

            let data = try await run(
                ["cat-file", "blob", try GitPorcelain.oid(side.oid)],
                at: expected.repository.root,
                limit: 8_000_000
            )
            guard try workingFile(in: expected.repository, path: path, allowSpecial: true).token == working.token else {
                throw GitInspectionError.failed("Working file changed before restore")
            }

            try Task.checkCancellation()
            let destination = URL(fileURLWithPath: expected.repository.absolutePath(path))
            if side.mode == "120000" {
                guard let target = String(data: data, encoding: .utf8), !target.contains("\0"),
                      data.count <= 8192 else {
                    throw GitInspectionError.failed("Invalid symlink stage target.")
                }

                if working.data != nil { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
                output("Restored only the symlink entry; target contents untouched, index remains unmerged.\n")

                return
            }

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

    private func resolveIndex(
        _ conflict: GitConflict,
        expected: GitSnapshot,
        mode: String,
        oid: String,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        let transaction = try GitIndexTransaction(repository: expected.repository)
        defer { transaction.close() }
        guard let bytes = try indexBytes(expected.repository),
              digest(try await conflictIndex(at: expected.repository.root, path: conflict.path)) == conflict.indexToken,
              try integration(at: expected.repository) == conflict.integration else {
            throw GitInspectionError.failed("Conflict changed before index-only resolution; reopen.")
        }

        try bytes.write(to: transaction.candidate)
        let record = mode + " " + (try GitPorcelain.oid(oid)) + "\t" + (try GitPorcelain.path(conflict.path)) + "\0"
        _ = try await run(
            ["update-index", "-z", "--index-info"],
            at: expected.repository.root,
            input: Data(record.utf8),
            indexOverride: transaction.candidate.path
        )
        let final = try await snapshot(at: expected.repository.root)
        guard final.mutationToken == expected.mutationToken, final.head == expected.head,
              digest(try await conflictIndex(at: expected.repository.root, path: conflict.path)) == conflict.indexToken
        else {
            throw GitInspectionError.failed("Conflict/repository changed before index publication.")
        }

        try transaction.publish()
        output("Resolved only the index entry; disk, symlink targets, nested checkout and editor buffers unchanged.\n")
    }

    private func rejectMarkers(_ data: Data, size: Int, allowingLiteral: Bool = false) throws {
        if let text = text(data) {
            if allowingLiteral {
                var opening = false, separator = false
                let start = String(repeating: "<", count: size)
                let middle = String(repeating: "=", count: size)
                let end = String(repeating: ">", count: size)
                for line in text.split(whereSeparator: \.isNewline) {
                    if line.hasPrefix(start) { opening = true }
                    if opening, line.hasPrefix(middle) { separator = true }
                    if opening, separator, line.hasPrefix(end) {
                        throw GitInspectionError.failed("A complete/nested conflict region remains; resolve it first.")
                    }
                }
                guard GitConflictRegion.parse(text, version: 0, markerSize: size).isEmpty else {
                    throw GitInspectionError
                        .failed("A complete conflict region remains; resolve it before allowing literal markers.")
                }

                return
            }

            let prefixes = ["<", "=", ">", "|"].map { String(repeating: $0, count: size) }
            guard !text.split(whereSeparator: \.isNewline)
                .contains(where: { line in prefixes.contains { line.hasPrefix($0) } }) else {
                throw GitInspectionError.failed("Conflict markers remain in the saved/filtered result")
            }
        }
    }

}
