import Foundation
import IDEApplication
import IDEDomain
import Testing
@testable import SyntaxInfrastructure

/// The kind painted on the first occurrence of `token`, if all of it has one kind (nil if mixed or none).
private func kind(of token: String, in text: String, occurrence: Int = 1) -> HighlightKind? {
    let kinds = MarkdownColours.kinds(for: Array(text.utf16))
    var from = text.startIndex
    var found: Range<String.Index>?
    for _ in 0..<occurrence {
        guard let range = text.range(of: token, range: from..<text.endIndex) else { return nil }

        found = range
        from = range.upperBound
    }
    guard let range = found else { return nil }

    let start = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
    let values = Set(kinds[start..<(start + token.utf16.count)])

    return values.count == 1 ? HighlightKind(rawValue: values.first!) : nil
}

@Test
func headingsAreKeywordsAndASetextUnderlineColoursItsLineToo() {
    #expect(kind(of: "# Title", in: "# Title\ntext\n") == .keyword)
    #expect(kind(of: "### Third *level*", in: "### Third *level*\n") == .keyword)
    #expect(kind(of: "text", in: "# Title\ntext\n") == nil)
    let setext = "Heading\n=======\nbody\n"
    #expect(kind(of: "Heading", in: setext) == .keyword && kind(of: "=======", in: setext) == .keyword)
    #expect(kind(of: "body", in: setext) == nil)
    #expect(kind(of: "#tag", in: "#tag\n") == nil)
}

@Test
func emphasisCodeStrikeAndEscapesAreColouredAndCodeWinsOverEmphasis() {
    let text = "a **bold** and *italic* and _under_ and ~~gone~~ and `code *x*` and \\* here\n"
    #expect(kind(of: "**bold**", in: text) == .builtin)
    #expect(kind(of: "*italic*", in: text) == .builtin)
    #expect(kind(of: "_under_", in: text) == .builtin)
    #expect(kind(of: "~~gone~~", in: text) == .comment)
    #expect(kind(of: "`code *x*`", in: text) == .string, "the star inside code is not emphasis")
    #expect(kind(of: "\\*", in: text) == .escape)
    #expect(kind(of: "and", in: text) == nil)
    #expect(kind(of: "snake_case_name", in: "a snake_case_name b\n") == nil, "underscores inside a word are text")
    #expect(kind(of: "2 * 3 * 4", in: "2 * 3 * 4\n") == nil, "stars with spaces are not emphasis")
}

@Test
func linksImagesAndAddressesAreColouredByPart() {
    let text = "[the docs](https://example.com/docs) and ![alt](img.png) and [ref][1] and <https://a.b/c> and https://x.y/z.\n[1]: https://example.com\n"
    #expect(kind(of: "[the docs]", in: text) == .function)
    #expect(kind(of: "(https://example.com/docs)", in: text) == .constant)
    #expect(kind(of: "[alt]", in: text) == .function && kind(of: "(img.png)", in: text) == .constant)
    #expect(kind(of: "[ref]", in: text) == .function && kind(of: "[1]", in: text) == .constant)
    #expect(kind(of: "<https://a.b/c>", in: text) == .constant)
    #expect(kind(of: "https://x.y/z", in: text) == .constant)
    #expect(kind(of: "[1]: https://example.com", in: text) == .constant)
}

@Test
func fencedBlocksColourTheirLinesAsCodeWhateverTheyHold() {
    let text = "intro\n```swift\n# not a heading and **not bold**\nlet a = 1\n```\n**bold**\n"
    #expect(kind(of: "```swift", in: text) == nil, "the marker and the language differ")
    #expect(kind(of: "```", in: text) == .attribute)
    #expect(kind(of: "swift", in: text) == .label)
    #expect(kind(of: "# not a heading and **not bold**", in: text) == .string)
    #expect(kind(of: "let a = 1", in: text) == .string)
    #expect(kind(of: "**bold**", in: text) == .builtin, "after the closing fence it is text again")
    let open = "```\ncode to the end"
    #expect(kind(of: "code to the end", in: open) == .string)
}

