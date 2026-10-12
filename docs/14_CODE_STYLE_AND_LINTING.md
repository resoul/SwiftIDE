# TK-023: formatting and linting of Swift code

**Status:** implemented on 2026-10-10 (tools, configurations, a SwiftSyntax check, local commands, a self-test, a CI workflow); **the workflow has passed on a GitHub runner** (the `xcode-27` image). The mass formatting was done in the working tree and awaits a separate commit ([Result](#implementation-result)). Below are the original assignment and the criteria.

The goal is to maintain consistent readability of the code automatically and to check suspicious constructs. Formatting must not be mixed with functional changes.

## Readability rules

| Rule | Conditions and exceptions |
|---|---|
| One blank line after `guard` | If another statement follows it in the same block; between adjacent `guard`s there is also one blank line. A short `else { return }` is allowed |
| One blank line before a standalone `return` | If other statements precede it in the same block; a sole/first `return` and one embedded in a one-line `guard`/`if` need no blank line |
| One blank line after a multi-line `if` | If work continues in the same block after the whole `if`/`else if`/`else` construct; do not insert between branches or before the closing `}` |
| One parameter per line in a multi-line signature | For `init` and methods/functions; the first parameter on the line after `(`, the closing `)` on a separate line. A short signature may stay on one line |
| Adjacent short `if`s — one group | One-line checks need not be separated by blank lines; the result after them is separated by the `return` rule |
| One blank line around `init` and functions | Separate from neighboring declarations/statements; comments and attributes such as `@available` and `@objc` belong to the declaration. First/last declarations need no extra line against the containing braces |
| One instruction per line | Separate instructions joined with `;`, even on short lines. Expand compact bodies containing several instructions/declarations. Single-instruction short methods, closures and `if`/`guard` bodies may stay inline. Remove unnecessary `;`; retain a separator if removal changes parsing |
| Stable whitespace | No more than one consecutive blank line; no trailing whitespace; documentation comments stay attached to their declaration |

Examples of the expected result:

```swift
guard resolved.language != .plainText else { return parts }

if !hasColours { parts.append("no syntax colours") }
if !hasLanguageFeatures { parts.append("no code completion") }

return parts
```

```swift
if evaluation != nil {
    rerun = true

    return
}

startEvaluation()
```

```swift
public init(
    label: String,
    detail: String? = nil,
    insertText: String? = nil,
    sortText: String? = nil,
    filterText: String? = nil,
    replacementRange: UTF16TextRange? = nil,
    kind: CompletionKind = .other
) {
    // Property assignments.
}
```

## Tools and implementation result

- **SwiftFormat** is the only automatic formatter. Add a root `.swiftformat` with an explicitly chosen set of formatting rules; do not enable transformations of logic/declarations without a separate decision. Do not run a second formatter on top of it.
- For `guard`: enable `blankLinesAfterGuardStatements`, set `--line-between-guards true`. For parameters: `--wrap-parameters before-first`, `--allow-partial-wrapping false`, `--closing-paren balanced`. Keep the possibility of short one-line `if`s; do not enable forced expansion of their bodies. Check the behaviour on the pinned version. [SwiftFormat rules](https://github.com/nicklockwood/SwiftFormat/blob/main/Rules.md)
- **SwiftLint** — a root `.swiftlint.yml` with an explicitly chosen set of checks. Enable `multiline_parameters`; begin with warnings for `force_try` and `force_cast`, and check the necessary exceptions in tests and existing code. Do not enable all opt-in rules automatically. [Parameters](https://realm.github.io/SwiftLint/multiline_parameters.html), [rule catalog](https://realm.github.io/SwiftLint/rule-directory.html)
- For the exact rules before `return` and after `if`, implement an additional check based on SwiftSyntax. The way of connecting it is chosen in a prototype: a separate repo check or an extension of the linter. The check must report the file/line and an understandable reason; do not use a regex to determine the boundaries of Swift blocks. Auto-fixing these rules is only after verifying that comments and syntax are preserved; a diagnostic check is enough for the first slice.
- Pin the versions of the tools and the way of installing/running them for the developer and CI. If the additional check uses SwiftSyntax, choose a version compatible with the toolchain. The same configurations and versions are used locally and in CI.
- Coverage: Swift files in `Apps/SwiftIDE` and `Packages/IDE`, including tests and manifests. `.build`, `.swiftpm`, vendor, generated sources and the research `Fixtures`/`Tools/Experiments` are explicitly excluded from the first slice; extending the coverage is a separate decision.
- Provide check commands that write no files and a separate explicit formatting command. A violation fails the corresponding CI check; SwiftLint warnings have an explicitly set policy. An ordinary application build must not rewrite the sources automatically.

## Order of execution

1. Connect the pinned tools, the configurations and a small set of examples; make sure the rules give a consistent result.
2. Implement the syntactic check of blank lines and include it in the common lint command.
3. Run the check over the current code, go through the violations and the necessary exceptions. Document the existing exceptions, without disabling checks wholesale.
4. Apply the mass formatting **in a separate commit** from the introduction of the tools and from functional edits. Run the application build and the tests of both packages.
5. Connect CI and describe the local commands in the README. The new check does not depend on the readiness of the language services or the Bazel integration.

## Acceptance criteria

- All the examples above are accepted; a missing blank line and a mixed parameter layout are detected.
- No false positives for a sole `return`, a one-line `guard`/`if`, nested blocks/closures, `if`/`else if`/`else`, comments before `return`, string literals, documentation and conditional compilation. A comment that belongs to the `return` stays next to it; the blank line separates the whole group from the previous statement.
- Repeated formatting does not change the result. The formatter and the additional check do not demand opposite transformations; the agreed example passes the whole pipeline.
- The check mode does not change files; a violation gives a non-zero exit code, the path/line and the rule name. CI repeats the local result on the same versions.
- After the mass formatting the application builds and the tests pass; a change of behaviour is not part of the formatting commit.
- `.swiftformat`, `.swiftlint.yml`, the command of the additional check, the exception rules and the run instructions are in the repository. The status of TK-023 is updated only after these conditions are actually verified.

## Implementation result

**The user's decisions:** release binaries in `Tools/Lint/.tools` with a SHA-256 check; the additional check is a separate Swift package on SwiftSyntax.

**What is in the repository.**
- [`.swiftformat`](../.swiftformat): an explicit set of rules `blankLinesAfterGuardStatements`, `wrapArguments`, `consecutiveBlankLines`, `trailingSpace`; declaration parameters — `before-first`, one per line, `)` on its own line, calls and collections are not touched (`preserve`). Excluded: `.build`, `.swiftpm`, `vendor`, `Fixtures`, `Tools`, `Generated`.
- [`.swiftlint.yml`](../.swiftlint.yml): `only_rules` — `multiline_parameters` (**error**, a short one-line signature is allowed), `force_try` and `force_cast` (**warning**). The warning policy: they are printed and counted (`SwiftLint warnings (not failing)`) and do not fail the check. There are three of them now (two `force_cast`, one `force_try`), with no exceptions.
- [`Tools/Lint/install.sh`](../Tools/Lint/install.sh): SwiftFormat **0.63.1** and SwiftLint **0.65.1** (`portable_swiftlint.zip`) from GitHub, the SHA-256 values are recorded in the script (they match those GitHub shows for the release assets), unpacking happens only after the checksum is verified, everything inside `Tools/Lint/.tools` (in `.gitignore`).
- [`Tools/Lint/Package.swift`](../Tools/Lint/Package.swift): the `SpacingCheck` package on **swift-syntax 604.0.0** (for Swift 6.4 / Xcode 27): the library `SpacingRules` and the utility `spacing-check` (`path:line:column: error: [rule] message`, exit code 1 on a violation, `--fix`, `--exclude`).
- The `spacing-check` rules: `blank_line_before_return` (a standalone `return` after other statements of the same block; the blocks are bodies of functions, closures, `if`/`else`, `switch` branches, `#if` clauses; a first `return`, a `return` on the same line and inside one-line `guard`/`if` are not required to; comments directly above a `return` are its group, the blank line goes above them) and `blank_line_after_multiline_if` (a multi-line `if` with all its `else`s, followed by a continuation in the block; adjacent short `if`s are one group). Block boundaries are determined from the tree, not by regexes; a line of spaces counts as blank. A violation for a `return` after a multi-line `if` is reported once, as a `return`. The `guard` rule is entirely SwiftFormat's.
- The `--fix` auto-fix: adds one line break (the LF/CRLF style is preserved); before writing, the same tokens, the same comments and no more syntax errors are verified, otherwise the file is not written.
- [`lint.sh`](../Tools/Lint/lint.sh) (check only; runs all the checks, exit code 1 on any violation), [`format.sh`](../Tools/Lint/format.sh) (a separate explicit command: SwiftFormat, then `spacing-check --fix`), [`selftest.sh`](../Tools/Lint/selftest.sh) and the [fixtures](../Tools/Lint/Fixtures). The application build rewrites nothing.
- [`.github/workflows/lint.yml`](../.github/workflows/lint.yml): the same commands. The first run failed on `xcode-select -s /Applications/Xcode_27.0.app/...`: there is no such Xcode on `macos-latest` (macOS 26). Now `runs-on: xcode-27` (a preview image with Xcode 27 by default, according to actions/runner-images) and instead of choosing a path — the output of `xcode-select -p`, `xcodebuild -version`, `swift --version`. After that the run on the runner passed (as reported by the user, 2026-10-10; the cache missed on the first run, which is expected). GitHub warned that `actions/checkout@v4` and `actions/cache@v4` are built for Node 20 and forcibly run on Node 24; the workflow now uses `actions/checkout@v7` and `actions/cache@v6` (both declare `node24` in their `action.yml`, checked 2026-10-10; the changes since the old majors are the ESM migration and, for checkout, a block on fork pull requests for `pull_request_target`/`workflow_run`, which this workflow does not use). **Not yet run with the new versions**: restart the workflow once before relying on it.

**Numbers before formatting.** SwiftFormat: 95 of 133 files; `multiline_parameters`: 34 violations; `spacing-check`: 424 violations. Formatting: 105 files changed (+1435/−269), the result is idempotent (a repeated `format.sh` changes nothing), after it `lint.sh` is clean, the application builds and all the tests of the package and the application pass (46 + 82 + 360 + 65 and 5), behaviour did not change.

**Checks.** 25 `spacing-check` tests (the assignment's examples are accepted; a sole/first `return`, one-line `guard`/`if`, nested closures, `if`/`else if`/`else`, comments before `return`, strings and comments with the text `return`, `#if`, `switch`, CRLF; a refusal to write when tokens or comments change). Mutations: 13 breakages, all caught except two that do not change behaviour (the `.expr` branch for `if` is unreachable — the parser returns `if` as `.stmt`; the check "no more syntax errors" cannot be reproduced with blank lines alone). The `selftest.sh` self-test (18 checks): the good fixture is accepted by all, the bad one is rejected by each tool for its own reason, after formatting all accept it, repeated formatting changes nothing, the check mode writes no files.

**What is not done / not checked.**
- Build time of CI on a cold cache: `swift-syntax` is built once (in the debug configuration, `-j 2`) — on 8 GB that is minutes and hundreds of MB, but the cold build time in CI was not measured.
- The coverage is the first slice: `Apps/SwiftIDE` and `Packages/IDE`; `Tools`, `Fixtures`, `Tools/Experiments` and `Tools/Lint` itself are not checked. Extending the coverage is a separate decision.
- The condition "the check mode does not change files" is confirmed for `spacing-check` by the self-test; for SwiftFormat/SwiftLint it is a property of their `--lint` / `lint`.
- `portable_swiftlint` runs without `sourcekitd`; there are no rules that need the analyzer.
- Updating the versions is by the instructions in `install.sh`; there is no automatic reminder.


## Initializer spacing refinement (2026-10-11)

`blank_line_around_initializer` now checks neighboring members in types/extensions and declarations within conditional compilation. It adds spacing before the complete attribute/comment group, never between `@available` and `init`. The same existing token/comment/syntax verification and LF/CRLF preservation protect auto-fixes. The initial 28-test checker run and pipeline self-test passed; `format.sh` applied the new rule to 42 checked source files. These blank-line-only changes can be committed separately from Pull and the earlier network slices. Final project verification is recorded with ADR-044.

```swift
private let output = NSTextView()
private var subscription: UUID?

public init(model: GitClone) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
}

@available(*, unavailable)
public required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
}
```

## Line length refinement (2026-10-12)

**Decision (user):** the longest line is **120 characters**, the default of SwiftLint's `line_length`. A longer line is an error.

**What changed.**
- [`.swiftformat`](../.swiftformat): `--max-width 120` with the `wrap` and `wrapSingleLineComments` rules; calls and collections now follow the declaration layout once they span several lines (`--wrap-arguments before-first`, `--wrap-collections before-first`, `)` on its own line, so no argument alignment under the opening parenthesis); a ternary that does not fit breaks before `?` and `:` (`--wrap-ternary before-operators`).
- [`.swiftlint.yml`](../.swiftlint.yml): `line_length` (warning and error at 120, URLs ignored). It is the check for what SwiftFormat cannot wrap: a long string literal has to be split by hand (a multi-line `"""` literal with `\` at the end of a line keeps the text unchanged).
- `spacing-check` (the same SwiftSyntax tool, run by `lint.sh` and, with `--fix`, by `format.sh`) has two more rules, both about a line longer than 120 characters, because a formatter alone wraps the header of a statement and leaves its body behind it (`if lock⏎    .withLock({ … }) {⏎    body() }`):
  - `long_line_body`: a block written as `{ statements }` (an `if`/`for`/`while`/`guard`/`func` body, a getter, a closure) whose `}` closes the line gets its statements and its `}` on lines of their own; of the blocks on the line the outermost, the last one is expanded, repeatedly. A block with a comment, an empty block and a closure followed by more code on the line (`.map { … } ?? "x"`) are left alone.
  - `long_line_statements`: statements joined with `;` (or following a `case` label on its line) each get a line of their own.
- `format.sh` order: `spacing-check --fix` (bodies and statements first, so SwiftFormat wraps only what is left of the line), SwiftFormat, `spacing-check --fix` once more for the blank lines. The `--fix` verification now ignores `;` tokens, which go when statements get their own lines; tokens and comments are otherwise compared as before.

**Result.** 7 new `spacing-check` tests (35 in all), the fixtures and `selftest.sh` cover the new rules and the new order (the SwiftFormat diagnostic for a split signature may now be named `wrap` instead of `wrapArguments`). One formatting pass changed about 195 files; the 120-character limit left no line longer than that in `Apps/SwiftIDE` and `Packages/IDE`. Long string literals (about 45) were split by hand into `"""` literals or `+`, and a few over-long expressions were broken up with local constants. `lint.sh` is clean, the application and package build, and all package tests pass; of the application tests `aProjectQuestionBelongsToItsOwnerWhileAnotherProjectIsActuallyActive` fails with and without the change when the application is not the active one (`active=false`), which is a property of running it from a background session.

## Function spacing and instruction separation (2026-10-12)

**Decision (user):** separate functions from their neighbors with one blank line and put each instruction on its own line, including lines shorter than 120 characters.

```swift
public func showRemoteSelection() {
    _ = view
    showBranches(nil)
}

@objc private func filterChanged(_ sender: Any?) { render() }

private func configure() {
    tracking.target = self
    tracking.action = #selector(trackingSelected(_:))
}
```

`blank_line_around_function` checks type members, top-level/local functions and conditional compilation. The blank line goes before the complete documentation/attribute group, including `@objc`; first/last declarations need no blank line against the containing braces. This is declaration spacing, not empty lines at the beginning/end of every function body. A short function containing just one instruction can stay on one line.

`one_statement_per_line` separates instructions joined with `;` regardless of length. `multiple_statement_body` expands a compact body containing several instructions/declarations, including nested bodies, closures and compact member blocks. Existing long-line rules remain in force. Strings and comments containing `;` are not instructions.

SwiftFormat now also enables `semicolons` (`--semicolons never`), `indent` (`--indent 4`) and `braces`. These normalize the layout after syntax-aware expansion and remove unnecessary semicolons. A separator is retained when removing it changes parsing: for example, `return; work()` must never become `return work()`. Before writing, the syntax-aware fixer compares the non-semicolon tokens, exact comments, statement/member counts, return expressions, break/continue labels and syntax-error counts. CRLF is preserved.

**Verification:** 42 checker tests and the complete pipeline self-test pass, including the user's short examples, documentation/attributes, nested blocks, strings/comments, CRLF, control-flow separators and repeated formatting. Formatting changed 161 of the 293 checked Swift files. A one-off comparison of all 293 files against the current working-tree snapshot confirmed unchanged tokens, comments and statement/control-flow structure, preserving the pending Git functionality. Commit the mechanical source formatting separately from functional changes.

The second formatting pass changed no source file. One expression that exceeded 120 characters after indentation was wrapped without changing its string literal. Final verification: 974 package tests pass; App builds; lint has zero violations and four pre-existing force-cast/force-try warnings. Of the 39 App tests, 38 pass and the existing foreground-window probe fails with `active=false` in the background run; its assertion was retained.

**Coverage correction during TK-037:** format/lint now pass `Apps/SwiftIDE` and `Packages/IDE` explicitly to SwiftFormat, matching `spacing-check` and SwiftLint. A root-wide `.` invocation could traverse an unrelated reference checkout added later. The accidental reference formatting was stopped; all 1250 changed files were restored only after exact comparison against formatting their Git HEAD, with no unmatched changes overwritten. The reference checkout is clean again. Future sibling/reference folders are outside the explicit tool inputs.
