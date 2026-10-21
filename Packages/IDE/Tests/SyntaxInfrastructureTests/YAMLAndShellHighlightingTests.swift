import Foundation
import IDEApplication
import IDEDomain
import Testing
@testable import SyntaxInfrastructure

// YAML and shell are coloured from the pinned Tree-sitter grammars (tree-sitter-yaml 0.7.2,
// tree-sitter-bash 0.25.1) and our own queries.

private final class Run: @unchecked Sendable {
    let highlighter: TreeSitterHighlighter
    private let lock = NSLock()
    private var results: [HighlightResult] = []
    private var consumed = 0

    init(_ language: DocumentLanguage) throws {
        highlighter = try TreeSitterHighlighter(language: language)
        highlighter.connect { [unowned self] result in lock.withLock { results.append(result) } }
    }

    func spans(of text: String) async -> [HighlightSpan] {
        let units = Array(text.utf16)
        highlighter.reset(text: [units], version: 0)
        highlighter.requestHighlights(in: 0..<units.count, version: 0)
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let found: HighlightResult? = lock.withLock {
                guard consumed < results.count else { return nil }

                consumed += 1

                return results[consumed - 1]
            }
            if let found { return found.spans }

            try? await Task.sleep(for: .milliseconds(5))
        }

        return []
    }
}

private func kind(of token: String, in text: String, spans: [HighlightSpan], occurrence: Int = 1) -> HighlightKind? {
    var from = text.startIndex
    var found: Range<String.Index>?
    for _ in 0..<occurrence {
        guard let range = text.range(of: token, range: from..<text.endIndex) else { return nil }

        found = range
        from = range.upperBound
    }
    guard let range = found else { return nil }

    let start = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
    let kinds = (start..<(start + token.utf16.count)).map { unit in
        spans.first { $0.location <= unit && unit < $0.end }?.kind
    }

    return Set(kinds.map { $0.map { String(describing: $0) } ?? "none" }).count == 1 ? kinds.first ?? nil : nil
}

@Test
func yamlKeysScalarsAnchorsTagsAndBlockScalarsAreColoured() async throws {
    let text = """
    # comment
    name: demo
    count: 12
    ratio: 1.5
    on: true
    gone: null
    list:
      - one
      - "q\\n"
      - key: &anchor value
        other: *anchor
    text: |
      body line
    tagged: !!str 5
    """
    let spans = try await Run(.yaml).spans(of: text)

    func k(_ token: String, _ n: Int = 1) -> HighlightKind? { kind(of: token, in: text, spans: spans, occurrence: n) }

    #expect(k("# comment") == .comment)
    #expect(k("name") == .property && k("list") == .property && k("text") == .property)
    #expect(k("12") == .number && k("1.5") == .number)
    #expect(k("true") == .constant && k("null") == .constant)
    #expect(k("demo") == nil, "a plain string value is not coloured")
    #expect(k("anchor", 1) == .label && k("anchor", 2) == .label)
    #expect(k("!!str") == .type)
    #expect(k("body line") == .string)
}

@Test
func shellKeywordsBuiltinsVariablesStringsAndFlagsAreColoured() async throws {
    let text = "#!/bin/bash\n# note\nset -eu\nNAME=\"hi $USER\"\n"
        + "if [ -n \"$NAME\" ]; then echo ${NAME} $(date) 'raw'; fi\n"
        + "for f in *.txt; do ls -l \"$f\" | wc; done\n"
    let spans = try await Run(.shell).spans(of: text)

    func k(_ token: String, _ n: Int = 1) -> HighlightKind? { kind(of: token, in: text, spans: spans, occurrence: n) }

    #expect(k("#!/bin/bash") == .attribute && k("# note") == .comment)
    #expect(k("set") == .builtin && k("echo") == .builtin && k("ls") == .function)
    #expect(k("-eu") == .label && k("-l") == .label)
    #expect(k("if") == .keyword && k("then") == .keyword && k("fi") == .keyword)
    #expect(k("for") == .keyword && k("do") == .keyword && k("done") == .keyword)
    #expect(k("NAME", 1) == .property)
    #expect(k("${NAME}") == .property && k("$(date)") == .property)
    #expect(k("'raw'") == .string && k("|") == .operator)
}

@Test
func aHashInsideAShellWordIsNotAComment() async throws {
    let text = "echo a#b # real\n"
    let spans = try await Run(.shell).spans(of: text)
    #expect(kind(of: "a#b", in: text, spans: spans) == nil)
    #expect(kind(of: "# real", in: text, spans: spans) == .comment)
}

@Test
func yamlAndShellHighlightersAreMadeByTheFactory() throws {
    #expect(SyntaxHighlighters.make(for: .yaml) is TreeSitterHighlighter)
    #expect(SyntaxHighlighters.make(for: .shell) is TreeSitterHighlighter)
    #expect(TreeSitterHighlighter.supportedLanguages.isSuperset(of: [.yaml, .shell]))
}
