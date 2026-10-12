import Foundation
import IDEDomain

public enum GitDiffLineKind: Sendable { case context, addition, deletion }

public struct GitDiffLine: Equatable, Sendable, Identifiable {
    public let id: Int
    public let kind: GitDiffLineKind
    public let text: String
    public var hasNewline: Bool
    public let range: UTF16TextRange
    public var bytes: Data {
        var value = Data(text.utf8)
        if hasNewline { value.append(10) }

        return value
    }
}

public struct GitDiffHunk: Equatable, Sendable, Identifiable {
    public let id: Int
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let header: String
    public var lines: [GitDiffLine]
    public var changedIDs: Set<Int> { Set(lines.filter { $0.kind != .context }.map(\.id)) }
}

/// Frozen canonical diff, base index bytes and metadata. Selection never edits the working file.
public struct GitPartialDiff: Equatable, Sendable {
    public let repository: GitRepository
    public let comparison: GitComparison
    public let text: String
    public let token: String
    public let base: Data
    public let mode: String
    public let removeWhenEmpty: Bool
    public let hunks: [GitDiffHunk]
    public var isUnstage: Bool {
        if case .index = comparison { return true }

        return false
    }
    public var changedIDs: Set<Int> { hunks.reduce(into: []) { $0.formUnion($1.changedIDs) } }

    public init(
        repository: GitRepository,
        comparison: GitComparison,
        text: String,
        token: String,
        base: Data,
        mode: String,
        removeWhenEmpty: Bool
    ) throws {
        self.repository = repository
        self.comparison = comparison
        self.text = text
        self.token = token
        self.base = base
        self.mode = mode
        self.removeWhenEmpty = removeWhenEmpty
        hunks = try Self.parse(text)
        guard !hunks.isEmpty, !changedIDs.isEmpty else {
            throw GitInspectionError.unavailable("No selectable text changes; use the whole-file action.")
        }
    }

    /// Rebuild the index from its exact source lines, retaining every unselected change.
    public func applying(_ selected: Set<Int>) throws -> Data {
        guard !selected.isEmpty, selected.isSubset(of: changedIDs) else {
            throw GitInspectionError.failed("Select current added or removed diff lines.")
        }

        var source: [Data] = []
        var start = base.startIndex
        for index in base.indices where base[index] == 10 {
            source.append(Data(base[start...index]))
            start = base.index(after: index)
        }
        if start < base.endIndex { source.append(Data(base[start..<base.endIndex])) }
        var result = Data(), cursor = 0
        for hunk in hunks {
            let count = isUnstage ? hunk.newCount : hunk.oldCount
            let line = isUnstage ? hunk.newStart : hunk.oldStart
            let position = count == 0 ? line : line - 1
            guard position >= cursor, position <= source.count else { throw Self.malformed }

            for value in source[cursor..<position] { result.append(value) }
            cursor = position
            for value in hunk.lines {
                let consumes = value.kind == .context || (isUnstage ? value.kind == .addition : value.kind == .deletion)
                if consumes {
                    guard cursor < source.count, source[cursor] == value.bytes else { throw Self.malformed }

                    cursor += 1
                }

                let include: Bool
                switch value.kind {
                case .context: include = true
                case .addition: include = isUnstage ? !selected.contains(value.id) : selected.contains(value.id)
                case .deletion: include = isUnstage ? selected.contains(value.id) : !selected.contains(value.id)
                }
                if include { result.append(value.bytes) }
            }
        }
        for value in source[cursor...] { result.append(value) }

        return result
    }

    private static var malformed: GitInspectionError { .failed("The diff does not match its index snapshot; refresh.") }

    private static func parse(_ text: String) throws -> [GitDiffHunk] {
        guard text.utf8.count <= 512_000, !text.contains("\0"),
              text.components(separatedBy: "\n").filter({ $0.hasPrefix("diff --git ") }).count == 1 else {
            throw GitInspectionError.unavailable("Partial staging requires a bounded single-file text diff.")
        }

        let pattern = try NSRegularExpression(pattern: "^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@")
        var hunks: [GitDiffHunk] = [], offset = 0
        for (id, raw) in text.components(separatedBy: "\n").enumerated() {
            defer { offset += raw.utf16.count + 1 }
            if raw.hasPrefix("@@") {
                let value = raw as NSString
                guard let match = pattern.firstMatch(in: raw, range: NSRange(location: 0, length: value.length)) else {
                    throw malformed
                }

                func number(_ group: Int, default fallback: Int = 1) throws -> Int {
                    let range = match.range(at: group)
                    if range.location == NSNotFound { return fallback }
                    guard let number = Int(value.substring(with: range)), number <= 100_000_000 else { throw malformed }

                    return number
                }

                hunks.append(try .init(
                    id: id,
                    oldStart: number(1),
                    oldCount: number(2),
                    newStart: number(3),
                    newCount: number(4),
                    header: raw,
                    lines: []
                ))
            } else if !hunks.isEmpty {
                if raw == "\\ No newline at end of file" {
                    guard let last = hunks.last?.lines.indices.last else { throw malformed }

                    hunks[hunks.count - 1].lines[last].hasNewline = false
                } else if !raw.isEmpty {
                    let kind: GitDiffLineKind
                    switch raw.first { case " ": kind = .context
                    case "+": kind = .addition
                    case "-": kind = .deletion
                    default: throw malformed }
                    hunks[hunks.count - 1].lines.append(.init(
                        id: id,
                        kind: kind,
                        text: String(raw.dropFirst()),
                        hasNewline: true,
                        range: .init(
                            location: offset,
                            length: raw.utf16.count
                        )
                    ))
                }
            }
        }
        for hunk in hunks {
            guard hunk.lines.filter({ $0.kind != .addition }).count == hunk.oldCount,
                  hunk.lines.filter({ $0.kind != .deletion }).count == hunk.newCount else { throw malformed }
        }

        return hunks
    }
}

public struct GitPartialSelection: Equatable, Sendable {
    public let diff: GitPartialDiff
    public let lines: Set<Int>

    public init(diff: GitPartialDiff, lines: Set<Int>) {
        self.diff = diff
        self.lines = lines
    }

    public var title: String { (diff.isUnstage ? "Unstage " : "Stage ") + "selected changes · " + diff.comparison.path }
}

public protocol GitPartialReading: Sendable {
    func partialDiff(in snapshot: GitSnapshot, comparison: GitComparison) async throws -> GitPartialDiff
}
