import Foundation
import CryptoKit
import IDEApplication

extension GitCLI {
    func integration(at repository: GitRepository) throws -> GitIntegrationStatus? {
        let root = repository.gitDirectory
        let manager = FileManager.default
        let kind: GitIntegrationKind, files: [String], label: String
        if manager.fileExists(atPath: root + "/rebase-merge") {
            kind = .rebase
            files = [
                "rebase-merge/orig-head",
                "rebase-merge/onto",
                "rebase-merge/stopped-sha",
                "rebase-merge/msgnum",
                "rebase-merge/end",
                "rebase-merge/amend",
                "rebase-merge/message",
                "rebase-merge/message-squash",
                "rebase-merge/message-fixup",
                "swiftide-kept-empty",
                "rebase-merge/git-rebase-todo",
                "rebase-merge/done"
            ]
            label = "Rebase in progress"
        } else if manager.fileExists(atPath: root + "/rebase-apply") {
            kind = manager.fileExists(atPath: root + "/rebase-apply/rebasing") ? .rebase : .am
            files = [
                "rebase-apply/orig-head",
                "rebase-apply/onto",
                "rebase-apply/original-commit",
                "rebase-apply/next",
                "rebase-apply/last",
                "rebase-apply/patch",
                "rebase-apply/info",
                "rebase-apply/applying"
            ]
            label = kind == .rebase ? "Rebase in progress" : "Git am in progress"
        } else if manager.fileExists(atPath: root + "/MERGE_HEAD") {
            kind = .merge
            files = ["MERGE_HEAD", "ORIG_HEAD", "MERGE_MSG"]
            label = "Merge in progress"
        }
        else if manager.fileExists(atPath: root + "/CHERRY_PICK_HEAD")
            || manager.fileExists(atPath: root + "/REVERT_HEAD")
            || manager.fileExists(atPath: root + "/sequencer") {
            let todoURL = URL(fileURLWithPath: root + "/sequencer/todo")
            var firstAction = ""
            if let handle = try? FileHandle(forReadingFrom: todoURL) {
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 1024) ?? Data()
                firstAction = String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isWhitespace).first
                    .map(String.init) ?? ""
            }

            if manager.fileExists(atPath: root + "/REVERT_HEAD") || firstAction == "revert" { kind = .revert }
            else if manager.fileExists(atPath: root + "/CHERRY_PICK_HEAD") || firstAction == "pick" {
                kind = .cherryPick
            }
            else { kind = .other }

            files = [
                "CHERRY_PICK_HEAD",
                "REVERT_HEAD",
                "MERGE_MSG",
                "sequencer/head",
                "sequencer/todo",
                "sequencer/abort-safety",
                "sequencer/opts"
            ]
            label = kind == .other
                ? "Other sequencer operation (finish outside SwiftIDE)"
                : kind.rawValue.capitalized + " in progress"
        } else if manager.fileExists(atPath: root + "/BISECT_LOG") {
            kind = .other
            files = ["BISECT_LOG", "BISECT_START"]
            label = "Bisect in progress (finish outside SwiftIDE)"
        } else { return nil }

        var contents: [String: String] = [:], token = Data(kind.rawValue.utf8)
        for file in files {
            token.append(Data((file + "\0").utf8))
            let url = URL(fileURLWithPath: root + "/" + file)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                continue
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = file == "rebase-apply/patch" ? 8_000_000 : 65_536
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                throw GitInspectionError.failed("Git operation metadata is too large to review")
            }

            token.append(data)
            token.append(0)
            contents[file] = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func oid(_ names: [String]) throws -> String? {
            guard let value = names.compactMap({ contents[$0] }).first, !value.isEmpty else { return nil }

            return try GitPorcelain.oid(value)
        }

        let original = try oid(["rebase-merge/orig-head", "rebase-apply/orig-head", "sequencer/head"] + (kind == .merge
                ? ["ORIG_HEAD"]
                : []))
        let stopped = try oid([
            "rebase-merge/stopped-sha",
            "rebase-apply/original-commit",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD"
        ])
        let kept = contents["swiftide-kept-empty"]?.components(separatedBy: "\n") ?? []
        let keptHead = kept.count == 3 && kept[0] == original && kept[1] == stopped
            ? try? GitPorcelain.oid(kept[2])
            : nil
        let pending = kept.count == 4 && kept[0] == original && kept[1] == stopped && kept[3] == "pending"
            ? try? GitPorcelain.oid(kept[2])
            : nil

        return try .init(
            kind: kind,
            token: digest(token),
            originalHead: original,
            onto: oid(["rebase-merge/onto", "rebase-apply/onto"]),
            stoppedCommit: stopped,
            detail: label,
            isEditingCommit: contents["rebase-merge/amend"] != nil,
            keptEmptyHead: keptHead,
            emptyAttemptParent: pending
        )
    }

    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
