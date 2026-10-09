import IDEDomain

/// How a line ends. A line ends with `\n`, `\r\n` or `\r` (the line model of LSP and of files);
/// only the last line of a document has no terminator.
public enum LineTerminator: Int, Sendable {
    case none = 0, lf, cr, crlf

    public var length: Int {
        switch self {
        case .none: 0
        case .lf, .cr: 1
        case .crlf: 2
        }
    }
}

/// Where lines begin, kept up to date from edits without reading the text again.
///
/// Lines are stored as lengths, in chunks of a few hundred lines with running totals, so that
/// offset ↔ line lookups cost O(log n + chunk) and an edit costs O(edit + chunks): typing in a
/// 100 MB file does not scan it. The index never holds the text, so the neighbours of an edit
/// (the `\r` before an inserted `\n`) are known from the terminator it keeps for every line.
///
/// Lines are numbered from 0. A document always has at least one line; a trailing newline
/// makes the last line empty.
public struct LineIndex: Sendable {
    struct Line: Sendable {
        /// Content length shifted left by two, terminator in the low bits.
        private var packed: Int

        init(content: Int, terminator: LineTerminator) {
            packed = content << 2 | terminator.rawValue
        }

        var content: Int { packed >> 2 }
        var terminator: LineTerminator { LineTerminator(rawValue: packed & 3)! }
        var length: Int { content + terminator.length }
    }

    struct Chunk: Sendable {
        var lines: [Line]
        var unitCount: Int

        init(lines: [Line]) {
            self.lines = lines
            unitCount = lines.reduce(0) { $0 + $1.length }
        }
    }

    private static let preferredChunk = 512
    private static let maximumChunk = 1024

    private var chunks: [Chunk]
    /// Offset and line number at which each chunk starts.
    private var chunkOffset: [Int]
    private var chunkLine: [Int]
    public private(set) var utf16Length: Int
    public private(set) var lineCount: Int

    /// An index of the empty document.
    public init() {
        self.init(lines: [Line(content: 0, terminator: .none)])
    }

    /// Builds the index by reading the whole text once.
    @MainActor
    public init(scanning source: some TextSource) {
        var scanner = LineScanner()
        source.enumerateUTF16(in: UTF16TextRange(location: 0, length: source.utf16Length)) { units in
            scanner.feed(units)
        }
        scanner.finish(endsWithTerminator: false)
        self.init(lines: scanner.lines)
    }

    /// Builds the index of a string. For tests and small inputs.
    public init(_ text: String) {
        var scanner = LineScanner()
        for unit in text.utf16 { scanner.feed(unit) }
        scanner.finish(endsWithTerminator: false)
        self.init(lines: scanner.lines)
    }

    private init(lines: [Line]) {
        chunks = []
        chunkOffset = []
        chunkLine = []
        utf16Length = 0
        lineCount = 0
        chunks = Self.makeChunks(lines)
        recomputeTotals(from: 0)
    }

    // MARK: Queries

    /// The line containing `offset`. An offset at a line's start belongs to that line, the end of
    /// the document to the last line.
    public func line(containing offset: Int) -> Int {
        precondition(offset >= 0 && offset <= utf16Length, "offset outside the document")
        return locate(offset).line
    }

    /// The offset at which `line` begins.
    public func startOffset(ofLine line: Int) -> Int {
        precondition(line >= 0 && line < lineCount, "no such line")
        return locate(line: line).start
    }

    /// The line that starts exactly at `offset`, if one does.
    public func lineStarting(at offset: Int) -> Int? {
        guard offset >= 0, offset <= utf16Length else { return nil }
        let found = locate(offset)
        return found.start == offset ? found.line : nil
    }

    /// Content length (without terminator) and terminator of a line.
    public func lineExtent(_ line: Int) -> (content: Int, terminator: LineTerminator) {
        precondition(line >= 0 && line < lineCount, "no such line")
        let found = locate(line: line)
        let record = chunks[found.chunk].lines[found.indexInChunk]
        return (record.content, record.terminator)
    }

    // MARK: Editing

    /// Applies one replacement given in the coordinates of the current text. Returns false,
    /// leaving the index as it was, when the range does not fit the document.
    @discardableResult
    public mutating func replace(_ range: UTF16TextRange, with replacement: String) -> Bool {
        guard range.location >= 0, range.length >= 0, range.location + range.length <= utf16Length else {
            return false
        }
        let end = range.location + range.length
        var first = locate(range.location)
        let last = locate(end)

        var scanner = LineScanner()

        // A line break just before the edit may be a `\r` that an inserted `\n` completes.
        if first.start == range.location, first.line > 0,
           let previous = record(ofLine: first.line - 1), previous.terminator == .cr {
            first = locate(line: first.line - 1)
            scanner.opaque(first.record.content)
            scanner.carriageReturn()
        } else {
            let before = range.location - first.start
            let content = first.record.content
            scanner.opaque(min(before, content))
            if before > content { scanner.carriageReturn() }   // inside a `\r\n`
        }

        for unit in replacement.utf16 { scanner.feed(unit) }

        let after = end - last.start
        let lastContent = last.record.content
        switch last.record.terminator {
        case .crlf where after > lastContent:   // the edit ends between `\r` and `\n`
            scanner.lineFeed()
        default:
            scanner.opaque(lastContent - min(after, lastContent))
            switch last.record.terminator {
            case .none: break
            case .lf: scanner.lineFeed()
            case .cr: scanner.carriageReturn()
            case .crlf: scanner.carriageReturn(); scanner.lineFeed()
            }
        }
        scanner.finish(endsWithTerminator: last.record.terminator != .none)

        splice(from: first, through: last, with: scanner.lines)
        return true
    }

