import Foundation
import IDEApplication
import IDEDomain
import Testing
import SyntaxInfrastructure

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private let sample = """
import Foundation

/// A greeting.
struct Greeter {
    let name: String
    var count = 3

    func greet(times: Int) -> String {
        // say hello
        let line = "Hello, \\(name)!\\n"
        if times > 0 && count != 1 {
            return String(repeating: line, count: times)
        }
        return line
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var items: [Int] = [1, 2, 3]
    func total() -> Int { items.reduce(0, +) }
}

"""

/// A highlighter and what it has answered so far, driven the way the editor drives it.
private final class Rig: @unchecked Sendable {
    let highlighter: TreeSitterHighlighter
    private let lock = NSLock()
    private var received: [HighlightResult] = []
    private var consumed = 0

    init(connected: Bool = true) throws {
        highlighter = try TreeSitterHighlighter()
        if connected { connect() }
    }

    func connect() {
        highlighter.connect { [unowned self] result in
            lock.withLock { received.append(result) }
        }
    }

    /// The next result nobody has looked at yet, or nil if none comes in time.
    func next(within seconds: Double = 20) async -> HighlightResult? {
        // A clock that stops while the machine sleeps: with the wall clock, a laptop that slept in
        // the middle of a run found every deadline already passed and failed tests that were fine.
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            let found: HighlightResult? = lock.withLock {
                guard consumed < received.count else { return nil }
                consumed += 1
                return received[consumed - 1]
            }
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func highlights(of units: [UInt16], version: UInt64 = 0) async -> HighlightResult? {
        highlighter.reset(text: [units], version: version)
        highlighter.requestHighlights(in: 0..<units.count, version: version)
        return await next()
    }
}

private func described(_ result: HighlightResult, in units: [UInt16]) -> [String] {
    result.spans.map { span in
        "\(String(decoding: units[span.location..<span.end], as: UTF16.self)) \(span.kind)"
    }
}

@Test
func sourceIsColouredByKind() async throws {
    let rig = try Rig()
    let units = Array(sample.utf16)
    let result = try #require(await rig.highlights(of: units))
    let spans = described(result, in: units)
    #expect(spans.contains("import keyword"))
    #expect(spans.contains("struct keyword"))
    #expect(spans.contains("1 number"))
    #expect(spans.contains { $0.hasSuffix(" comment") && $0.hasPrefix("// say hello") })
    #expect(spans.contains { $0.hasSuffix(" documentation") && $0.hasPrefix("/// A greeting.") })
    #expect(spans.contains("String type"))
    #expect(spans.contains("\\n escape"))
    #expect(spans.contains("@MainActor attribute") || spans.contains("MainActor attribute") || spans.contains("@ attribute"))
    #expect(result.documentLength == units.count)
    #expect(result.window == 0..<units.count)
    // Spans are sorted, separate, and inside the window.
    var previousEnd = 0
    for span in result.spans {
        #expect(span.length > 0 && span.location >= previousEnd && span.end <= units.count)
        previousEnd = span.end
    }
}

@Test
func onlyTheAskedWindowIsDescribed() async throws {
    let rig = try Rig()
    let units = Array(sample.utf16)
    rig.highlighter.reset(text: [units], version: 4)
    rig.highlighter.requestHighlights(in: 40..<120, version: 4)
    let result = try #require(await rig.next())
    #expect(result.window == 40..<120)
    #expect(!result.spans.isEmpty)
    #expect(result.spans.allSatisfy { $0.location >= 40 && $0.end <= 120 })

    rig.highlighter.requestHighlights(in: (units.count - 10)..<(units.count + 500), version: 4)
    let tail = try #require(await rig.next())
    #expect(tail.window.upperBound == units.count, "a window past the end is cut to the document")
}

@Test
func aRequestForAnotherVersionGetsNoAnswer() async throws {
    let rig = try Rig()
    let units = Array(sample.utf16)
    rig.highlighter.reset(text: [units], version: 7)
    rig.highlighter.requestHighlights(in: 0..<100, version: 6)
    #expect(await rig.next(within: 0.4) == nil)
    rig.highlighter.requestHighlights(in: 0..<100, version: 7)
    #expect(await rig.next()?.version == 7)
}

@Test
func anEditThatDoesNotFitSilencesTheHighlighterUntilItIsReset() async throws {
    let rig = try Rig()
    let units = Array(sample.utf16)
    rig.highlighter.reset(text: [units], version: 0)
    rig.highlighter.edit(DocumentChangeSet(
        documentID: DocumentID(), oldVersion: 0, newVersion: 1,
        edits: [DocumentEdit(range: UTF16TextRange(location: units.count + 50, length: 3), replacement: "x")],
        origin: .typing
    ))
    rig.highlighter.requestHighlights(in: 0..<100, version: 1)
    #expect(await rig.next(within: 0.4) == nil, "its copy of the text cannot be trusted")
    let result = try #require(await rig.highlights(of: units, version: 2))
    #expect(result.version == 2)
}

/// Applies a change set to plain text, the way the editor's storage would.
private func apply(_ changes: DocumentChangeSet, to units: inout [UInt16]) {
    for edit in changes.edits {
        units.replaceSubrange(
            edit.range.location..<(edit.range.location + edit.range.length), with: Array(edit.replacement.utf16)
        )
    }
}

private let fragments = ["x", " ", "\n", "let ", "\"", "//", "{", "}", "(", ")", "😀", "\r\n", "1", ".", "func ", "\\(", "/*", "*/", "@", "if "]

@Test
func incrementalColoursEqualThoseOfAFreshParseAfterEveryEdit() async throws {
    var generator = SeededGenerator(state: 0x7EE5)
    let incremental = try Rig()
    let fresh = try Rig()
    var units = Array(sample.utf16)
    var version: UInt64 = 0
    incremental.highlighter.reset(text: [units], version: version)

    var mismatches: [String] = []
    for step in 0..<150 {
        let location = Int.random(in: 0...units.count, using: &generator)
        let length = Bool.random(using: &generator) ? 0 : Int.random(in: 0...min(6, units.count - location), using: &generator)
        let replacement = Bool.random(using: &generator) && length > 0 ? "" : fragments.randomElement(using: &generator)!
        let changes = DocumentChangeSet(
            documentID: DocumentID(), oldVersion: version, newVersion: version + 1,
            edits: [DocumentEdit(range: UTF16TextRange(location: location, length: length), replacement: replacement)],
            origin: .typing
        )
        apply(changes, to: &units)
        version += 1
        incremental.highlighter.edit(changes)
        incremental.highlighter.requestHighlights(in: 0..<units.count, version: version)
        let a = try #require(await incremental.next())
        let b = try #require(await fresh.highlights(of: units, version: version))
        #expect(a.version == version && a.documentLength == units.count)
        if a.spans != b.spans { mismatches.append("step \(step): edit \(location)+\(length) -> \(replacement.debugDescription)") }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) of 150 steps differ from a fresh parse: \(mismatches.prefix(5))")
}

@Test
func severalEditsInOneChangeSetAreAppliedLikeTheStorageDoes() async throws {
    let incremental = try Rig(), fresh = try Rig()
    var units = Array(sample.utf16)
    // A first parse, so that the edits below go to a tree that exists.
    _ = try #require(await incremental.highlights(of: units))
    // Last position first, in the coordinates of the text before the change.
    let changes = DocumentChangeSet(
        documentID: DocumentID(), oldVersion: 0, newVersion: 1,
        edits: [
            DocumentEdit(range: UTF16TextRange(location: 200, length: 5), replacement: "0xFF"),
            DocumentEdit(range: UTF16TextRange(location: 100, length: 0), replacement: "// note\n"),
            DocumentEdit(range: UTF16TextRange(location: 0, length: 6), replacement: "@testable import")
        ],
        origin: .command
    )
    apply(changes, to: &units)
    incremental.highlighter.edit(changes)
    incremental.highlighter.requestHighlights(in: 0..<units.count, version: 1)
    let a = try #require(await incremental.next())
    let b = try #require(await fresh.highlights(of: units, version: 1))
    #expect(a.spans == b.spans)
}

@Test
func aWindowBeyondTheEndOfTheTextIsAnsweredWithNothingInsteadOfCrashing() async throws {
    let rig = try Rig()
    let units = Array("let a = 1\n".utf16)
    rig.highlighter.reset(text: [units], version: 0)
    rig.highlighter.requestHighlights(in: 500..<900, version: 0)
    let beyond = try #require(await rig.next())
    #expect(beyond.window.upperBound <= units.count && beyond.window.lowerBound <= beyond.window.upperBound)
    #expect(beyond.spans.isEmpty)

    rig.highlighter.requestHighlights(in: 4..<900, version: 0)
    let partly = try #require(await rig.next())
    #expect(partly.window == 4..<units.count)
}

@Test
func aShrunkenDocumentIsAnsweredForAWindowThatUsedToFit() async throws {
    let rig = try Rig()
    let units = Array(sample.utf16)
    var current = units
    rig.highlighter.reset(text: [units], version: 0)
    let cut = DocumentChangeSet(
        documentID: DocumentID(), oldVersion: 0, newVersion: 1,
        edits: [DocumentEdit(range: UTF16TextRange(location: 20, length: units.count - 20), replacement: "")],
        origin: .command
    )
    apply(cut, to: &current)
    rig.highlighter.edit(cut)
    rig.highlighter.requestHighlights(in: (units.count - 100)..<units.count, version: 1)
    let result = try #require(await rig.next())
    #expect(result.documentLength == current.count)
    #expect(result.window.upperBound <= current.count)
}

@Test
func aRequestSentRightAfterConnectingIsNeverLost() async throws {
    // The handler travels through the same queue as the requests. If it raced them (a separate task
    // setting it), a busy machine could drop the first answer. Rare on an idle one, so the machine
    // is kept busy here; this guards the ordering, it does not prove the race gone.
    let rigs = try (0..<12).map { _ in try Rig(connected: false) }
    let deadline = Date().addingTimeInterval(4)
    let hogs = (0..<(ProcessInfo.processInfo.activeProcessorCount * 2)).map { _ in
        Task.detached(priority: .high) { while Date() < deadline { _ = (0..<1000).reduce(0, +) } }
    }
    for rig in rigs {
        rig.connect()
        rig.highlighter.reset(text: [Array("let a = 1\n".utf16)], version: 0)
        rig.highlighter.requestHighlights(in: 0..<10, version: 0)
    }
    for (index, rig) in rigs.enumerated() {
        #expect(await rig.next(within: 30) != nil, "highlighter \(index) answered its first request")
    }
    for hog in hogs { await hog.value }
}

// MARK: A block comment that is never closed

/// The kinds of every unit of the text, from a result's spans.
private func kinds(_ result: HighlightResult, count: Int) -> [HighlightKind?] {
    var kinds = [HighlightKind?](repeating: nil, count: count)
    for span in result.spans { for index in span.location..<span.end { kinds[index] = span.kind } }
    return kinds
}

private func unitOffset(of marker: String, in text: String) -> Int {
    let range = text.range(of: marker)!
    return text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound.samePosition(in: text.utf16)!)
}