@Test
func quotesListsTasksRulesTablesAndHTMLCommentsAreMarked() {
    let text = "> quoted *em*\n- item\n1. first\n- [x] done\n---\n| a | b |\n<!-- one\ntwo -->\nplain\n"
    #expect(kind(of: ">", in: text) == .operator && kind(of: "*em*", in: text) == .builtin)
    #expect(kind(of: "- ", in: text) == nil && kind(of: "-", in: text, occurrence: 1) == .operator)
    #expect(kind(of: "1.", in: text) == .operator)
    #expect(kind(of: "[x]", in: text) == .constant)
    #expect(kind(of: "---", in: text) == .operator)
    #expect(kind(of: "|", in: text) == .operator)
    #expect(kind(of: "<!-- one\ntwo -->", in: text) == .comment)
    #expect(kind(of: "plain", in: text) == nil)
    let inCode = "```\n<!-- not a comment -->\n```\n"
    #expect(kind(of: "<!-- not a comment -->", in: inCode) == .string)
}

@Test
func anEmptyDocumentAndWindowsAreHandled() {
    #expect(MarkdownColours.kinds(for: []).isEmpty)
    #expect(MarkdownColours.kinds(for: Array("\n\n".utf16)) == [0, 0])
}

// MARK: The highlighter

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HighlightResult] = []

    func add(_ result: HighlightResult) { lock.withLock { values.append(result) } }

    var all: [HighlightResult] { lock.withLock { values } }
}

private func waitForResult(_ results: Results, count: Int) async -> HighlightResult? {
    for _ in 0..<600 where results.all.count < count { try? await Task.sleep(for: .milliseconds(5)) }

    return results.all.count >= count ? results.all[count - 1] : nil
}

@Test
func theHighlighterAnswersForAWindowFollowsEditsAndDropsStaleRequests() async throws {
    let highlighter = MarkdownHighlighter()
    let results = Results()
    highlighter.connect { results.add($0) }
    let text = "# Title\nplain\n"
    let units = Array(text.utf16)
    highlighter.reset(text: [units], version: 1)
    highlighter.requestHighlights(in: 0..<units.count, version: 1)
    let first = try #require(await waitForResult(results, count: 1))
    #expect(first.version == 1 && first.documentLength == units.count)
    #expect(first.spans == [HighlightSpan(location: 0, length: 7, kind: .keyword)])

    let edit = DocumentEdit(range: UTF16TextRange(location: 8, length: 5), replacement: "`code`")
    highlighter.edit(DocumentChangeSet(
        documentID: DocumentID(),
        oldVersion: 1,
        newVersion: 2,
        edits: [edit],
        origin: .typing
    ))
    highlighter.requestHighlights(in: 8..<14, version: 2)
    let second = try #require(await waitForResult(results, count: 2))
    #expect(second.version == 2 && second.window == 8..<14)
    #expect(second.spans == [HighlightSpan(location: 8, length: 6, kind: .string)])

    highlighter.requestHighlights(in: 0..<5, version: 1)
    highlighter.requestHighlights(in: 0..<7, version: 2)
    let third = try #require(await waitForResult(results, count: 3))
    #expect(third.version == 2 && third.window == 0..<7, "the request for the old version got no answer")
    highlighter.stop()
}

@Test
func markdownHasColoursAndTheFactoryMakesItsHighlighter() {
    #expect(SyntaxHighlighters.supportedLanguages.contains(.markdown))
    #expect(SyntaxHighlighters.supportedLanguages.isSuperset(of: TreeSitterHighlighter.supportedLanguages))
    #expect(SyntaxHighlighters.make(for: .markdown) is MarkdownHighlighter)
    #expect(SyntaxHighlighters.make(for: .swift) is TreeSitterHighlighter)
    #expect(SyntaxHighlighters.make(for: .plainText) == nil)
    #expect(DocumentLanguage.guess(forPath: "/w/README.md").language == .markdown)
    #expect(DocumentLanguage.guess(forPath: "/w/a.MARKDOWN").language == .markdown)
    #expect(DocumentLanguage.markdown.supportsFolding && DocumentLanguage.markdown.lineCommentPrefix == nil)
}