    // MARK: Structure

    private struct Location {
        var chunk: Int
        var indexInChunk: Int
        var start: Int
        var line: Int
        var record: Line
    }

    private func record(ofLine line: Int) -> Line? {
        guard line >= 0, line < lineCount else { return nil }
        let found = locate(line: line)
        return found.record
    }

    private func locate(_ offset: Int) -> Location {
        // The last chunk starting at or before the offset.
        var low = 0, high = chunks.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chunkOffset[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        var start = chunkOffset[low]
        let lines = chunks[low].lines
        var index = 0
        while index < lines.count - 1, start + lines[index].length <= offset {
            start += lines[index].length
            index += 1
        }
        return Location(chunk: low, indexInChunk: index, start: start, line: chunkLine[low] + index, record: lines[index])
    }

    private func locate(line: Int) -> Location {
        var low = 0, high = chunks.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chunkLine[middle] <= line { low = middle } else { high = middle - 1 }
        }
        let lines = chunks[low].lines
        let index = line - chunkLine[low]
        var start = chunkOffset[low]
        for position in 0..<index { start += lines[position].length }
        return Location(chunk: low, indexInChunk: index, start: start, line: line, record: lines[index])
    }

    /// Replaces the lines from `first` through `last` (inclusive) with `newLines`.
    private mutating func splice(from first: Location, through last: Location, with newLines: [Line]) {
        var combined = Array(chunks[first.chunk].lines[..<first.indexInChunk])
        combined.append(contentsOf: newLines)
        combined.append(contentsOf: chunks[last.chunk].lines[(last.indexInChunk + 1)...])
        chunks.replaceSubrange(first.chunk...last.chunk, with: Self.makeChunks(combined))
        recomputeTotals(from: first.chunk)
    }

    private static func makeChunks(_ lines: [Line]) -> [Chunk] {
        if lines.count <= maximumChunk { return [Chunk(lines: lines)] }
        return stride(from: 0, to: lines.count, by: preferredChunk).map {
            Chunk(lines: Array(lines[$0..<min($0 + preferredChunk, lines.count)]))
        }
    }

    private mutating func recomputeTotals(from chunk: Int) {
        if chunk == 0 {
            chunkOffset = []
            chunkLine = []
        } else {
            chunkOffset.removeSubrange(chunk...)
            chunkLine.removeSubrange(chunk...)
        }
        var offset = chunk == 0 ? 0 : chunkOffset[chunk - 1] + chunks[chunk - 1].unitCount
        var line = chunk == 0 ? 0 : chunkLine[chunk - 1] + chunks[chunk - 1].lines.count
        for index in chunk..<chunks.count {
            chunkOffset.append(offset)
            chunkLine.append(line)
            offset += chunks[index].unitCount
            line += chunks[index].lines.count
        }
        utf16Length = offset
        lineCount = line
    }
}

/// Turns a stream of text into lines. Unknown content is fed as an opaque run of a given length,
/// which is how the index re-reads an edit's neighbours without having their text.
struct LineScanner {
    private(set) var lines: [LineIndex.Line] = []
    private var content = 0
    /// The last thing seen was `\r`; whether it ends the line alone or with a `\n` is not known yet.
    private var pendingReturn = false

    mutating func opaque(_ count: Int) {
        guard count > 0 else { return }
        if pendingReturn { emit(.cr) }
        content += count
    }

    mutating func carriageReturn() {
        if pendingReturn { emit(.cr) }
        pendingReturn = true
    }

    mutating func lineFeed() {
        emit(pendingReturn ? .crlf : .lf)
    }

    mutating func feed(_ unit: UInt16) {
        switch unit {
        case 0x0A: lineFeed()
        case 0x0D: carriageReturn()
        default: opaque(1)
        }
    }

    mutating func feed(_ units: UnsafeBufferPointer<UInt16>) {
        var run = 0
        for unit in units {
            if unit == 0x0A || unit == 0x0D {
                opaque(run)
                run = 0
                feed(unit)
            } else {
                run += 1
            }
        }
        opaque(run)
    }

    /// Ends the stream. A document's last line has no terminator; the end of a re-read region
    /// stops at a terminator that was already there.
    mutating func finish(endsWithTerminator: Bool) {
        if pendingReturn { emit(.cr) }
        if !endsWithTerminator { lines.append(LineIndex.Line(content: content, terminator: .none)) }
        content = 0
    }

    private mutating func emit(_ terminator: LineTerminator) {
        lines.append(LineIndex.Line(content: content, terminator: terminator))
        content = 0
        pendingReturn = false
    }
}