@Test
func aBlockCommentThatIsNeverClosedRunsToTheEndOfTheText() async throws {
    // Swift reads an unterminated /* to the end of the file; the grammar alone does not.
    let text = "let a = 1\n/* open\nlet b = 2\nlet c = \"x\" + 3\n"
    let units = Array(text.utf16)
    let start = unitOffset(of: "/*", in: text)
    let result = try #require(await Rig().highlights(of: units))
    let found = kinds(result, count: units.count)
    #expect(found[0..<3].allSatisfy { $0 == .keyword }, "code before the opener is coloured as code")
    #expect(found[start...].allSatisfy { $0 == .comment }, "everything from the opener on is comment")
}

@Test
func aWindowBelowAnUnclosedOpenerIsAllComment() async throws {
    let text = "/* open\n" + (1...50).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
    let units = Array(text.utf16)
    let rig = try Rig()
    rig.highlighter.reset(text: [units], version: 0)
    rig.highlighter.requestHighlights(in: 200..<400, version: 0)   // the opener is above this window
    let result = try #require(await rig.next())
    let found = kinds(result, count: units.count)
    #expect(found[200..<400].allSatisfy { $0 == .comment })
}

@Test
func slashStarInsideAStringOrALineCommentOpensNothing() async throws {
    let text = "let s = \"a /* b\"\n// c /* d\nlet n = 1\n"
    let units = Array(text.utf16)
    let result = try #require(await Rig().highlights(of: units))
    let found = kinds(result, count: units.count)
    let tail = unitOffset(of: "let n", in: text)
    #expect(found[tail..<(tail + 3)].allSatisfy { $0 == .keyword }, "the code after them is code")
    #expect(found[(units.count - 4)..<(units.count - 1)].contains(.number))
}

