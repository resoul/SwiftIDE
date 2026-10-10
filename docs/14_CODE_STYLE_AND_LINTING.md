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
- [`.github/workflows/lint.yml`](../.github/workflows/lint.yml): the same commands. The first run failed on `xcode-select -s /Applications/Xcode_27.0.app/...`: there is no such Xcode on `macos-latest` (macOS 26). Now `runs-on: xcode-27` (a preview image with Xcode 27 by default, according to actions/runner-images) and instead of choosing a path — the output of `xcode-select -p`, `xcodebuild -version`, `swift --version`. After that the run on the runner passed (as reported by the user, 2026-10-10; the cache missed on the first run, which is expected). GitHub warns: `actions/checkout@v4` and `actions/cache@v4` are built for Node 20 and are forcibly run on Node 24 — the versions should be raised when builds for Node 24 appear.

**Numbers before formatting.** SwiftFormat: 95 of 133 files; `multiline_parameters`: 34 violations; `spacing-check`: 424 violations. Formatting: 105 files changed (+1435/−269), the result is idempotent (a repeated `format.sh` changes nothing), after it `lint.sh` is clean, the application builds and all the tests of the package and the application pass (46 + 82 + 360 + 65 and 5), behaviour did not change.

**Checks.** 25 `spacing-check` tests (the assignment's examples are accepted; a sole/first `return`, one-line `guard`/`if`, nested closures, `if`/`else if`/`else`, comments before `return`, strings and comments with the text `return`, `#if`, `switch`, CRLF; a refusal to write when tokens or comments change). Mutations: 13 breakages, all caught except two that do not change behaviour (the `.expr` branch for `if` is unreachable — the parser returns `if` as `.stmt`; the check "no more syntax errors" cannot be reproduced with blank lines alone). The `selftest.sh` self-test (18 checks): the good fixture is accepted by all, the bad one is rejected by each tool for its own reason, after formatting all accept it, repeated formatting changes nothing, the check mode writes no files.

**What is not done / not checked.**
- Build time of CI on a cold cache: `swift-syntax` is built once (in the debug configuration, `-j 2`) — on 8 GB that is minutes and hundreds of MB, but the cold build time in CI was not measured.
- The coverage is the first slice: `Apps/SwiftIDE` and `Packages/IDE`; `Tools`, `Fixtures`, `Tools/Experiments` and `Tools/Lint` itself are not checked. Extending the coverage is a separate decision.
- The condition "the check mode does not change files" is confirmed for `spacing-check` by the self-test; for SwiftFormat/SwiftLint it is a property of their `--lint` / `lint`.
- `portable_swiftlint` runs without `sourcekitd`; there are no rules that need the analyzer.
- Updating the versions is by the instructions in `install.sh`; there is no automatic reminder.
