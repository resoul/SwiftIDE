import Foundation
import Testing
@testable import SpacingRules

private func rules(_ source: String) -> [Rule] { SpacingChecker.check(source).map(\.rule) }

private func lines(_ source: String) -> [Int] { SpacingChecker.check(source).map(\.line) }

// MARK: The documented examples are accepted

@Test
func theExamplesOfTheTaskAreAccepted() {
    let samples = [
        """
        func a(resolved: Int) -> [String] {
            guard resolved != 0 else { return [] }

            if resolved > 1 { print("a") }
            if resolved > 2 { print("b") }

            return []
        }
        """,
        """
        func b() {
            if evaluation != nil {
                rerun = true

                return
            }

            startEvaluation()
        }
        """,
        """
        public init(
            label: String,
            kind: CompletionKind = .other
        ) {
            self.label = label
        }
        """,
    ]
    for sample in samples { #expect(SpacingChecker.check(sample).isEmpty, "\(sample)") }
}

// MARK: return

@Test
func aReturnAfterOtherStatementsNeedsABlankLineBeforeIt() {
    let source = """
    func f() -> Int {
        let x = 1
        return x
    }
    """
    #expect(rules(source) == [.blankLineBeforeReturn])
    #expect(lines(source) == [3])
    #expect(SpacingChecker.check(source)[0].formatted.hasSuffix("[blank_line_before_return] put a blank line before `return` when other statements come before it in the block"))
}

@Test
func aReturnThatIsFirstOrAloneNeedsNothing() {
    #expect(rules("func f() -> Int {\n    return 1\n}\n").isEmpty)
    #expect(rules("func f(_ a: Int?) -> Int {\n    guard let a else { return 0 }\n\n    return a\n}\n").isEmpty)
    #expect(rules("func f(_ a: Int) -> Int {\n    if a > 0 { return 1 }\n    return 0\n}\n") == [.blankLineBeforeReturn], "the last return follows another statement")
}

@Test
func aReturnInsideAOneLineGuardOrIfIsTheOnlyStatementOfItsBlock() {
    let source = """
    func f(_ a: Int?) -> Int {
        guard let a else { return 0 }

        if a > 3 { return 1 }

        return a
    }
    """
    #expect(rules(source).isEmpty)
}

@Test
func aReturnOnTheLineOfTheStatementBeforeIsLeftAlone() {
    #expect(rules("func f() -> Int {\n    let x = 1; return x\n}\n").isEmpty)
    #expect(rules("let g: () -> Int = { let y = 2; return y }\n").isEmpty)
}

@Test
func nestedBlocksAndClosuresAreCheckedOnTheirOwn() {
    let source = """
    func f(_ items: [Int]) -> [Int] {
        let doubled = items.map { item -> Int in
            let twice = item * 2
            return twice
        }

        let single = items.map { $0 + 1 }

        return doubled + single
    }
    """
    #expect(lines(source) == [4], "only the return inside the closure")
}

@Test
func aSwitchCaseIsABlockToo() {
    let source = """
    func f(_ x: Int) -> Int {
        switch x {
        case 1:
            return 1
        case 2:
            print("two")
            return 2
        default:
            return 0
        }
    }
    """
    #expect(lines(source) == [7])
}

@Test
func conditionalCompilationClausesAreBlocks() {
    let source = """
    func f() -> Int {
        #if DEBUG
        let x = 1
        return x
        #else
        return 0
        #endif
    }
    """
    #expect(lines(source) == [4])
}

@Test
func textThatLooksLikeAReturnIsNotAReturn() {
    let source = """
    func f() -> String {
        let a = "return 1"
        // return 2
        /// return 3
        let b = "\\(a) return"

        return b
    }
    """
    #expect(rules(source).isEmpty)
}

// MARK: Comments belong to their statement

@Test
func aCommentRightAboveAReturnMovesTheBlankLineAboveTheComment() {
    let good = """
    func f() -> Int {
        let x = 1

        // the answer
        return x
    }
    """
    #expect(rules(good).isEmpty)

    let bad = """
    func f() -> Int {
        let x = 1
        // the answer
        return x
    }
    """
    #expect(rules(bad) == [.blankLineBeforeReturn])

    let separated = """
    func f() -> Int {
        let x = 1
        // the answer

        return x
    }
    """
    #expect(rules(separated).isEmpty, "a comment with a blank line below it is on its own; the return has its blank line")
}

@Test
func severalCommentLinesAndADocCommentFormOneGroup() {
    let good = """
    func f() -> Int {
        let x = 1

        /// first
        // second
        /* third */
        return x
    }
    """
    #expect(rules(good).isEmpty)
    #expect(rules(good.replacingOccurrences(of: "let x = 1\n\n", with: "let x = 1\n")) == [.blankLineBeforeReturn])
}

@Test
func aTrailingCommentOnTheLineBeforeIsNotPartOfTheGroup() {
    let source = """
    func f() -> Int {
        let x = 1 // one
        return x
    }
    """
    #expect(rules(source) == [.blankLineBeforeReturn])
}

@Test
func aBlankLineThatHasSpacesInItCounts() {
    #expect(rules("func f() -> Int {\n    let x = 1\n    \n    return x\n}\n").isEmpty)
}

// MARK: if

@Test
func aMultilineIfFollowedByMoreNeedsABlankLine() {
    let source = """
    func f(_ x: Int) {
        if x > 1 {
            print(x)
        }
        print("after")
    }
    """
    #expect(rules(source) == [.blankLineAfterMultilineIf])
    #expect(lines(source) == [5])
}

@Test
func theWholeIfElseChainIsOneConstruct() {
    let source = """
    func f(_ x: Int) {
        if x > 1 {
            print(1)
        } else if x > 0 {
            print(2)
        } else {
            print(3)
        }
        print("after")
    }
    """
    #expect(rules(source) == [.blankLineAfterMultilineIf])
    #expect(lines(source) == [9])
}

@Test
func shortIfsInARowAreOneGroupAndALastMultilineIfNeedsNothing() {
    let source = """
    func f(_ x: Int) {
        if x > 1 { print(1) }
        if x > 2 { print(2) }
        if x > 3 { print(3) }
        print("after")
        if x > 4 {
            print(4)
        }
    }
    """
    #expect(rules(source).isEmpty)
}

@Test
func aMultilineIfThenAReturnIsOneViolationAsAReturn() {
    let source = """
    func f(_ x: Int) -> Int {
        if x > 1 {
            print(x)
        }
        return x
    }
    """
    #expect(rules(source) == [.blankLineBeforeReturn])
}

@Test
func aMultilineIfWithACommentBelowItKeepsTheCommentWithTheNextStatement() {
    let good = """
    func f(_ x: Int) {
        if x > 1 {
            print(x)
        }

        // then
        print("after")
    }
    """
    #expect(rules(good).isEmpty)
    #expect(rules(good.replacingOccurrences(of: "}\n\n    // then", with: "}\n    // then")) == [.blankLineAfterMultilineIf])
}

@Test
func anIfInsideAClosureOrAnotherIfIsCheckedInItsOwnBlock() {
    let source = """
    func f(_ x: Int) {
        if x > 0 {
            if x > 1 {
                print(1)
            }
            print(2)
        }
    }
    """
    #expect(lines(source) == [6])
}

// MARK: The fix

@Test
func theFixAddsTheBlankLinesAndOnlyThose() throws {
    let source = """
    func f(_ x: Int) -> Int {
        if x > 1 {
            print(x)
        }
        let y = x
        // explained
        return y
    }
    """
    let fixed = try #require(try SpacingChecker.fix(source))
    #expect(fixed == """
    func f(_ x: Int) -> Int {
        if x > 1 {
            print(x)
        }

        let y = x

        // explained
        return y
    }
    """)
    #expect(SpacingChecker.check(fixed).isEmpty)
    #expect(try SpacingChecker.fix(fixed) == nil, "idempotent")
}

@Test
func theFixKeepsLineEndingsAndHandlesCarriageReturns() throws {
    let source = "func f() -> Int {\r\n    let x = 1\r\n    return x\r\n}\r\n"
    let fixed = try #require(try SpacingChecker.fix(source))
    #expect(fixed == "func f() -> Int {\r\n    let x = 1\r\n\r\n    return x\r\n}\r\n")
}

@Test
func nothingToFixGivesNil() throws {
    #expect(try SpacingChecker.fix("let a = 1\n") == nil)
}

@Test
func codeThatDoesNotParseIsNotMadeWorse() throws {
    // A broken file is checked as far as it can be read and the fix never changes its tokens.
    let source = "func f( {\n    let x = 1\n    return x\n"
    if let fixed = try? SpacingChecker.fix(source) {
        #expect(fixed.replacingOccurrences(of: "\n", with: "") == source.replacingOccurrences(of: "\n", with: ""))
    }
}

@Test
func everyViolationNamesFileLineColumnAndRule() {
    let violation = SpacingChecker.check("func f() -> Int {\n    let x = 1\n    return x\n}\n", path: "A.swift")[0]
    #expect(violation.path == "A.swift" && violation.line == 3 && violation.column == 5)
    #expect(violation.formatted.hasPrefix("A.swift:3:5: error: [blank_line_before_return]"))
}

// MARK: The safety check of the fix

@Test
func aFixThatChangedCodeCommentsOrSyntaxIsRefused() throws {
    let original = "func f() -> Int {\n    let x = 1 // one\n    return x\n}\n"
    try SpacingChecker.verify(original: original, fixed: "func f() -> Int {\n    let x = 1 // one\n\n    return x\n}\n", path: "A.swift")

    #expect(throws: SpacingChecker.FixRefused.self) {
        try SpacingChecker.verify(original: original, fixed: original.replacingOccurrences(of: "return x", with: "return y"), path: "A.swift")
    }
    #expect(throws: SpacingChecker.FixRefused.self) {
        try SpacingChecker.verify(original: original, fixed: original.replacingOccurrences(of: "// one", with: "// two"), path: "A.swift")
    }
    #expect(throws: SpacingChecker.FixRefused.self) {
        try SpacingChecker.verify(original: original, fixed: original.replacingOccurrences(of: "// one", with: ""), path: "A.swift")
    }
    // Same tokens and comments, but a new syntax error: an unbalanced brace cannot come from blank lines.
    #expect(throws: SpacingChecker.FixRefused.self) {
        try SpacingChecker.verify(original: "let a = [1, 2]\n", fixed: "let a = [1, 2]\nlet\n", path: "A.swift")
    }
}