@Test
func aClosedCommentLeavesTheCodeAfterItAlone() async throws {
    let text = "/* x */ let a = 1\nlet b = 2\n"
    let units = Array(text.utf16)
    let result = try #require(await Rig().highlights(of: units))
    let found = kinds(result, count: units.count)
    let code = unitOffset(of: "let a", in: text)
    #expect(found[code..<(code + 3)].allSatisfy { $0 == .keyword })
}

@Test
func anOuterCommentThatIsNeverClosedSwallowsAClosedOneInsideIt() async throws {
    let text = "let a = 1\n/* outer /* inner */ let c = 2\nlet d = 3\n"
    let units = Array(text.utf16)
    let result = try #require(await Rig().highlights(of: units))
    let found = kinds(result, count: units.count)
    let start = unitOffset(of: "/* outer", in: text)
    #expect(found[start...].allSatisfy { $0 == .comment })
}

@Test
func closingTheCommentAgainGivesTheCodeBackItsColours() async throws {
    let rig = try Rig()
    var units = Array("let a = 1\n/* open\nlet b = 2\n".utf16)
    _ = try #require(await rig.highlights(of: units))
    let close = DocumentChangeSet(
        documentID: DocumentID(), oldVersion: 0, newVersion: 1,
        edits: [DocumentEdit(range: UTF16TextRange(location: units.count - 11, length: 0), replacement: "*/")],
        origin: .typing
    )
    // "/* open\nlet b = 2\n" with "*/" before the second line
    apply(close, to: &units)
    rig.highlighter.edit(close)
    rig.highlighter.requestHighlights(in: 0..<units.count, version: 1)
    let result = try #require(await rig.next())
    let text = String(decoding: units, as: UTF16.self)
    let code = unitOffset(of: "let b", in: text)
    let found = kinds(result, count: units.count)
    #expect(found[code..<(code + 3)].allSatisfy { $0 == .keyword }, "once the comment is closed, what follows is code")
}

