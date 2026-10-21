import Foundation
import IDEDomain
import Testing
@testable import SyntaxInfrastructure

/// The kind painted on the nth occurrence of `token`, if all of it has one kind (nil if mixed or none).
private func kind(
    of token: String,
    in text: String,
    occurrence: Int = 1,
    using scanner: ([UInt16]) -> [UInt8]
) -> HighlightKind? {
    let kinds = scanner(Array(text.utf16))
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

// MARK: JSON

@Test
func jsonKeysValuesNumbersAndLiteralsHaveTheirOwnColours() {
    let text = "{\n  \"name\": \"A\\n\\u00e9\",\n  \"n\": -1.5e3,\n"
        + "  \"ok\": true, \"none\": null, // note\n  \"list\": [1, 2]\n}\n"

    func k(_ token: String, _ n: Int = 1) -> HighlightKind? {
        kind(of: token, in: text, occurrence: n, using: JSONColours.kinds(for:))
    }

    #expect(k("\"name\"") == .property && k("\"n\"") == .property && k("\"list\"") == .property)
    #expect(k("\"A") == .string && k("\\n") == .escape && k("\\u00e9") == .escape)
    #expect(k("-1.5e3") == .number && k("1", 2) == .number)
    #expect(k("true") == .constant && k("null") == .constant)
    #expect(k("// note") == .comment)
    #expect(k("{") == nil && k("[") == nil)
}

@Test
func anUnterminatedJSONStringStopsAtTheLineEnd() {
    let text = "{\"a\": \"open\n\"b\": 1}"
    #expect(kind(of: "\"open", in: text, using: JSONColours.kinds(for:)) == .string)
    #expect(kind(of: "\"b\"", in: text, using: JSONColours.kinds(for:)) == .property)
}

// MARK: XML and property lists

@Test
func xmlTagsAttributesCommentsAndEntitiesAreColoured() {
    let text = "<?xml version=\"1.0\"?>\n<!-- c -->\n<a id=\"x\" b='y'>t &amp; u<![CDATA[raw]]><br/></a>\n"

    func k(_ token: String) -> HighlightKind? { kind(of: token, in: text, using: XMLColours.kinds(for:)) }

    #expect(k("<?xml version=\"1.0\"?>") == .attribute)
    #expect(k("<!-- c -->") == .comment)
    #expect(k("id") == .property && k("\"x\"") == .string && k("'y'") == .string)
    #expect(k("a") == .keyword, "the first \"a\" is the name of the tag")
    #expect(k("&amp;") == .escape && k("raw") == .string)
    #expect(k("<![CDATA[") == .attribute)
}

@Test
func aPropertyListColoursKeysAndTypedValues() {
    let text = "<plist version=\"1.0\"><dict><key>Name</key><string>App</string><key>N</key><integer>3</integer>"
        + "<key>B</key><true/></dict></plist>"

    func k(_ token: String, _ n: Int = 1) -> HighlightKind? {
        kind(of: token, in: text, occurrence: n, using: XMLColours.kinds(for:))
    }

    #expect(k("Name") == .property && k("App") == .string && k("3") == .number)
    #expect(k("true") == .constant && k("dict") == .keyword)
    let outsidePlist = "<key>Name</key>"
    #expect(kind(of: "Name", in: outsidePlist, using: XMLColours.kinds(for:)) == nil, "plain XML has no typed text")
}

// MARK: TOML

@Test
func tomlTablesKeysValuesAndMultilineStringsAreColoured() {
    let text = "# c\n[package]\nname = \"demo\" # tail\nversion = 1.5\nok = true\nwhen = 1979-05-27T07:32:00Z\n"
        + "[[bin]]\ntext = \"\"\"\nline one\nline two\"\"\"\nafter = 3\n"

    func k(_ token: String, _ n: Int = 1) -> HighlightKind? {
        kind(of: token, in: text, occurrence: n, using: TOMLColours.kinds(for:))
    }

    #expect(k("# c") == .comment && k("# tail") == .comment)
    #expect(k("[package]") == .type && k("[[bin]]") == .type)
    #expect(k("name") == .property && k("\"demo\"") == .string)
    #expect(k("1.5") == .number && k("true") == .constant && k("1979-05-27T07:32:00Z") == .number)
    #expect(k("line one") == .string && k("after") == .property && k("3") == .number)
}

// MARK: Config files

@Test
func configFilesGetCommentsSectionsKeysValuesAndVariables() {
    let text = """
    // xcconfig
    # hash
    [core]
    SWIFT_VERSION = 6.0
    OTHER_FLAGS = $(inherited) -DDEBUG
    path = "a b"
    !keep.txt
    FROM swift:6
    RUN make
    name := value
    """

    func k(_ token: String, _ n: Int = 1) -> HighlightKind? {
        kind(of: token, in: text, occurrence: n, using: ConfigColours.kinds(for:))
    }

    #expect(k("// xcconfig") == .comment && k("# hash") == .comment)
    #expect(k("[core]") == .type)
    #expect(k("SWIFT_VERSION") == .property && k("OTHER_FLAGS") == .property && k("path") == .property)
    #expect(k("6.0") == .number && k("$(inherited)") == .property && k("\"a b\"") == .string)
    #expect(k("!") == .operator)
    #expect(k("FROM") == .keyword && k("RUN") == .keyword)
    #expect(k("name") == .property && k(":=") == .operator)
}

@Test
func stringsAndProjectFilesWithBlockCommentsAreRead() {
    let strings = "/* greeting\n   spans lines */\n\"hello\" = \"Hello\";\n"
    #expect(kind(of: "/* greeting", in: strings, using: ConfigColours.kinds(for:)) == .comment)
    #expect(kind(of: "spans lines */", in: strings, using: ConfigColours.kinds(for:)) == .comment)
    #expect(kind(of: "\"hello\"", in: strings, using: ConfigColours.kinds(for:)) == .property)
    #expect(kind(of: "\"Hello\"", in: strings, using: ConfigColours.kinds(for:)) == .string)
    let pbx = "// !$*UTF8*$!\n{\n\tobjectVersion = 56;\n}\n"
    #expect(kind(of: "// !$*UTF8*$!", in: pbx, using: ConfigColours.kinds(for:)) == .comment)
    #expect(kind(of: "objectVersion", in: pbx, using: ConfigColours.kinds(for:)) == .property)
}

// MARK: Metal

@Test
func metalKeywordsAddressSpacesTypesAndAttributesAreColoured() {
    let text = """
    #include <metal_stdlib>
    using namespace metal;
    constant float PI_2 = 6.28f;
    struct Out { float4 position [[position]]; };
    kernel void shade(device float4 *data [[buffer(0)]], texture2d<float> tex [[texture(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        float3x3 m = float3x3(1.0);
        half h = 0.5h;  // note
        data[gid.x] = tex.read(gid) * metal::saturate(h);
    }
    """

    func k(_ token: String, _ n: Int = 1) -> HighlightKind? {
        kind(of: token, in: text, occurrence: n, using: MetalColours.kinds(for:))
    }

    #expect(k("#include <metal_stdlib>") == .attribute && k("// note") == .comment)
    #expect(k("kernel") == .keyword && k("device") == .keyword && k("constant") == .keyword && k("struct") == .keyword)
    #expect(k("float4", 1) == .type && k("float3x3") == .type && k("uint2") == .type && k("half") == .type)
    #expect(k("texture2d") == .type && k("void") == .type)
    #expect(k("[[position]]") == .attribute && k("[[buffer(0)]]") == .attribute && k("[[thread_position_in_grid]]") ==
        .attribute)
    #expect(k("6.28f") == .number && k("0.5h") == .number && k("1.0") == .number)
    #expect(k("shade") == .function && k("metal", 3) == .builtin && k("saturate") == .function)
    #expect(k("PI_2") == .constant && k("data") == nil)
}

