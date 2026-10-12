import Foundation
import IDEDomain

public enum GitConflictRegionChoice: Sendable { case base, ours, theirs }

public struct GitConflictRegion: Equatable, Sendable, Identifiable {
    public let version: UInt64
    public let range: UTF16TextRange
    public let ours: String
    public let base: String?
    public let theirs: String
    public var id: Int { range.location }

    public func text(_ choice: GitConflictRegionChoice) -> String? {
        switch choice { case .base: base
        case .ours: ours
        case .theirs: theirs }
    }

    public func addingBase(from reference: [GitConflictRegion]) -> GitConflictRegion {
        guard base == nil else { return self }

        let matches = reference.filter { $0.ours == ours && $0.theirs == theirs }
        guard matches.count == 1 else { return self }

        return .init(version: version, range: range, ours: ours, base: matches[0].base, theirs: theirs)
    }

    /// Parse actual merge/diff3 regions. Offsets address the original native document's UTF-16 text.
    public static func parse(_ text: String, version: UInt64, markerSize: Int = 7) -> [GitConflictRegion] {
        guard text.utf8.count <= 8_000_000, (1...4096).contains(markerSize) else { return [] }

        let value = text as NSString
        var result: [GitConflictRegion] = [], position = 0
        var beginning: Int?, oursStart = 0, oursEnd: Int?, baseStart: Int?, baseEnd: Int?, theirsStart: Int?

        func marker(_ line: String, _ character: String) -> Bool {
            let prefix = String(repeating: character, count: markerSize)
            let core = line.trimmingCharacters(in: .newlines)

            return core == prefix || core.hasPrefix(prefix + " ")
        }

        func slice(_ start: Int, _ end: Int) -> String {
            value.substring(with: NSRange(location: start, length: max(0, end - start)))
        }

        while position < value.length {
            let range = value.lineRange(for: NSRange(location: position, length: 0))
            let line = value.substring(with: range)
            if marker(line, "<") {
                if beginning != nil { return [] }
                beginning = range.location
                oursStart = NSMaxRange(range)
                oursEnd = nil
                baseStart = nil
                baseEnd = nil
                theirsStart = nil
            } else if beginning != nil, marker(line, "|"), theirsStart == nil {
                oursEnd = range.location
                baseStart = NSMaxRange(range)
            } else if beginning != nil, marker(line, "="), theirsStart == nil {
                if baseStart != nil { baseEnd = range.location } else { oursEnd = range.location }
                theirsStart = NSMaxRange(range)
            } else if let start = beginning, let oursEnd, let theirsStart, marker(line, ">") {
                result.append(.init(
                    version: version,
                    range: .init(location: start, length: NSMaxRange(range) - start),
                    ours: slice(oursStart, oursEnd),
                    base: baseStart.flatMap { a in baseEnd.map { slice(
                        a,
                        $0
                    ) } },
                    theirs: slice(theirsStart, range.location)
                ))
                beginning = nil
            }

            position = NSMaxRange(range)
        }

        return result
    }
}
