import Foundation
import IDEApplication
import IDEDomain
import SyntaxInfrastructure
import Testing

// The colours of C, C++ and Objective-C, from the pinned Tree-sitter grammars and our own queries
// (TK-016). They are checked on small texts: what is a keyword, what is a type, what is a call.

private final class Run: @unchecked Sendable {
    let highlighter: TreeSitterHighlighter
    private let lock = NSLock()
    private var results: [HighlightResult] = []
    private var consumed = 0

    init(_ language: DocumentLanguage) throws {
        highlighter = try TreeSitterHighlighter(language: language)
        highlighter.connect { [unowned self] result in lock.withLock { results.append(result) } }
    }

    func next() async -> HighlightResult? {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let found: HighlightResult? = lock.withLock {
                guard consumed < results.count else { return nil }

                consumed += 1

                return results[consumed - 1]
            }
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return nil
    }

    func spans(of text: String, version: UInt64 = 0) async -> [HighlightSpan] {
        let units = Array(text.utf16)
        highlighter.reset(text: [units], version: version)
        highlighter.requestHighlights(in: 0..<units.count, version: version)

        return await next()?.spans ?? []
    }
}

/// The kind painted on the first occurrence of `token` in `text`, if the whole token has one kind.
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
    let length = token.utf16.count
    let kinds = (start..<(start + length)).map { unit in spans.first { $0.location <= unit && unit < $0.end }?.kind }

    return Set(kinds.map { $0.map { String(describing: $0) } ?? "none" }).count == 1 ? kinds.first ?? nil : nil
}

private func expect(_ short: [(String, HighlightKind?)] = [], also long: [(String, HighlightKind?, Int)] = [], in text: String, language: DocumentLanguage, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let run = try Run(language)
    let spans = await run.spans(of: text)
    #expect(!spans.isEmpty, "\(language) gave no colours", sourceLocation: sourceLocation)
    let pairs = short.map { ($0.0, $0.1, 1) } + long
    for (token, expected, occurrence) in pairs {
        #expect(kind(of: token, in: text, spans: spans, occurrence: occurrence) == expected, "\(token) in \(language)", sourceLocation: sourceLocation)
    }
}

// MARK: Which languages

@Test
func theThreeLanguagesWithAGrammarAreMadeAndTheOthersAreRefused() throws {
    #expect(TreeSitterHighlighter.supportedLanguages == [.swift, .c, .cpp, .objectiveC])
    for language in TreeSitterHighlighter.supportedLanguages { _ = try TreeSitterHighlighter(language: language).language }
    for language in [DocumentLanguage.objectiveCPP, .plainText] {
        #expect(throws: SyntaxInfrastructureError.self) { _ = try TreeSitterHighlighter(language: language) }
    }
}

// MARK: C

private let cText = """
#include <stdio.h>
#define MAX(a, b) ((a) > (b) ? (a) : (b))
struct Point { int x; unsigned long y; };
// a note
static int add(int left, char *name) {
    /* block */
    struct Point p = { 1, 2 };
    printf("hi\\n %d", p.x + 0x1F);
    char c = 'q';
    if (name == NULL) goto done;
done:
    return left->count;
}
"""

@Test
func cSourceIsColouredByWhatItIs() async throws {
    try await expect([
        ("#include", .attribute),
        ("<stdio.h>", .string),
        ("#define", .attribute),
        ("MAX", .attribute),
        ("struct", .keyword),
        ("static", .keyword),
        ("return", .keyword),
        ("goto", .keyword),
        ("if", .keyword),
        ("int", .type),
        ("char", .type),
        ("Point", .type),
        ("// a note", .comment),
        ("/* block */", .comment),
        ("add", .function),
        ("printf", .function),
        ("left", .parameter),
        ("\"hi", .string),
        ("\\n", .escape),
        ("0x1F", .number),
        ("'q'", .string),
        ("NULL", .constant),
        ("done:", nil),
        ("->", .operator),
        ("==", .operator),
        ("count", .property),
    ], in: cText, language: .c)
}

// MARK: C++

