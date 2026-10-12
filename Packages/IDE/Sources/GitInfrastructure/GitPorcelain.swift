import Foundation
import IDEApplication

enum GitPorcelain {
    static func string(_ bytes: Data) throws -> String {
        guard let value = String(data: bytes, encoding: .utf8) else { throw GitInspectionError.failed("Git returned a non-UTF-8 name; this repository cannot be displayed faithfully") }

        return value
    }
    static func path(_ value: String) throws -> String {
        var value = value
        if value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty, !value.hasPrefix("/"), !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }), !value.contains("\0") else {
            throw GitInspectionError.failed("Invalid repository-relative path")
        }

        return value
    }
    static func oid(_ value: String) throws -> String {
        guard [40, 64].contains(value.count), value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GitInspectionError.failed("Invalid Git object ID")
        }

        return value
    }

    static func status(_ data: Data, repository: GitRepository, branches: [GitBranch], ignored: [String: String], mutationToken: String? = nil, remotes: [String] = [], integration: GitIntegrationStatus? = nil) throws -> GitSnapshot {
        let records = try data.split(separator: 0).map { try string(Data($0)) }
        var branch: String?, head: String?, upstream: String?, ahead: Int?, behind: Int?
        var changes: [GitChange] = [], i = 0
        while i < records.count {
            let record = records[i]; i += 1
            if record.hasPrefix("# branch.oid ") {
                let value = String(record.dropFirst(13))
                head = value == "(initial)" ? nil : try oid(value)
            } else if record.hasPrefix("# branch.head ") {
                let value = String(record.dropFirst(14)); branch = value == "(detached)" ? nil : value
            } else if record.hasPrefix("# branch.upstream ") { upstream = String(record.dropFirst(18))
            } else if record.hasPrefix("# branch.ab ") {
                let values = record.dropFirst(12).split(separator: " ")
                if values.count == 2 { ahead = Int(values[0].dropFirst()); behind = Int(values[1].dropFirst()) }
            } else if record.hasPrefix("# ") { continue
            } else if record.hasPrefix("? ") || record.hasPrefix("! ") {
                let name = try path(String(record.dropFirst(2)))
                changes.append(.init(path: name,
                                     decoration: record.hasPrefix("! ")
                    ? .init(ignoredReason: ignored[name] ?? "matching Git ignore rule") : .init(isUntracked: true)))
            } else {
                let type = record.first
                let prefixCount = type == "1" ? 8 : type == "2" ? 9 : type == "u" ? 10 : 0
                guard prefixCount > 0 else { throw GitInspectionError.failed("Unsupported Git status record") }

                let fields = record.split(separator: " ", maxSplits: prefixCount, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == prefixCount + 1, fields[1].count == 2 else { throw GitInspectionError.failed("Malformed Git status record") }

                let xy = Array(fields[1]), name = try path(fields[prefixCount])
                var previous: String?
                if type == "2" {
                    guard i < records.count else { throw GitInspectionError.failed("Missing rename source") }

                    previous = try path(records[i]); i += 1
                }

                var decoration = FileDecoration(index: xy[0] == "." ? "" : String(xy[0]), worktree: xy[1] == "." ? "" : String(xy[1]), isConflict: type == "u")
                if fields[2] != "N...", decoration.worktree.isEmpty { decoration.worktree = "M" }
                changes.append(.init(path: name, previousPath: previous, decoration: decoration, submodule: fields[2]))
            }
        }

        return GitSnapshot(repository: repository, branch: branch, head: head, upstream: upstream, ahead: ahead, behind: behind, changes: changes, branches: branches, mutationToken: mutationToken, remotes: remotes, integration: integration)
    }

    static func commitFiles(_ data: Data) throws -> [GitCommitFile] {
        let fields = try data.split(separator: 0).map { try string(Data($0)) }
        var result: [GitCommitFile] = [], i = 0
        while i < fields.count {
            let status = fields[i]; i += 1
            guard i < fields.count else { throw GitInspectionError.failed("Missing changed commit path") }

            let first = try path(fields[i]); i += 1
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard i < fields.count else { throw GitInspectionError.failed("Missing commit rename destination") }

                result.append(.init(path: try path(fields[i]), previousPath: first, status: status)); i += 1
            } else { result.append(.init(path: first, status: status)) }
        }

        return result
    }
}
