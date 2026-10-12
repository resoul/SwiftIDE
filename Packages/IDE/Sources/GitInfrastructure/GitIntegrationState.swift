import Foundation
import CryptoKit
import IDEApplication

extension GitCLI {
    func integration(at repository: GitRepository) throws -> GitIntegrationStatus? {
        let root = repository.gitDirectory
        let manager = FileManager.default
        let kind: GitIntegrationKind, files: [String], label: String
        if manager.fileExists(atPath: root + "/rebase-merge") {
            kind = .rebase; files = ["rebase-merge/orig-head", "rebase-merge/onto", "rebase-merge/stopped-sha", "rebase-merge/msgnum", "rebase-merge/end", "rebase-merge/git-rebase-todo", "rebase-merge/done"]; label = "Rebase in progress"
        } else if manager.fileExists(atPath: root + "/rebase-apply") {
            kind = manager.fileExists(atPath: root + "/rebase-apply/rebasing") ? .rebase : .other
            files = ["rebase-apply/orig-head", "rebase-apply/onto", "rebase-apply/original-commit", "rebase-apply/next", "rebase-apply/last"]; label = kind == .rebase ? "Rebase in progress" : "Git am in progress (finish outside SwiftIDE)"
        } else if manager.fileExists(atPath: root + "/MERGE_HEAD") {
            kind = .merge; files = ["MERGE_HEAD", "ORIG_HEAD", "MERGE_MSG"]; label = "Merge in progress"
        } else if let marker = ["CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "sequencer"].first(where: { manager.fileExists(atPath: root + "/" + $0) }) {
            kind = .other; files = [marker, "ORIG_HEAD"]; label = "Other Git operation: " + marker + " (finish outside SwiftIDE)"
        } else { return nil }

        var contents: [String: String] = [:], token = Data(kind.rawValue.utf8)
        for file in files {
            token.append(Data((file + "\0").utf8))
            let url = URL(fileURLWithPath: root + "/" + file)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { continue }

            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw GitInspectionError.failed("Git operation metadata is too large to review") }

            token.append(data); token.append(0)
            contents[file] = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func oid(_ names: [String]) throws -> String? {
            guard let value = names.compactMap({ contents[$0] }).first, !value.isEmpty else { return nil }

            return try GitPorcelain.oid(value)
        }

        return try .init(kind: kind,
                         token: digest(token),
                         originalHead: oid(["rebase-merge/orig-head", "rebase-apply/orig-head", "ORIG_HEAD"]),
                         onto: oid(["rebase-merge/onto", "rebase-apply/onto"]),
                         stoppedCommit: oid(["rebase-merge/stopped-sha", "rebase-apply/original-commit"]),
                         detail: label)
    }

    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
