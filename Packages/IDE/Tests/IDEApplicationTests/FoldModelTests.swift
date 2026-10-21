import Foundation
import IDEApplication
import IDEDomain
import Testing

private func regions(_ text: String, characterLiterals: Bool = false) -> [FoldRegion] {
    FoldRegions.compute(in: Array(text.utf16), characterLiterals: characterLiterals)
}

private func hiddenText(_ text: String, _ region: FoldRegion) -> String {
    (text as NSString).substring(with: NSRange(location: region.hidden.lowerBound, length: region.hidden.count))
}

@Test
func aBlockOverSeveralLinesFoldsItsBodyAndKeepsTheClosingLine() {
    let text = "func f() {\n    a\n    b\n}\nlet x = 1\n"
    let found = regions(text)
    #expect(found.count == 1 && found[0].startLine == 0 && found[0].endLine == 3 && found[0].headerStart == 0)
    #expect(hiddenText(text, found[0]) == "    a\n    b\n")
}

@Test
func nestedBlocksEachGetARegionAndOneLineWithTwoOpenersFoldsTheOuter() {
    let text = "class A {\n    func f() {\n        x\n        y\n    }\n    var v = { a in\n        a\n    }\n}\n"
    let found = regions(text)
    #expect(found.map(\.startLine) == [0, 1, 5])
    #expect(found.map(\.endLine) == [8, 4, 7])
    let same = regions("if a { if b {\n  x\n  y\n} }\n")
    #expect(same.count == 1 && same[0].endLine == 3)
}

@Test
func shortBlocksAndBlocksOnOneLineAreNotFoldable() {
    #expect(regions("if a { b }\n").isEmpty)
    #expect(regions("func f() {\n}\n").isEmpty, "nothing between the braces to hide")
    #expect(regions("func f() {\n    a\n}\n").count == 1, "one hidden line is enough")
}

@Test
func bracesInStringsAndCommentsAreNotBlocks() {
    let text = "let s = \"{\"\n// {\nlet t = \"\\\"{\"\n/* { */\nfunc f() {\n  a\n  b\n}\n"
    let found = regions(text)
    #expect(found.count == 1 && found[0].startLine == 4)
    let multi = "let s = \"\"\"\n{\n  not a block\n\"\"\"\nfunc g() {\n  a\n}\n"
    #expect(regions(multi).map(\.startLine) == [4])
}

@Test
func aBlockCommentOverSeveralLinesFolds() {
    let text = "/* one\n   two\n   three */\nlet x = 1\n/** doc\n * line\n */\nfunc f() {}\n"
    let found = regions(text)
    #expect(found.map(\.startLine) == [0, 4])
    #expect(hiddenText(text, found[0]) == "   two\n")
}

@Test
func characterLiteralsHideBracesOnlyWhenTheLanguageHasThem() {
    let text = "void f() {\n  char c = '}';\n  a;\n}\n"
    #expect(regions(text, characterLiterals: true).map(\.startLine) == [0])
    #expect(regions(text, characterLiterals: false).isEmpty, "without literals the quoted brace closes the block early")
}

@Test
func lineEndingsOfAllKindsCountAsLines() {
    let crlf = "func f() {\r\n  a\r\n  b\r\n}\r\n"
    let found = regions(crlf)
    #expect(found.count == 1 && found[0].endLine == 3 && found[0].hidden == 12..<22)
    #expect(regions("f() {\r  a\r  b\r}\r").count == 1)
}

@MainActor
private func model(_ text: String) -> FoldModel {
    let model = FoldModel()
    model.update(regions: regions(text))

    return model
}

@Test @MainActor
func foldingHidesTheBodyAndTogglesBack() {
    let text = "func f() {\n    a\n    b\n}\n"
    let folds = model(text)
    var changes = 0
    folds.onChange = { changes += 1 }
    #expect(folds.fold(startLine: 0) && folds.isFolded(startLine: 0))
    #expect(folds.hiddenRanges == [11..<23] && changes == 1)
    #expect(!folds.fold(startLine: 0) && !folds.fold(startLine: 5))
    folds.toggle(startLine: 0)
    #expect(!folds.isFolded(startLine: 0) && folds.hiddenRanges.isEmpty && changes == 2)
    folds.fold(startLine: 0)
    folds.unfoldAll()
    #expect(folds.hiddenRanges.isEmpty)
}

@Test @MainActor
func editsAbovePushAFoldDownEditsInTheHeaderKeepItAndEditsInsideOpenIt() {
    let text = "top\nfunc f() {\n    a\n    b\n}\n"
    let folds = model(text)
    folds.fold(startLine: 1)
    let header = folds.folded[0].headerStart, hidden = folds.folded[0].hidden
    folds.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "x\n")])
    #expect(folds.folded.first?.headerStart == header + 2 && folds.folded.first?
        .hidden == (hidden.lowerBound + 2)..<(hidden.upperBound + 2))
    folds.apply([DocumentEdit(range: UTF16TextRange(location: header + 2 + 4, length: 0), replacement: "oo")])
    #expect(folds.folded.first?.headerStart == header + 2, "typing in the header keeps the fold")
    #expect(folds.folded.first?.hidden.lowerBound == hidden.lowerBound + 4)
    folds.apply([DocumentEdit(range: UTF16TextRange(location: hidden.lowerBound + 4 + 2, length: 1), replacement: "")])
    #expect(folds.folded.isEmpty, "an edit in the hidden text opens it")
}