@Test
func incrementalColoursStayEqualToAFreshParseWhenEditsAreAboutComments() async throws {
    // Edits that open, close and nest comments and strings: where the unclosed-comment rule acts.
    var generator = SeededGenerator(state: 0xC0DE)
    let incremental = try Rig(), fresh = try Rig()
    var units = Array(sample.utf16)
    var version: UInt64 = 0
    incremental.highlighter.reset(text: [units], version: version)
    let pieces = ["/*", "*/", "\"", "//", "\n", "x ", "/* a */", "\\(", "#\""]
    var mismatches: [String] = []
    for step in 0..<120 {
        let location = Int.random(in: 0...units.count, using: &generator)
        let length = Bool.random(using: &generator) ? 0 : Int.random(in: 0...min(4, units.count - location), using: &generator)
        let replacement = pieces.randomElement(using: &generator)!
        let changes = DocumentChangeSet(
            documentID: DocumentID(), oldVersion: version, newVersion: version + 1,
            edits: [DocumentEdit(range: UTF16TextRange(location: location, length: length), replacement: replacement)],
            origin: .typing
        )
        apply(changes, to: &units)
        version += 1
        incremental.highlighter.edit(changes)
        incremental.highlighter.requestHighlights(in: 0..<units.count, version: version)
        let a = try #require(await incremental.next())
        let b = try #require(await fresh.highlights(of: units, version: version))
        if a.spans != b.spans { mismatches.append("step \(step)") }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) of 120 steps differ: \(mismatches.prefix(5))")
}

// Where the unclosed-comment rule could be fooled: text that contains `/*` without opening a comment.

@Test
func slashStarInsideAMultilineStringOpensNothing() async throws {
    let text = "let s = \"\"\"\n/* not a comment\n\"\"\"\nlet n = 1\n"
    let units = Array(text.utf16)
    let result = try #require(await Rig().highlights(of: units))
    let found = kinds(result, count: units.count)
    let tail = unitOffset(of: "let n", in: text)
    #expect(found[tail..<(tail + 3)].allSatisfy { $0 == .keyword }, "the code after the string is code")
}

@Test
func aRegexLiteralWithAnEscapedSlashIsMisreadByTheGrammarButNeverMadeIntoAComment() async throws {
    // tree-sitter-swift 0.7.4 reads `/a\/b/` as a string followed by operators, so code after it
    // loses its colours even without a `/*` in it. That is the grammar's limit; what the
    // unclosed-comment rule must not do is turn the rest of the file into a comment because of it.
    for text in ["let r = /a\\/b/\nlet n = 1\n", "let r = /a\\/*b/\nlet n = 1\n"] {
        let units = Array(text.utf16)
        let result = try #require(await Rig().highlights(of: units))
        #expect(!result.spans.contains { $0.kind == .comment }, "no comment in \(text.debugDescription)")
    }
}

@Test
func slashStarInsideAnExtendedRegexLiteralOpensNothing() async throws {
    let text = "let r = #/a /* b/#\nlet n = 1\n"
    let units = Array(text.utf16)
    let result = try #require(await Rig().highlights(of: units))
    let found = kinds(result, count: units.count)
    let tail = unitOffset(of: "let n", in: text)
    #expect(found[tail..<(tail + 3)].allSatisfy { $0 == .keyword }, "the code after the regex is code")
}
