import Foundation
import IDEApplication
import Testing
@testable import LanguageInfrastructure

@Test
func positionsInPlainTextAreLineAndColumn() {
    let index = LineIndex("let a = 1\nlet b = 2\n\nend")
    #expect(LSPPositionMapper.position(of: 0, in: index) == LSPPosition(line: 0, character: 0))
    #expect(LSPPositionMapper.position(of: 4, in: index) == LSPPosition(line: 0, character: 4))
    #expect(LSPPositionMapper.position(of: 10, in: index) == LSPPosition(line: 1, character: 0))
    #expect(LSPPositionMapper.position(of: 20, in: index) == LSPPosition(line: 2, character: 0))
    #expect(LSPPositionMapper.position(of: index.utf16Length, in: index) == LSPPosition(line: 3, character: 3))
}

@Test
func charactersAreUTF16UnitsSoAnEmojiCountsTwice() {
    let text = "a😀b\nλ"
    let index = LineIndex(text)
    // "a" 1 unit, the emoji 2, "b" 1.
    #expect(LSPPositionMapper.position(of: 3, in: index) == LSPPosition(line: 0, character: 3))
    #expect(LSPPositionMapper.position(of: 4, in: index) == LSPPosition(line: 0, character: 4))
    #expect(LSPPositionMapper.position(of: 6, in: index) == LSPPosition(line: 1, character: 1))
}

@Test
func allThreeLineTerminatorsStartANewLine() {
    let index = LineIndex("a\r\nb\rc\nd")
    #expect(LSPPositionMapper.position(of: 3, in: index) == LSPPosition(line: 1, character: 0))
    #expect(LSPPositionMapper.position(of: 5, in: index) == LSPPosition(line: 2, character: 0))
    #expect(LSPPositionMapper.position(of: 7, in: index) == LSPPosition(line: 3, character: 0))
}

@Test
func anOffsetBetweenCarriageReturnAndLineFeedIsGivenTheEndOfItsLine() {
    let index = LineIndex("ab\r\ncd")
    #expect(LSPPositionMapper.position(of: 3, in: index) == LSPPosition(line: 0, character: 2))
}

@Test
func aPositionPastTheEndOfItsLineOrTheDocumentIsClamped() {
    let index = LineIndex("abc\nde")
    #expect(LSPPositionMapper.offset(of: LSPPosition(line: 0, character: 99), in: index) == 3)
    #expect(LSPPositionMapper.offset(of: LSPPosition(line: 9, character: 0), in: index) == 6)
    #expect(LSPPositionMapper.offset(of: LSPPosition(line: -1, character: 4), in: index) == 0)
}

@Test
func offsetsAndPositionsRoundTripOverRandomText() {
    var generator = SystemRandomNumberGenerator()
    let pieces = ["a", "bb", "😀", "λ", "\n", "\r\n", "\r", "  ", "é"]
    for _ in 0..<200 {
        let text = (0..<Int.random(in: 0...40, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
        let index = LineIndex(text)
        let units = Array(text.utf16)
        for offset in 0...units.count {
            // An offset between the halves of a CR LF has no position of its own.
            if offset > 0, offset < units.count, units[offset - 1] == 0x0D, units[offset] == 0x0A { continue }
            let position = LSPPositionMapper.position(of: offset, in: index)
            #expect(LSPPositionMapper.offset(of: position, in: index) == offset, "offset \(offset) in \(text.debugDescription)")
        }
    }
}
