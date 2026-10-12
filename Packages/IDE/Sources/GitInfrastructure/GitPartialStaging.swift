import Foundation
import IDEApplication

extension GitCLI: GitPartialReading {
    public func partialDiff(in snapshot: GitSnapshot, comparison: GitComparison) async throws -> GitPartialDiff {
        let change: GitChange, reverse: Bool
        switch comparison {
        case .index(let value): change = value
            reverse = true
        case .worktree(let value), .untracked(let value): change = value
            reverse = false
        default: throw GitInspectionError.unavailable("This comparison is read-only.")
        }
        guard snapshot.changes.contains(change), !change.decoration.isConflict, change.previousPath == nil,
              change.submodule == "N...", change.decoration.ignoredReason == nil else {
            throw GitInspectionError.unavailable("Use whole-file actions for renamed, conflicted or special files.")
        }

        let repository = snapshot.repository, root = repository.root, path = try GitPorcelain.path(change.path)
        let indexBefore = try indexBytes(repository)
        let attributes = try await run(["check-attr", "-z", "filter", "working-tree-encoding", "--", path], at: root)
        let fields = attributes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 6, [fields[2], fields[5]].allSatisfy({ $0 == "unspecified" || $0 == "unset" }) else {
            throw GitInspectionError.unavailable("Custom filters/encodings require whole-file staging.")
        }

        let configuration = try await run([
            "config",
            "--null",
            "--get-regexp",
            "^core\\.(autocrlf|eol|safecrlf|attributesfile)$"
        ], at: root, accepted: [
            0,
            1
        ])
        let index = try await entry(["ls-files", "--stage", "-z", "--", path], root: root)
        let flags = try await run(["ls-files", "-v", "-z", "--", path], at: root)
        guard flags.isEmpty || flags.first == 72 else {
            throw GitInspectionError.unavailable("Sparse/assume-unchanged index entries require whole-file actions.")
        }

        let head: (mode: String, oid: String)?
        if reverse, let oid = snapshot.head {
            head = try await entry(["ls-tree", "-z", try GitPorcelain.oid(oid), "--", path], root: root)
        } else { head = nil }

        for mode in [index?.mode, head?.mode].compactMap({ $0 }) where mode != "100644" && mode != "100755" {
            throw GitInspectionError.unavailable("Partial staging supports regular text files.")
        }
        let working = try workingFile(in: repository, path: path)
        guard (working.data?.count ?? 0) <= 512_000 else {
            throw GitInspectionError.unavailable("Partial staging preview limit: 512 KB; use whole-file actions.")
        }

        let base = try await index
            .mapAsync { try await run(["cat-file", "blob", $0.oid], at: root, limit: 512_000) } ?? Data()
        guard !base.contains(0), String(data: base, encoding: .utf8) != nil else {
            throw GitInspectionError.unavailable("Partial staging supports UTF-8 text, not binary files.")
        }

        let options = [
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--no-renames",
            "--full-index",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "--diff-algorithm=myers",
            "--no-indent-heuristic",
            "--unified=3"
        ]
        let arguments: [String], accepted: Set<Int32>
        if reverse {
            arguments = ["diff", "--cached"] + options + ["--", path]
            accepted = [0]
        }
        else if case .untracked = comparison {
            arguments = ["diff", "--no-index"] + options + ["--", "/dev/null", repository.absolutePath(path)]
            accepted = [0, 1]
        } else {
            arguments = ["diff"] + options + ["--", path]
            accepted = [0]
        }

        let bytes = try await run(arguments, at: root, limit: 512_000, accepted: accepted)
        guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8),
              try indexBytes(repository) == indexBefore,
              try workingFile(in: repository, path: path).token == working.token else {
            throw GitInspectionError.failed("File/index changed during inspection, or text is not UTF-8; refresh.")
        }

        let mode = index?.mode ?? head?.mode ?? ((working.permissions ?? 0) & 0o111 == 0 ? "100644" : "100755")
        let token = digest(indexBefore ?? Data()) + ":" + digest(bytes + base + attributes + configuration)
            + ":" + working.token + ":" + (snapshot.head ?? "unborn") + ":" + mode