private let cppText = """
#include <vector>
namespace shapes {
template <typename T>
class Box : public Base {
public:
    virtual void grow() const override;
    T *item = nullptr;
};
}
auto lambda = [](int x) { return x * 2; };
std::string raw = R"(a "raw" text)";
void run() { shapes::build(); this->value = 1; }
"""

@Test
func cPlusPlusSourceIsColouredByWhatItIs() async throws {
    try await expect([
        ("#include", .attribute),
        ("namespace", .keyword),
        ("template", .keyword),
        ("typename", .keyword),
        ("class", .keyword),
        ("public", .keyword),
        ("virtual", .keyword),
        ("override", .keyword),
        ("const", .keyword),
        ("void", .type),
        ("int", .type),
        ("Box", .type),
        ("Base", .type),
        ("nullptr", .constant),
        ("auto", .keyword),
        ("return", .keyword),
        ("R\"(a \"raw\" text)\"", .string),
        ("build", .function),
        ("run", .function),
        ("this", .builtin),
    ], in: cppText, language: .cpp)
}

// MARK: Objective-C

private let objcText = """
#import <Foundation/Foundation.h>
@interface Foo : NSObject <Bar>
@property (nonatomic, copy) NSString *name;
- (void)doIt:(int)count with:(id)other;
@end
@implementation Foo
- (void)doIt:(int)count with:(id)other {
    NSLog(@"hi %d", count);
    [self reload:@1];
    BOOL ok = YES;
}
@end
"""

@Test
func objectiveCSourceIsColouredByWhatItIs() async throws {
    try await expect([
        ("#import", .attribute),
        ("@interface", .keyword),
        ("@property", .keyword),
        ("@end", .keyword),
        ("@implementation", .keyword),
        ("nonatomic", .keyword),
        ("void", .type),
        ("id", .type),
        ("BOOL", .type),
        ("NSString", .type),
        ("NSLog", .function),
        ("@\"hi %d\"", .string),
        ("reload", .function),
        ("self", .builtin),
    ], also: [("int", .type, 2), ("count", .parameter, 1), ("doIt", .function, 1), ("with", .function, 1)], in: objcText, language: .objectiveC)
}

// MARK: A block comment that is never closed

@Test
func anUnclosedBlockCommentColoursTheRestAsCommentInEveryCLanguage() async throws {
    for language in [DocumentLanguage.c, .cpp, .objectiveC] {
        let text = "int a = 1;\n/* never closed\nint b = \"s\" + 2;\nreturn;\n"
        let run = try Run(language)
        let spans = await run.spans(of: text)
        #expect(kind(of: "int", in: text, spans: spans) == .type, "code before it keeps its colours: \(language)")
        let open = (text as NSString).range(of: "/*").location
        let rest = spans.filter { $0.location >= open }
        #expect(rest.allSatisfy { $0.kind == .comment }, "\(language): \(rest)")
        #expect(rest.reduce(0) { $0 + $1.length } == (text as NSString).length - open, "\(language): the whole rest is comment")
    }
}

@Test
func aSlashStarInsideAStringOrALineCommentOpensNothing() async throws {
    for language in [DocumentLanguage.c, .cpp, .objectiveC] {
        let text = "const char *s = \"a /* b\";\n// c /* d\nint n = 1;\n"
        let run = try Run(language)
        let spans = await run.spans(of: text)
        #expect(kind(of: "int", in: text, spans: spans, occurrence: 1) == .type, "\(language): code after them is coloured as code")
        #expect(kind(of: "1", in: text, spans: spans, occurrence: 1) == .number, "\(language)")
        #expect(kind(of: "// c /* d", in: text, spans: spans) == .comment, "\(language)")
    }
}

@Test
func aClosedBlockCommentAndAnIncludePathWithSlashStarAreNotUnclosed() async throws {
    for language in [DocumentLanguage.c, .cpp, .objectiveC] {
        let text = "/* x */ int a = 1;\n#include <a/*b>\nint b = 2;\n"
        let run = try Run(language)
        let spans = await run.spans(of: text)
        #expect(kind(of: "/* x */", in: text, spans: spans) == .comment, "\(language)")
        let tail = (text as NSString).range(of: "int b").location
        #expect(spans.contains { $0.location >= tail && $0.kind != .comment }, "\(language): the last line is code")
    }
}

