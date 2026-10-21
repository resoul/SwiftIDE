import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

private func problems(_ text: String, _ language: DocumentLanguage = .json, file: String = "") -> [DocumentDiagnostic] {
    SyntaxChecks.check(Array(text.utf16), language: language, fileName: file)
}

/// The text the first problem points at (empty at the end of the document).
private func marked(_ text: String, _ language: DocumentLanguage = .json) -> String? {
    guard let first = problems(text, language).first else { return nil }

    return (text as NSString).substring(with: NSRange(location: first.range.location, length: first.range.length))
}

@Test
func validJSONHasNoProblemsAndWhiteSpaceOnlyIsLeftAlone() {
    let text = "{\n  \"a\": [1, -2.5e+3, true, false, null, \"x\\n\\u00e9\\\"\"],\n  \"o\": {}, \"e\": []\n}\n"
    #expect(problems(text).isEmpty)
    #expect(problems("[]").isEmpty && problems("0").isEmpty && problems("\"s\"").isEmpty && problems("null").isEmpty)
    #expect(problems("  \n").isEmpty && problems("").isEmpty)
}

@Test
func jsonErrorsPointAtTheFirstMistake() {
    #expect(marked("{\"a\": 1,}") == ",")
    #expect(problems("{\"a\": 1,}").first?.message == "A comma cannot come before the closing '}'")
    #expect(marked("[1, 2,]") == ",")
    #expect(marked("{\"a\" 1}") == "1")
    #expect(marked("{a: 1}") == "a")
    #expect(marked("[1 2]") == "2")
    #expect(marked("{\"a\": 01}") == "0")
    #expect(marked("[1.]") == "1")
    #expect(marked("[tru]") == "t")
    #expect(marked("[1e]") == "1")
    #expect(marked("{\"a\": \"x\ny\"}") == "\n")
    #expect(marked("[\"\\q\"]") == "\\q")
    #expect(marked("[\"\\u12\"]") == "\\u")
    #expect(marked("[\"open") == "\"")
    #expect(marked("[1] 2") == "2")
    #expect(marked("{\"a\": 1") == "", "the document ends first: an empty range at the end")
    #expect(problems("{\"a\": 1").first?.range == UTF16TextRange(location: 7, length: 0))
}

@Test
func onlyTheFirstJSONErrorIsReportedAndCommentsAreAWarning() {
    #expect(problems("[1 2 3 4]").count == 1)
    let commented = problems("// settings\n{\"a\": 1 /* x */}\n")
    #expect(commented.map(\.severity) == [.warning] && commented[0].message == "Comments are not allowed in JSON")
    #expect(commented[0].range == UTF16TextRange(location: 0, length: 2))
    #expect(problems("/* open").first?.message == "Unterminated comment")
    #expect(problems(String(repeating: "[", count: 600)).first?.message == "Nested too deeply")
}

@Test
func xmlErrorsAreFoundWithAPlaceAndTheRightWords() {
    #expect(problems("<a><b></b></a>", .xml).isEmpty)
    #expect(problems("<a x=\"1\" y='2'>t &amp; &#65; &#x41;<!-- c --><![CDATA[ & < ]]><?pi x?><b/></a>", .xml).isEmpty)
    let mismatch = problems("<a>\n<b>\n</a>\n", .xml)
    #expect(mismatch.count == 1 && mismatch[0].message == "The closing tag </a> does not match <b>")
    #expect(mismatch[0].range == UTF16TextRange(location: 10, length: 1), "on the name in the closing tag")
    #expect(problems("<a><b></b>", .xml).first?.message == "The tag <a> is never closed")
    #expect(problems("<a><b></b>", .xml).first?.range == UTF16TextRange(location: 0, length: 2))
    #expect(problems("<a x=1/>", .xml).first?.message == "The value of x must be in quotes")
    #expect(problems("<a x/>", .xml).first?.message == "The attribute x has no value; write x=\"…\"")
    #expect(problems("<a x=\"1\" x=\"2\"/>", .xml).first?.message == "The attribute x is given twice")
    #expect(problems("<a x=\"1/>", .xml).first?.message == "This attribute value is never closed")
    #expect(problems("<a>1 < 2</a>", .xml).first?.message == "A '<' must start a tag, or be written as &lt;")
    #expect(problems("<a>fish & chips</a>", .xml).first?
        .message == "An '&' must be written as &amp; or start an entity such as &lt;")
    #expect(problems("<a><!-- open</a>", .xml).first?.message == "This comment is never closed")
    #expect(problems("</a>", .xml).first?.message == "There is no open tag for </a>")
    #expect(problems("plain text", .xml).isEmpty || problems("plain text", .xml).first != nil)
}

