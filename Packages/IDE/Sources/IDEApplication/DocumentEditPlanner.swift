import Foundation
import IDEDomain

public enum EditValidationError: Error, Equatable, Sendable {
    case invalidRange
    case splitSurrogatePair
    case overlappingEdits
}

/// A validated batch, described by what it replaces, never by whole texts.
/// Short-lived: not a second authoritative copy of the document.
public struct PreparedDocumentEdit: Sendable {
    /// Effective edits (no-ops dropped), non-overlapping, descending by original position.
    public let edits: [DocumentEdit]
    /// The text each edit replaces, aligned with `edits`. Enough to build the inverse.
    public let replaced: [String]
    public let sourceLength: Int
    public let resultLength: Int

    /// Applying these to the text after `edits` restores the text before, in post-change
    /// coordinates. Touching inverse ranges are merged so the result is always a valid batch.
    public var inverseEdits: [DocumentEdit] { DocumentEdit.inverse(of: edits, replaced: replaced) }
}

/// Validates edits against a document without copying it: bounds, surrogate boundaries and
/// overlaps are checked in O(edits), and each edit reads only the text it replaces.
@MainActor
public enum DocumentEditPlanner {
    public static func prepare(
        _ edits: [DocumentEdit], in source: some TextSource
    ) throws -> PreparedDocumentEdit? {
        let length = source.utf16Length
        let ascending = edits.sorted { $0.range.location < $1.range.location }
        var previous: UTF16TextRange?
        var effective: [(edit: DocumentEdit, replaced: String)] = []

        for edit in ascending {
            let range = edit.range
            guard range.location >= 0, range.length >= 0,
                  range.location <= length, range.length <= length - range.location else {
                throw EditValidationError.invalidRange
            }
            let end = range.location + range.length
            for boundary in [range.location, end] where boundary > 0 && boundary < length {
                if UTF16.isLeadSurrogate(source.utf16Unit(at: boundary - 1)),
                   UTF16.isTrailSurrogate(source.utf16Unit(at: boundary)) {
                    throw EditValidationError.splitSurrogatePair
                }
            }
            if let previous,
               previous.location == range.location || previous.location + previous.length > range.location {
                throw EditValidationError.overlappingEdits
            }
            previous = range
            let replaced = source.substring(in: range)
            if !replaced.utf8.elementsEqual(edit.replacement.utf8) {
                effective.append((edit, replaced))
            }
        }

        let net = withoutCancellingNeighbours(withoutCancellingClusters(effective), in: source)
        guard !net.isEmpty else { return nil }
        let descending = Array(net.reversed())
        let delta = descending.reduce(0) { $0 + $1.edit.replacement.utf16.count - $1.edit.range.length }
        return PreparedDocumentEdit(
            edits: descending.map(\.edit), replaced: descending.map(\.replaced),
            sourceLength: length, resultLength: length + delta
        )
    }

    /// Edits at most this many UTF-16 units apart are judged together for cancelling out. Farther
    /// apart, deciding would mean reading the text between them (a whole file, for a formatter that
    /// touches both ends), which the editing path must not do; such edits are taken as real.
    public static let cancellationReach = 256

    /// Edits near each other can restate the text between them: in "aaaa", replacing the first
    /// two units by "a" and inserting "a" before the last is a pair of real edits that leave the
    /// text as it was. The stretch they span is compared as a whole.
    private static func withoutCancellingNeighbours(
        _ edits: [(edit: DocumentEdit, replaced: String)], in source: some TextSource
    ) -> [(edit: DocumentEdit, replaced: String)] {
        var kept: [(edit: DocumentEdit, replaced: String)] = []
        var start = 0
        while start < edits.count {
            var end = start
            while end + 1 < edits.count {
                let gap = edits[end + 1].edit.range.location
                    - (edits[end].edit.range.location + edits[end].edit.range.length)
                guard gap <= cancellationReach else { break }
                end += 1
            }
            var cancels = false
            if end > start {
                var after = ""
                for index in start...end {
                    after += edits[index].edit.replacement
                    if index < end {
                        let from = edits[index].edit.range.location + edits[index].edit.range.length
                        let to = edits[index + 1].edit.range.location
                        after += source.substring(in: UTF16TextRange(location: from, length: to - from))
                    }
                }
                let first = edits[start].edit.range.location
                let last = edits[end].edit.range.location + edits[end].edit.range.length
                let before = source.substring(in: UTF16TextRange(location: first, length: last - first))
                cancels = before.utf8.elementsEqual(after.utf8)
            }
            if !cancels { kept.append(contentsOf: edits[start...end]) }
            start = end + 1
        }
        return kept
    }

    /// Edits that touch each other act on one stretch of text, and together they may leave it as
    /// it was (remove "a", insert "a" after it). Each is a change alone, so they pass the
    /// per-edit check; the stretch is compared as a whole, which reads only text already read.
    /// Edits with a gap between them change separate stretches and cannot cancel.
    private static func withoutCancellingClusters(
        _ edits: [(edit: DocumentEdit, replaced: String)]
    ) -> [(edit: DocumentEdit, replaced: String)] {
        var kept: [(edit: DocumentEdit, replaced: String)] = []
        var start = 0
        while start < edits.count {
            var end = start
            while end + 1 < edits.count,
                  edits[end].edit.range.location + edits[end].edit.range.length == edits[end + 1].edit.range.location {
                end += 1
            }
            let cluster = edits[start...end]
            let isNoOp = end > start
                && cluster.map(\.replaced).joined().utf8.elementsEqual(cluster.map(\.edit.replacement).joined().utf8)
            if !isNoOp { kept.append(contentsOf: cluster) }
            start = end + 1
        }
        return kept
    }
}