// MARK: Typing

@Test
func typingASlashStarOpensACommentOverTheRestAndClosingItGivesTheColoursBack() async throws {
    let run = try Run(.c)
    var units = Array("int a = 1;\nint b = 2;\nint c = 3;\n".utf16)
    _ = await run.spans(of: String(decoding: units, as: UTF16.self))
    func edit(_ range: UTF16TextRange, _ text: String, version: UInt64) async -> [HighlightSpan] {
        let changes = DocumentChangeSet(documentID: DocumentID(),
                                        oldVersion: version - 1,
                                        newVersion: version,
                                        edits: [DocumentEdit(range: range, replacement: text)],
                                        origin: .typing)
        units.replaceSubrange(range.location..<(range.location + range.length), with: Array(text.utf16))
        run.highlighter.edit(changes)
        run.highlighter.requestHighlights(in: 0..<units.count, version: version)

        return await run.next()?.spans ?? []
    }
    let opened = await edit(UTF16TextRange(location: 11, length: 0), "/*", version: 1)
    #expect(opened.filter { $0.location >= 11 }.allSatisfy { $0.kind == .comment } && !opened.isEmpty)
    let closed = await edit(UTF16TextRange(location: 11 + 2 + 10, length: 0), "*/", version: 2)
    let text = String(decoding: units, as: UTF16.self)
    #expect(kind(of: "int", in: text, spans: closed, occurrence: 3) == .type, "after the comment ends the code is code again: \(text.debugDescription)")
}

// MARK: Real headers

private let sdk: String? = {
    let finder = Process()
    finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    finder.arguments = ["--show-sdk-path"]
    let pipe = Pipe()
    finder.standardOutput = pipe
    finder.standardError = FileHandle.nullDevice
    guard (try? finder.run()) != nil else { return nil }

    finder.waitUntilExit()
    guard finder.terminationStatus == 0 else { return nil }

    let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

    return FileManager.default.fileExists(atPath: path) ? path : nil
}()

@Test(.enabled(if: sdk != nil), arguments: [
    ("/usr/include/sys/stat.h", DocumentLanguage.c),
    ("/usr/include/c++/v1/__algorithm/sort.h", .cpp),
    ("/System/Library/Frameworks/Foundation.framework/Headers/NSArray.h", .objectiveC),
    // The Objective-C grammar reads this one as a single error (macro-wrapped enums, `NS_OPTIONS`);
    // the colours that survive are only comments and tokens, but nothing breaks.
    ("/System/Library/Frameworks/Foundation.framework/Headers/NSURL.h", .objectiveC),
] as [(String, DocumentLanguage)])
func headersOfTheSDKAreColouredInTimeAndAreConsistent(path: String, language: DocumentLanguage) async throws {
    let text = try String(contentsOfFile: sdk! + path, encoding: .utf8)
    let run = try Run(language)
    let began = ContinuousClock.now
    let spans = await run.spans(of: text)
    let took = ContinuousClock.now - began
    let length = text.utf16.count

    #expect(took < .seconds(10), "\(path): \(took)")
    #expect(!spans.isEmpty)
    var previousEnd = 0
    for span in spans {
        #expect(span.location >= previousEnd && span.length > 0 && span.end <= length, "\(path): span \(span) after \(previousEnd)")
        previousEnd = span.end
    }
    let kinds = Set(spans.map(\.kind))
    let coloured = spans.reduce(0) { $0 + $1.length }
    if path.hasSuffix("NSURL.h") {
        #expect(kinds.contains(.comment), "\(path): \(kinds)")
    } else {
        #expect(kinds.isSuperset(of: [.comment, .keyword, .type, .attribute]), "\(path): \(kinds)")
        #expect(coloured * 10 > length, "\(path): under a tenth of the text is coloured (\(coloured) of \(length))")
    }
}