        return try .init(
            repository: repository,
            comparison: comparison,
            text: text,
            token: token,
            base: base,
            mode: mode,
            removeWhenEmpty: reverse ? head == nil : working.data == nil
        )
    }

    private func entry(_ arguments: [String], root: String) async throws -> (mode: String, oid: String)? {
        let data = try await run(arguments, at: root)
        guard !data.isEmpty else { return nil }

        let records = data.split(separator: 0)
        guard records.count == 1, let tab = records[0].firstIndex(of: 9) else {
            throw GitInspectionError.unavailable("Ambiguous or unmerged index entry.")
        }

        let fields = String(decoding: records[0][..<tab], as: UTF8.self).split(separator: " ")
        guard fields.count == 3 else { throw GitInspectionError.failed("Malformed index entry.") }

        return (String(fields[0]), try GitPorcelain.oid(String(fields[1] == "blob" ? fields[2] : fields[1])))
    }

    func indexBytes(_ repository: GitRepository) throws -> Data? {
        let path = repository.gitDirectory + "/index"
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw GitInspectionError.failed("Cannot read the Git index.") }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw GitInspectionError.failed("The Git index is not a regular file.")
        }

        let bytes = try handle.read(upToCount: 16_000_001) ?? Data()
        guard bytes.count <= 16_000_000 else {
            throw GitInspectionError.unavailable("Index exceeds the 16 MB transaction limit.")
        }

        return bytes
    }

    func partial(
        _ selection: GitPartialSelection,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        let reviewed = selection.diff, repository = expected.repository
        guard repository == reviewed.repository else { throw GitInspectionError.failed("Repository changed.") }

        let transaction = try GitIndexTransaction(repository: repository)
        defer { transaction.close() }
        let fresh = try await partialDiff(in: expected, comparison: reviewed.comparison)
        guard fresh == reviewed else {
            throw GitInspectionError.failed("Diff/index changed; refresh and select again.")
        }

        let result = try reviewed.applying(selection.lines)
        guard result.count <= 512_000 else { throw GitInspectionError.failed("Selected result exceeds 512 KB.") }

        if let bytes = try indexBytes(repository) { try bytes.write(to: transaction.candidate) }
        else {
            _ = try await run(["read-tree", "--empty"], at: repository.root, indexOverride: transaction.candidate.path)
        }

        var record: String
        if result.isEmpty && reviewed.removeWhenEmpty {
            let emptyOID = try await run(["hash-object", "--stdin"], at: repository.root, input: Data())
            let count = String(decoding: emptyOID, as: UTF8.self).trimmingCharacters(in: .newlines).count
            record = "0 " + String(repeating: "0", count: count) + "\t" + reviewed.comparison.path + "\0"
        } else {
            var arguments = ["hash-object", "-w", "--stdin"]
            if case .untracked = reviewed.comparison { arguments.append("--path=" + reviewed.comparison.path) }
            let oid = try GitPorcelain.oid(GitPorcelain.string(await run(arguments, at: repository.root, input: result))
                .trimmingCharacters(in: .whitespacesAndNewlines))
            record = reviewed.mode + " " + oid + "\t" + reviewed.comparison.path + "\0"
        }

        _ = try await run(
            ["update-index", "-z", "--index-info"],
            at: repository.root,
            input: Data(record.utf8),
            indexOverride: transaction.candidate.path
        )
        try Task.checkCancellation()
        // Revalidate after normalization/object writes while still owning the real index lock.
        guard try await partialDiff(in: expected, comparison: reviewed.comparison) == reviewed else {
            throw GitInspectionError.failed("Diff/index changed before publication; refresh.")
        }

        let final = try await snapshot(at: repository.root)
        guard final.head == expected.head, final.branch == expected.branch,
              final.mutationToken == expected.mutationToken else {
            throw GitInspectionError.failed("Repository changed before index publication; refresh.")
        }

        try transaction.publish()
        output("Updated only selected index lines in " + reviewed.comparison.path + ". Working files unchanged.\n")
    }
}

/// Native writers see index.lock. Prepare in an alternate index, then publish by one rename.
final class GitIndexTransaction {
    let candidate: URL
    private let index: String
    private let lock: String
    private let descriptor: Int32
    private var published = false

    init(repository: GitRepository) throws {
        index = repository.gitDirectory + "/index"
        lock = index + ".lock"
        candidate = URL(fileURLWithPath: repository.gitDirectory + "/swiftide-index-" + UUID().uuidString)
        descriptor = open(lock, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw GitInspectionError.failed("Git index is locked; finish the other Git action.")
        }

        var existing = stat()
        if lstat(index, &existing) == 0 {
            var owned = stat()
            guard existing.st_mode & S_IFMT == S_IFREG,
                  fstat(descriptor, &owned) == 0,
                  owned.st_gid == existing.st_gid || fchown(descriptor, uid_t.max, existing.st_gid) == 0,
                  fchmod(descriptor, existing.st_mode & 0o777) == 0 else {
                Darwin.close(descriptor)
                unlink(lock)
                throw GitInspectionError.failed("Cannot preserve native index permissions; no publication.")
            }
        } else if errno != ENOENT {
            Darwin.close(descriptor)
            unlink(lock)
            throw GitInspectionError.failed("Cannot inspect native index permissions.")
        }
    }

    func close() {
        var owned = stat(), actual = stat()
        let ownsPath = fstat(descriptor, &owned) == 0 && lstat(lock, &actual) == 0
            && owned.st_ino == actual.st_ino && owned.st_dev == actual.st_dev
        Darwin.close(descriptor)
        if !published, ownsPath { unlink(lock) }
        try? FileManager.default.removeItem(at: candidate)
        try? FileManager.default.removeItem(atPath: candidate.path + ".lock")
    }

    func publish() throws {
        let source = try FileHandle(forReadingFrom: candidate)
        defer { try? source.close() }
        let bytes = try source.read(upToCount: 16_000_001) ?? Data()
        guard bytes.count <= 16_000_000 else { throw GitInspectionError.failed("Result index exceeds 16 MB.") }

        var actual = stat(), owned = stat()
        guard fstat(descriptor, &owned) == 0, lstat(lock, &actual) == 0,
              actual.st_ino == owned.st_ino, actual.st_dev == owned.st_dev else {
            throw GitInspectionError.failed("Git index lock was replaced; no publication.")
        }

        try Task.checkCancellation()
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        guard rename(lock, index) == 0 else {
            throw GitInspectionError.failed("Cannot publish the selected index changes.")
        }

        published = true
    }
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        if let value = self { return try await transform(value) }

        return nil
    }
}
