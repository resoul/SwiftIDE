import Foundation
import IDEDomain

/// The text of a document at one version, with what a save of it is judged against, all taken at
/// the same instant.
public struct DocumentCapture: Sendable {
    public let snapshot: DocumentSnapshot
    /// The file revision the text was based on at that instant.
    public let diskRevision: FileRevision?
}

/// How a large document is copied without stopping the window (ADR-018).
public struct CapturePolicy: Sendable, Equatable {
    /// A document up to this size (UTF-16 units) is copied in one go: that takes about a millisecond.
    public var synchronousLimit: Int
    /// The size of one slice of a larger copy; the main thread is given back after each.
    public var sliceUnits: Int

    public init(synchronousLimit: Int = 1_000_000, sliceUnits: Int = 262_144) {
        self.synchronousLimit = synchronousLimit
        self.sliceUnits = sliceUnits
    }

    public static let standard = CapturePolicy()
}

/// The start of a document, copied slice by slice while the document goes on changing.
///
/// It always equals the first `copied` units of the live text: an edit inside what is copied is
/// applied to the copy, one that reaches past it cuts the copy back to where the edit begins, and
/// one after it needs nothing, because the next slice reads the live text.
@MainActor
final class TextCopier {
    private(set) var chunks: [[UInt16]] = []
    private(set) var copied = 0
    private let chunkUnits: Int

    init(chunkUnits: Int = 262_144) {
        self.chunkUnits = max(1, chunkUnits)
    }

    func append(_ buffer: UnsafeBufferPointer<UInt16>) {
        guard !buffer.isEmpty else { return }
        if var last = chunks.popLast() {
            if last.count + buffer.count <= chunkUnits {
                last.append(contentsOf: buffer)
                chunks.append(last)
                copied += buffer.count
                return
            }
            chunks.append(last)
        }
        chunks.append(Array(buffer))
        copied += buffer.count
    }

    /// Edits are in the order they were made: each range is valid when its turn comes.
    func apply(_ changes: DocumentChangeSet) {
        // A change rebuilt after the fact (the text was changed without anyone being told) is
        // described against text the copy may have already read past: start again.
        if changes.isReconciled {
            reset()
            return
        }
        for edit in changes.edits {
            let lower = edit.range.location
            let upper = lower + edit.range.length
            if lower >= copied { continue }
            if upper > copied {
                truncate(to: lower)
                continue
            }
            let units = Array(edit.replacement.utf16)
            replace(lower..<upper, with: units)
            copied += units.count - edit.range.length
        }
    }

    func reset() {
        chunks = []
        copied = 0
    }

    private func truncate(to length: Int) {
        var offset = 0
        var keep = 0
        while keep < chunks.count, offset + chunks[keep].count <= length {
            offset += chunks[keep].count
            keep += 1
        }
        if keep < chunks.count {
            let remainder = length - offset
            if remainder > 0 {
                chunks[keep] = Array(chunks[keep][..<remainder])
                keep += 1
            }
            chunks.removeSubrange(keep...)
        }
        copied = length
    }

    private func replace(_ range: Range<Int>, with units: [UInt16]) {
        var first = 0
        var firstOffset = 0
        while first < chunks.count, firstOffset + chunks[first].count <= range.lowerBound {
            firstOffset += chunks[first].count
            first += 1
        }
        guard first < chunks.count else {
            // At the very end of the copy.
            if !units.isEmpty { chunks.append(units) }
            return
        }
        var last = first
        var lastOffset = firstOffset
        while last < chunks.count - 1, lastOffset + chunks[last].count < range.upperBound {
            lastOffset += chunks[last].count
            last += 1
        }
        var merged = Array(chunks[first][..<(range.lowerBound - firstOffset)])
        merged.append(contentsOf: units)
        merged.append(contentsOf: chunks[last][(range.upperBound - lastOffset)...])
        chunks.replaceSubrange(first...last, with: merged.isEmpty ? [] : [merged])
    }

    /// Builds the text; for a background thread: the copy is a value and nothing else touches it.
    ///
    /// The pieces are cut wherever a slice or an edit happened to end, which may be between the two
    /// halves of a surrogate pair; decoding each piece alone would turn such a character into two
    /// replacement characters. The first half is held back and joined to the next piece.
    nonisolated static func string(from chunks: [[UInt16]]) -> String {
        var result = ""
        result.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        var held: UInt16?
        for (index, chunk) in chunks.enumerated() {
            var body = chunk[...]
            if let lead = held {
                if let first = body.first, UTF16.isTrailSurrogate(first) {
                    result += String(decoding: [lead, first], as: UTF16.self)
                    body = body.dropFirst()
                    held = nil
                } else if body.isEmpty {
                    continue
                } else {
                    result += String(decoding: [lead], as: UTF16.self)   // not a pair after all
                    held = nil
                }
            }
            if index < chunks.count - 1, let last = body.last, UTF16.isLeadSurrogate(last) {
                held = last
                body = body.dropLast()
            }
            result += String(decoding: body, as: UTF16.self)
        }
        if let lead = held { result += String(decoding: [lead], as: UTF16.self) }
        return result
    }
}

extension DocumentSession {
    /// The text at the current version, copied without holding up the window.
    ///
    /// A small document is copied at once. A large one is copied slice by slice, giving the main
    /// thread back after each, while a subscription applies every edit made meanwhile to what was
    /// copied; building the final `String` happens off the main thread. The version, path,
    /// encoding and disk revision are those of the instant the copy was complete and no input
    /// method held marked text: that is the instant the capture is "of".
    ///
    /// `endsComposition` asks the input method to finish marked text if it is live (an explicit
    /// save does; a background write does not interrupt typing).
    public func capture(
        forPath target: String? = nil, policy: CapturePolicy = .standard, endsComposition: Bool = false
    ) async throws -> DocumentCapture {
        reconcileUnobservedMutation()
        if utf16Length <= policy.synchronousLimit, !isComposing {
            let snapshot = snapshot(forPath: target ?? path)
            return DocumentCapture(snapshot: snapshot, diskRevision: diskRevision)
        }
        if endsComposition, isComposing { requestCompositionEnd() }
        let copier = TextCopier(chunkUnits: policy.sliceUnits)
        let subscription = subscribeToChanges { copier.apply($0) }
        defer { unsubscribeFromChanges(subscription) }

        while true {
            try Task.checkCancellation()
            let live = backendLength
            if copier.copied < live {
                let end = min(live, copier.copied + max(1, policy.sliceUnits))
                copyUnits(from: copier.copied, to: end, into: copier)
                await Task.yield()
                continue
            }
            // Everything copied. Edits the backend made that nobody was told about are told now.
            reconcileUnobservedMutation()
            guard copier.copied == backendLength else {
                copier.reset()   // the copy does not match the text: do not trust it, read it again
                continue
            }
            if isComposing {
                if endsComposition { requestCompositionEnd() }
                try await waitForCompositionEnd()
                continue
            }
            break
        }

        // From here to the end of this block there is no suspension: this is the instant.
        precondition(copier.copied == utf16Length, "the copy follows the document")
        let chunks = copier.chunks
        let version = version, documentID = id, encoding = encoding
        let capturedPath = target ?? path
        let revision = diskRevision
        let text = await Task.detached(priority: .userInitiated) { TextCopier.string(from: chunks) }.value
        return DocumentCapture(
            snapshot: DocumentSnapshot(documentID: documentID, path: capturedPath, version: version, text: text, encoding: encoding),
            diskRevision: revision
        )
    }
}
