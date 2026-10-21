import Foundation
import IDEApplication
import IDEDomain
import Testing
@testable import SyntaxInfrastructure

private func check(_ text: String, _ language: DocumentLanguage) async -> [DocumentDiagnostic] {
    await TreeSitterChecks().check(Array(text.utf16), language: language, fileName: "f", directory: nil)
}

@Test
func goodYAMLAndShellHaveNoProblems() async {
    #expect(await check("a: 1\nb:\n  - x\n  - y: [1, 2]\nc: |\n  text\n", .yaml).isEmpty)
    #expect(await check("#!/bin/sh\nif [ -f a ]; then\n  echo hi\nfi\n", .shell).isEmpty)
    let empty = await check("", .yaml)
    let blank = await check("   \n", .shell)
    #expect(empty.isEmpty && blank.isEmpty)
}

@Test
func yamlErrorsAreErrorsAndPointAtTheTrouble() async {
    let bad = await check("a: 1\nb: [1, 2\nc: 3\n", .yaml)
    #expect(!bad.isEmpty && bad.allSatisfy { $0.severity == .error && $0.source == "YAML" })
    #expect(bad[0].range.location >= 5, "not before the broken line")
    let tab = await check("a:\n\t- x\n", .yaml)
    #expect(!tab.isEmpty, "a tab cannot indent")
    let quote = await check("a: 'open\nb: 1\n", .yaml)
    #expect(!quote.isEmpty)
}

@Test
func shellMistakesAreWarningsBecauseTheGrammarIsBashs() async {
    let bad = await check("if [ -f a ]; then\n  echo hi\n", .shell)
    #expect(!bad.isEmpty && bad.allSatisfy { $0.severity == .warning && $0.source == "Shell" })
    let loop = await check("for x in 1 2; do echo $x;\n", .shell)
    let quote = await check("echo \"open\n", .shell)
    #expect(!loop.isEmpty && !quote.isEmpty)
}

@Test
func otherLanguagesAreNotThisCheckersBusiness() async {
    #expect(!TreeSitterChecks().supports(.json) && TreeSitterChecks().supports(.yaml) && TreeSitterChecks()
        .supports(.shell))
    let json = await check("{", .json)
    #expect(json.isEmpty)
}

@Test
func moreThanTenErrorsAreCut() async {
    let text = (0..<40).map { "a\($0): [1,\n" }.joined()
    let found = await check(text, .yaml)
    #expect(!found.isEmpty && found.count <= 10)
    #expect(found.map(\.range.location) == found.map(\.range.location).sorted())
}

// MARK: Formatting YAML

private func formatYAML(_ text: String) throws -> String { try TreeSitterFormatter().format(text, language: .yaml) }

@Test
func yamlIsReindentedToTwoSpacesWithItsMeaningKept() throws {
    let input = "name:   demo   \nitems:\n    - one\n    -   two\n    - key: v\n"
        + "      other: w\nnested:\n    deep:\n        deeper: 1\n\n\n\nend: 2\n"
    let expected = "name:   demo\nitems:\n  - one\n  - two\n  - key: v\n"
        + "    other: w\nnested:\n  deep:\n    deeper: 1\n\nend: 2\n"
    #expect(try formatYAML(input) == expected)
    #expect(try formatYAML(expected) == expected, "formatting twice changes nothing")
}

@Test
func yamlBlockScalarsMoveWithTheirOwnerAndKeepTheirShape() throws {
    let input = "script:\n    run: |\n        line one\n          indented\n\n"
        + "        line two\n    after: 1\nlist:\n    - |\n        in item\n"
    let expected = "script:\n  run: |\n    line one\n      indented\n\n"
        + "    line two\n  after: 1\nlist:\n  - |\n    in item\n"
    #expect(try formatYAML(input) == expected)
}

@Test
func yamlCommentsDocumentsAndSequencesBesideTheirKeyAreKept() throws {
    let input = "# top\n---\nkey:\n- a\n- b\n    # note\nother:\n    - c\n...\n"
    let output = try formatYAML(input)
    #expect(output.hasPrefix("# top\n---\nkey:\n- a\n- b\n"))
    #expect(output.contains("# note") && output.contains("other:\n  - c"))
}

@Test
func yamlWithErrorsOrAnIndentationIndicatorIsLeftAlone() {
    #expect(throws: FormattingError.self) { try formatYAML("a: [1,\nb: 2\n") }
    #expect(throws: FormattingError.self) { try formatYAML("a: |2\n    text\n") }
    #expect(TreeSitterFormatter().supports(.yaml) && TreeSitterFormatter().supports(.shell) && !TreeSitterFormatter()
        .supports(.json))
}

// MARK: Formatting shell

private func formatShell(_ text: String) throws -> String { try TreeSitterFormatter().format(text, language: .shell) }

@Test
func shellBlocksAreIndentedByTheirDepth() throws {
    let input = """
    #!/bin/bash
    set -e
    f() {
    echo start
      if [ -n "$1" ]; then
    echo yes
    else
          echo no
    fi
    for x in 1 2; do
    echo $x
        done
    }
    case "$1" in
    a) echo A ;;
    b|c)
    echo BC
    ;;
    *) echo other ;;
    esac
    while true
    do
    break
    done


    f $@
    """
    let expected = """
    #!/bin/bash
    set -e
    f() {
      echo start
      if [ -n "$1" ]; then
        echo yes
      else
        echo no
      fi
      for x in 1 2; do
        echo $x
      done
    }
    case "$1" in
      a) echo A ;;
      b|c)
        echo BC
        ;;
      *) echo other ;;
    esac
    while true
    do
      break
    done

    f $@

    """
    #expect(try formatShell(input) == expected)
    #expect(try formatShell(expected) == expected, "formatting twice changes nothing")
}

@Test
func shellHeredocsStringsAndContinuationsAreNotTouched() throws {
    let input = "if true; then\ncat <<EOF\n    keep   this\n  as it is\n"
        + "EOF\necho \"multi\n   line\"\nls \\\n      -l\nfi\n"
    let output = try formatShell(input)
    #expect(output ==
        "if true; then\n  cat <<EOF\n    keep   this\n  as it is\nEOF\n"
        + "  echo \"multi\n   line\"\n  ls \\\n      -l\nfi\n")
}

@Test
func shellThatIsUnbalancedOrBrokenIsLeftAlone() {
    #expect(throws: FormattingError.self) { try formatShell("if true; then\necho\n") }
    #expect(throws: FormattingError.self) { try formatShell("echo \"open\n") }
    #expect(throws: FormattingError.self) { try formatShell("fi\n") }
}
