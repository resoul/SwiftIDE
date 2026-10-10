import Foundation
import IDEApplication

/// A position as the protocol states it: a line, and a UTF-16 offset within that line.
public struct LSPPosition: Equatable, Sendable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    var json: JSONValue { ["line": .int(line), "character": .int(character)] }
}

/// Converts between the document's UTF-16 offsets and the protocol's line/character pairs, using
/// the line index. The negotiated encoding is UTF-16, which is also what the document counts in,
/// so nothing is converted except the shape.
///
/// Lines end at LF, CR LF or CR, as the protocol defines them. An offset between the CR and the
/// LF of one terminator has no position of its own; it is given the end of its line.
public enum LSPPositionMapper {
    public static func position(of offset: Int, in index: LineIndex) -> LSPPosition {
        let clamped = min(max(offset, 0), index.utf16Length)
        let line = index.line(containing: clamped)
        let content = index.lineExtent(line).content
        return LSPPosition(line: line, character: min(clamped - index.startOffset(ofLine: line), content))
    }

    /// The offset of a position; a character past the end of its line means the end of the line,
    /// and a line past the end of the document means the end of the document.
    public static func offset(of position: LSPPosition, in index: LineIndex) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < index.lineCount else { return index.utf16Length }
        let content = index.lineExtent(position.line).content
        return index.startOffset(ofLine: position.line) + min(max(position.character, 0), content)
    }
}