@Test
func aPropertyListMustBeOneToo() {
    let good = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>A</key><string>b</string></dict></plist>"
    #expect(problems(good, .xml, file: "Info.plist").isEmpty)
    let bad = "<plist version=\"1.0\"><dict><key>A</key></dict></plist>"
    let found = problems(bad, .xml, file: "Info.plist")
    #expect(found.count == 1 && found[0].source == "plist" && found[0].message.hasPrefix("Not a valid property list"))
    #expect((bad as NSString).substring(with: NSRange(
        location: found[0].range.location,
        length: found[0].range.length
    )) == "<plist")
}

@Test
func otherLanguagesAreNotChecked() {
    #expect(!SyntaxChecks.supports(.yaml) && !SyntaxChecks.supports(.swift) && SyntaxChecks.supports(.json))
    #expect(problems("a: [", .yaml).isEmpty)
}

// MARK: Formatting

@Test
func jsonIsReindentedKeepingKeyOrderAndNumbersAsWritten() throws {
    let input = "{\"b\":1.50,\"a\":[1,2,{\"x\":null}],\"e\":{},\"l\":[ ],\"s\":\"a, b: {c}\"}"
    let expected = """
    {
      "b": 1.50,
      "a": [
        1,
        2,
        {
          "x": null
        }
      ],
      "e": {},
      "l": [],
      "s": "a, b: {c}"
    }

    """
    #expect(try DocumentFormatting.format(input, language: .json) == expected)
    #expect(try DocumentFormatting.format(expected, language: .json) == expected, "formatting twice changes nothing")
    #expect(try DocumentFormatting.format("[]", language: .json) == "[]\n")
    #expect(try DocumentFormatting.format("  \"x\"  ", language: .json) == "\"x\"\n")
}

@Test
func formattingRefusesWhatItCannotReadOrWouldLose() {
    #expect(throws: FormattingError.self) { try DocumentFormatting.format("{\"a\": }", language: .json) }
    #expect(throws: FormattingError.self) { try DocumentFormatting.format("{\"a\": 1 // note\n}", language: .json) }
    #expect(throws: FormattingError.self) { try DocumentFormatting.format("<a><b></a>", language: .xml) }
    #expect(throws: FormattingError.self) { try DocumentFormatting.format("a: 1", language: .yaml) }
    #expect(DocumentFormatting.supports(.json) && DocumentFormatting.supports(.xml) && !DocumentFormatting
        .supports(.swift))
}

@Test
func xmlIsReindentedAndItsContentIsKept() throws {
    let input = "<root><a id=\"1\"><b>text &amp; more</b><c/></a><!-- note --></root>"
    let output = try DocumentFormatting.format(input, language: .xml)
    #expect(output.contains("<a id=\"1\">") && output.contains("<b>text &amp; more</b>") && output.contains("<c/>"))
    #expect(output.contains("<!-- note -->") && output.hasSuffix("</root>\n"))
    #expect(output.split(separator: "\n").contains { $0.hasPrefix("    <a") }, "children are indented")
    #expect(try DocumentFormatting.format(output, language: .xml) == output, "formatting twice changes nothing")
    #expect(!output.contains("<?xml"), "no declaration is added where the file had none")
    let withDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        + "<plist version=\"1.0\"><dict><key>A</key><true/></dict></plist>"
    let plist = try DocumentFormatting.format(withDeclaration, language: .xml)
    #expect(plist.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n") && plist.contains("<!DOCTYPE plist"))
    #expect(plist.contains("<true/>") && !plist.contains("standalone"))
    #expect(try DocumentFormatting.format(plist, language: .xml) == plist)
}