@Test @MainActor
func editsAfterAFoldOrOnTheClosingLineLeaveItAndATouchAtTheEdgeOpensIt() {
    let text = "func f() {\n    a\n    b\n}\nlet y = 2\n"
    let folds = model(text)
    folds.fold(startLine: 0)
    let hidden = folds.folded[0].hidden
    folds.apply([DocumentEdit(range: UTF16TextRange(location: hidden.upperBound + 1, length: 0), replacement: "z")])
    #expect(folds.folded.count == 1 && folds.folded[0].hidden == hidden)
    folds.apply([DocumentEdit(range: UTF16TextRange(location: hidden.lowerBound, length: 0), replacement: "q")])
    #expect(folds.folded.isEmpty, "typing at the start of the first hidden line")
    folds.fold(startLine: 0)
    folds.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "\n")])
    #expect(folds.folded.isEmpty, "a new line at the very start of the header")
}

@Test @MainActor
func readingTheTextAgainKeepsFoldsWhoseHeaderStillStartsARegion() {
    let text = "func f() {\n    a\n    b\n}\n"
    let folds = model(text)
    folds.fold(startLine: 0)
    folds.update(regions: regions("func f() {\n    a\n    b\n    c\n}\n"))
    #expect(folds.isFolded(startLine: 0) && folds.hiddenRanges == [11..<29], "the hidden range follows the region")
    folds.update(regions: regions("func f() { a }\n"))
    #expect(folds.hiddenRanges.isEmpty && folds.regions.isEmpty)
    #expect(folds.region(containingLine: 0) == nil)
}

@Test @MainActor
func theInnermostRegionAroundALineIsFound() {
    let folds = model("class A {\n    func f() {\n        x\n        y\n    }\n}\n")
    #expect(folds.region(containingLine: 2)?.startLine == 1)
    #expect(folds.region(containingLine: 1)?.startLine == 1)
    #expect(folds.region(containingLine: 5)?.startLine == 0)
    #expect(folds.region(containingLine: 6) == nil)
}

// MARK: Markdown

private func markdown(_ text: String) -> [FoldRegion] { FoldRegions.computeMarkdown(in: Array(text.utf16)) }

@Test
func markdownLinesAreClassifiedWithFencesHeadingsAndTerminators() {
    let text = "# Title\n\nSome text\n```swift\n# not a heading\n```\n~~~\ncode\n"
    let kinds = MarkdownStructure.lines(in: Array(text.utf16)).map(\.kind)
    #expect(kinds == [
        .heading(level: 1),
        .blank,
        .text,
        .fenceOpen(marker: 0x60, length: 3),
        .code,
        .fenceClose,
        .fenceOpen(marker: 0x7E, length: 3),
        .code
    ])
    #expect(MarkdownStructure.lines(in: Array("a\r\nb\rc".utf16)).map(\.range) == [0..<1, 3..<4, 5..<6])
    #expect(MarkdownStructure.lines(in: []).count == 1)
    let notHeading = MarkdownStructure.lines(in: Array("#tag\n####### seven\n    # indented\n".utf16)).map(\.kind)
    #expect(notHeading == [.text, .text, .text])
}

@Test
func aLongerFenceClosesOnlyWithAtLeastItsLengthAndABacktickInfoCannotHoldABacktick() {
    let kinds = MarkdownStructure.lines(in: Array("````\n```\ntext\n````\n``` a`b\nx\n".utf16)).map(\.kind)
    #expect(kinds == [.fenceOpen(marker: 0x60, length: 4), .code, .code, .fenceClose, .text, .text])
}

@Test
func sectionsFoldFromTheirHeadingToTheNextHeadingOfTheSameOrAHigherLevel() {
    let text = "# A\ntext\n## B\nmore\nlines\n# C\nlast\n"
    let found = markdown(text)
    #expect(found.map(\.startLine) == [0, 2, 5])
    #expect(found.map(\.endLine) == [5, 5, 7])
    #expect(hiddenText(text, found[0]) == "text\n## B\nmore\nlines\n")
    #expect(hiddenText(text, found[1]) == "more\nlines\n")
    #expect(hiddenText(text, found[2]) == "last\n")
}

@Test
func aHeadingWithNothingUnderItAndHeadingsInsideCodeAreNotFoldable() {
    #expect(markdown("# A\n# B\ntext\n").map(\.startLine) == [1])
    let text = "```\n# not a heading\nmore\n```\n"
    let found = markdown(text)
    #expect(found.count == 1 && found[0].startLine == 0 && hiddenText(text, found[0]) == "# not a heading\nmore\n")
}