@Test
func metalAndOtherScannedLanguagesAreMadeByTheFactoryAndMetalHasNoGrammar() {
    #expect(SyntaxHighlighters.make(for: .metal) is ScannedHighlighter)
    #expect(!TreeSitterHighlighter.supportedLanguages.contains(.metal))
    #expect(SyntaxHighlighters.supportedLanguages.contains(.metal))
}

// MARK: Names, factory

@Test
func fileNamesChooseTheseLanguages() {
    let table: [(String, DocumentLanguage)] = [
        ("/w/Package.resolved", .json),
        ("/w/a.json", .json),
        ("/w/L.xcstrings", .json),
        ("/w/Info.plist", .xml),
        ("/w/A.entitlements", .xml),
        ("/w/M.storyboard", .xml),
        ("/w/a.xml", .xml),
        ("/w/.swiftlint.yml", .yaml),
        ("/w/ci.yaml", .yaml),
        ("/w/a.toml", .toml),
        ("/w/run.sh", .shell),
        ("/w/.zshrc", .shell),
        ("/w/a.metal", .metal),
        ("/w/.gitignore", .config),
        ("/w/Makefile", .config),
        ("/w/Dockerfile", .config),
        (
            "/w/Dockerfile.dev",
            .config
        ),
        ("/w/Debug.xcconfig", .config),
        ("/w/x.pbxproj", .config),
        ("/w/L.strings", .config),
        ("/w/.clang-format", .yaml),
        ("/w/README", .plainText),
        ("/w/notes.txt", .plainText)
    ]
    for (path, language) in table {
        #expect(DocumentLanguage.guess(forPath: path).language == language, "\(path)")
    }
}

@Test
func everyScannedLanguageHasColoursFolding() {
    for language: DocumentLanguage in [.json, .xml, .yaml, .toml, .shell, .config, .markdown, .metal] {
        #expect(SyntaxHighlighters.supportedLanguages.contains(language), "\(language)")
        #expect(SyntaxHighlighters.make(for: language) != nil, "\(language)")
        #expect(language.supportsFolding, "\(language)")
    }
    #expect(!SyntaxHighlighters.supportedLanguages.contains(.plainText))
    #expect(DocumentLanguage.shell.lineCommentPrefix == "#" && DocumentLanguage.json.lineCommentPrefix == nil)
}