// MARK: The minimal edit, and checking a document as it is edited

@Test
func theMinimalEditIsTheMiddleThatDiffers() {
    #expect(DocumentFormatting.minimalEdit(from: "same", to: "same") == nil)
    let edit = DocumentFormatting.minimalEdit(from: "{\"a\":1}", to: "{\n  \"a\": 1\n}")
    #expect(edit?.range == UTF16TextRange(location: 1, length: 5) && edit?.replacement == "\n  \"a\": 1\n")
    #expect(DocumentFormatting.minimalEdit(from: "ab", to: "abc") == DocumentEdit(
        range: UTF16TextRange(location: 2, length: 0),
        replacement: "c"
    ))
    #expect(DocumentFormatting.minimalEdit(from: "abc", to: "") == DocumentEdit(
        range: UTF16TextRange(location: 0, length: 3),
        replacement: ""
    ))
    let emoji = DocumentFormatting.minimalEdit(from: "x😀y", to: "x😁y")
    #expect(
        emoji?.range == UTF16TextRange(location: 1, length: 2) && emoji?.replacement == "😁",
        "a surrogate pair is not cut"
    )
}

@MainActor
private func wait(_ condition: () -> Bool) async {
    for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
}

@Test @MainActor
func aJSONDocumentIsCheckedNowAndAgainAfterEveryEditAndWhenItsLanguageChanges() async throws {
    let session = DocumentSession(path: "/w/a.json", backend: StringDocumentBackend(loadedText: "{\"a\": 1,}"))
    let languages = DocumentLanguages()
    let provider = BuiltInDiagnostics(languages: languages, delay: .milliseconds(10))
    #expect(provider.supports(session))
    var told = 0
    provider.subscribeToDiagnostics(for: session) { told += 1 }
    _ = provider.diagnostics(for: session)
    await wait { provider.diagnostics(for: session) != nil }
    let first = try #require(provider.diagnostics(for: session))
    #expect(first.items.map(\.severity) == [.error] && first.version == 0 && first.isVerified)
    #expect(told >= 1)

    try session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 7, length: 1), replacement: "")],
        expectedVersion: session.version
    )
    await wait { provider.diagnostics(for: session)?.version == 1 }
    #expect(provider.diagnostics(for: session)?.items.isEmpty == true && provider.diagnostics(for: session)?
        .version == 1)

    languages.selector(for: session).setOverride(.plainText)
    await wait { provider.diagnostics(for: session) == nil }
    #expect(!provider.supports(session) && provider.diagnostics(for: session) == nil)
    languages.selector(for: session).setOverride(nil)
    await wait { provider.diagnostics(for: session) != nil }
    #expect(provider.diagnostics(for: session) != nil)
    provider.forget(session)
}

@Test @MainActor
func otherLanguagesAndForgottenDocumentsGetNoReport() async {
    let session = DocumentSession(path: "/w/a.swift", backend: StringDocumentBackend(loadedText: "let x = "))
    let provider = BuiltInDiagnostics(languages: DocumentLanguages(), delay: .milliseconds(10))
    #expect(!provider.supports(session) && provider.diagnostics(for: session) == nil)
    let json = DocumentSession(path: "/w/b.json", backend: StringDocumentBackend(loadedText: "[1,"))
    let id = provider.subscribeToDiagnostics(for: json) {}
    provider.unsubscribeFromDiagnostics(id)
    provider.forget(json)
    provider.forget(json)
}