@Test
func anUnclosedFenceAndTheSectionAroundItFoldToTheEndOfTheText() {
    let text = "# A\n```\ncode\nmore"
    let found = markdown(text)
    #expect(found.map(\.startLine) == [0, 1])
    #expect(found.allSatisfy { $0.hidden.upperBound == text.utf16.count })
    #expect(markdown("").isEmpty && markdown("plain\ntext\n").isEmpty)
}

// MARK: Other languages

private func fold(_ text: String, _ regions: ([UInt16]) -> [FoldRegion]) -> [FoldRegion] { regions(Array(text.utf16)) }

@Test
func jsonFoldsObjectsAndArraysAndIgnoresBracketsInStrings() {
    let text = "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"s\": \"}[{\",\n  \"o\": {\n    \"k\": 1\n  }\n}\n"
    let found = fold(text) { FoldRegions.compute(in: $0, pairs: [.braces, .brackets]) }
    #expect(found.map(\.startLine) == [0, 1, 6] && found.map(\.endLine) == [9, 4, 8])
    #expect(
        fold(text) { FoldRegions.compute(in: $0, pairs: .braces) }.map(\.startLine) == [0, 6],
        "brackets only when asked"
    )
    #expect(fold("(\n a\n)\n") { FoldRegions.compute(in: $0, pairs: .parentheses) }.map(\.startLine) == [0])
    #expect(
        fold("{\n  ]\n  a\n}\n") { FoldRegions.compute(in: $0, pairs: [.braces, .brackets]) }.map(\.startLine) == [0],
        "a closer that does not match is ignored"
    )
}

@Test
func hashCommentsHideTheirBracesWhenAsked() {
    let text = "f() {\n  # }\n  a\n}\n"
    #expect(fold(text) { FoldRegions.compute(in: $0, hashComments: true) }.map(\.endLine) == [3])
    #expect(
        fold(text) { FoldRegions.compute(in: $0, hashComments: false) }.isEmpty,
        "the brace in the comment closes it early"
    )
}

@Test
func xmlFoldsElementsCommentsAndCDATAThatSpanLines() {
    let text = "<?xml version=\"1.0\"?>\n<root>\n  <a>\n    <b/>\n    <c>x</c>\n  </a>\n"
        + "  <!-- one\n  two\n  three -->\n</root>\n"
    let found = fold(text, FoldRegions.computeXML)
    #expect(found.map(\.startLine) == [1, 2, 6])
    #expect(found.map(\.endLine) == [9, 5, 8])
    let lonely = "<a>\n  <b>t</b>\n</a>\n"
    #expect(fold(lonely, FoldRegions.computeXML).map(\.startLine) == [0], "the one-line child is not a region")
    #expect(fold("<a>\n<b>\n</a>\n", FoldRegions.computeXML).map(\.startLine) == [0], "a tag left open is dropped")
}

@Test
func yamlFoldsEverythingIndentedUnderALine() {
    let text = "name: a\nitems:\n  - one\n  - two:\n      x: 1\n      y: 2\n\n# c\nlast: z\n"
    let found = fold(text, FoldRegions.computeYAML)
    #expect(found.map(\.startLine) == [1, 3])
    #expect(found.map(\.endLine) == [6, 6], "blank lines and comments after a block are not part of it")
    #expect(hiddenText(text, found[1]) == "      x: 1\n      y: 2\n")
    #expect(
        fold("a:\n  b\n---\nc:\n  d\n", FoldRegions.computeYAML).map(\.startLine) == [0, 3],
        "a document marker closes blocks"
    )
    #expect(fold("a:\n  b\n  c\n---\nd:\n  e\n  f\n", FoldRegions.computeYAML).map(\.startLine) == [0, 4])
}

@Test
func tomlFoldsTablesUpToTheNextOne() {
    let text = "title = \"t\"\n[a]\nx = 1\ny = 2\n[[b]]\nz = 3\nw = 4\n"
    let found = fold(text, FoldRegions.computeSections)
    #expect(found.map(\.startLine) == [1, 4] && found.map(\.endLine) == [4, 7])
    #expect(hiddenText(text, found[1]) == "z = 3\nw = 4\n")
}

@Test
func shellFoldsIfLoopsCasesAndFunctionsButNotWordsInStrings() {
    let text = """
    #!/bin/sh
    f() {
      if [ -n "$a" ]; then
        echo "done"
        echo hi
      else
        :
      fi
    }
    for x in 1 2; do
      case $x in
        1) echo one ;;
        2) echo two ;;
      esac
    done
    echo "if fi"
    """
    let found = fold(text, FoldRegions.computeShell)
    #expect(found.map(\.startLine) == [1, 2, 9, 10])
    #expect(found.map(\.endLine) == [8, 7, 14, 13])
}
