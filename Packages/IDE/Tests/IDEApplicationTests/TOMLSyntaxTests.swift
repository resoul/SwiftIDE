import Foundation
import IDEApplication
import Testing

private func parse(_ text: String) throws -> TOMLValue { try TOMLSyntax.parse(Array(text.utf16)) }

private func error(_ text: String) -> TOMLError? {
    do {
        _ = try parse(text)

        return nil
    } catch {
        return error as? TOMLError
    }
}

/// The text the error points at.
private func marked(_ text: String) -> String? {
    guard let found = error(text) else { return nil }

    return (text as NSString).substring(with: NSRange(location: found.location, length: found.length))
}

@Test
func aDocumentWithEveryKindOfValueIsRead() throws {
    let text = """
    # a comment
    title = "TOML \\u00e9"
    literal = 'C:\\path'
    multi = \"\"\"
    one \\
       two\"\"\"
    raw = '''
    raw "text"'''
    int = 1_000
    hex = 0xDEADbeef
    float = -3.14e+2
    inf = +inf
    on = true
    when = 1979-05-27T07:32:00Z
    day = 1979-05-27
    clock = 07:32:00.5
    spaced = 1979-05-27 07:32:00
    list = [ 1, 2,
      3, # trailing
    ]
    point = { x = 1, y = "two" }

    [owner]
    name = "A"
    dotted.key = 5

    [[products]]
    name = "x"

    [[products]]
    name = "y"
    """
    guard case .table(let root) = try parse(text) else {
        Issue.record("not a table")

        return
    }

    #expect(root["title"] == .string("TOML é") && root["literal"] == .string("C:\\path"))
    #expect(root["multi"] == .string("one two") && root["raw"] == .string("raw \"text\""))
    #expect(root["int"] == .integer("1_000") && root["float"] == .float("-3.14e+2") && root["inf"] == .float("+inf"))
    #expect(root["on"] == .boolean(true) && root["when"] == .dateTime("1979-05-27T07:32:00Z"))
    #expect(root["spaced"] == .dateTime("1979-05-27 07:32:00") && root["clock"] == .dateTime("07:32:00.5"))
    #expect(root["list"] == .array([.integer("1"), .integer("2"), .integer("3")]))
    #expect(root["point"] == .table(["x": .integer("1"), "y": .string("two")]))
    guard case .table(let owner)? = root["owner"] else {
        Issue.record("no owner")

        return
    }

    #expect(owner["dotted"] == .table(["key": .integer("5")]))
    guard case .array(let products)? = root["products"] else {
        Issue.record("no products")

        return
    }

    #expect(products.count == 2)
}

@Test
func mistakesAreFoundWhereTheyAre() {
    #expect(marked("a = ") == "")
    #expect(marked("a = 1 b = 2") == "b")
    #expect(marked("a = 01") == "01")
    #expect(marked("a = \"open\nb = 1") == "\"")
    #expect(marked("a = [1, 2") == "[")
    #expect(marked("a = {x = 1,}") == ",")
    #expect(marked("[t\na = 1") != nil)
    #expect(marked("= 1") == "=")
    #expect(marked("a = \"\\q\"") == "\\q")
    #expect(marked("a = \"\\u12\"") == "\\u")
    #expect(marked("a = 1979-13") == "1979-13")
    #expect(marked("a = [1 2]") == "2")
    #expect(marked("a = {x = 1\n}") != nil)
    #expect(error("a = 'x") != nil && error("a = \"\"\"never") != nil)
}

@Test
func whatMayNotBeSaidTwiceIsRefused() {
    #expect(error("a = 1\na = 2")?.message == "The key a is defined twice")
    #expect(error("[t]\n[t]")?.message == "The table [t] is defined twice")
    #expect(error("[a.b]\n[a]\n[a]")?.message == "The table [a] is defined twice")
    #expect(error("a = 1\n[a]")?.message == "a is already defined as a value, not a table")
    #expect(error("[a]\nb = 1\n[a.b]") != nil)
    #expect(error("a.b = 1\n[a]") != nil, "a table made by a dotted key cannot be opened")
    #expect(error("a = {x = 1}\n[a]") != nil, "an inline table is closed for good")
    #expect(error("[[a]]\n[a]") != nil && error("[a]\n[[a]]") != nil)
    #expect(error("[a.b]\n[a]\nx = 1") == nil, "a table made only on the way may be opened later")
    #expect(error("[[fruit]]\n[fruit.physical]\ncolor = \"red\"\n[[fruit]]\n[fruit.physical]\ncolor = \"y\"") == nil)
}

@Test
func checkingGivesOneProblemAtTheMistake() {
    #expect(TOMLSyntax.check(Array("a = 1\n".utf16)).isEmpty)
    let problems = TOMLSyntax.check(Array("a = 1\nb = oops\n".utf16))
    #expect(problems.count == 1 && problems[0].severity == .error && problems[0].source == "TOML")
    #expect(problems[0].range.location == 10 && problems[0].message == "This is not a valid TOML value")
}

// MARK: Formatting

@Test
func tomlWhiteSpaceIsMadeEvenAndTheMeaningIsKept() throws {
    let input = "# top\n\n\n  title   =   \"x\"   \nnum=1\n[a]\n   k = 2   # tail\n"
        + "\n\n\n[b.c]\nlist = [\n    1,\n  2,\n]\n[[d]]\nn= 3\n"
    let expected = "# top\n\ntitle = \"x\"\nnum = 1\n\n[a]\nk = 2   # tail\n"
        + "\n[b.c]\nlist = [\n    1,\n  2,\n]\n\n[[d]]\nn = 3\n"
    #expect(try DocumentFormatting.format(input, language: .toml) == expected)
    #expect(try DocumentFormatting.format(expected, language: .toml) == expected, "formatting twice changes nothing")
}

@Test
func multilineStringsAreNeverTouched() throws {
    let input = "a   =   \"\"\"\n  keep   this  \n\n\n   as it is\"\"\"\nb=1\n"
    let output = try DocumentFormatting.format(input, language: .toml)
    #expect(output == "a = \"\"\"\n  keep   this  \n\n\n   as it is\"\"\"\nb = 1\n")
    let literal = "x='''\n  a  \n'''\n"
    #expect(try DocumentFormatting.format(literal, language: .toml) == "x = '''\n  a  \n'''\n")
}

@Test
func aCommentAboveATableStaysWithIt() throws {
    #expect(try DocumentFormatting
        .format("a = 1\n# about b\n[b]\nc = 2\n", language: .toml) == "a = 1\n# about b\n[b]\nc = 2\n")
    #expect(try DocumentFormatting.format("[a]\n[b]\n", language: .toml) == "[a]\n\n[b]\n")
}

@Test
func tomlWithAnErrorIsNotFormatted() {
    #expect(throws: FormattingError.self) { try DocumentFormatting.format("a = \nb = 1\n", language: .toml) }
    #expect(DocumentFormatting.supports(.toml) && SyntaxChecks.supports(.toml))
}
