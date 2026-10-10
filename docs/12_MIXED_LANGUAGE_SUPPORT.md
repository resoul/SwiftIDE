# Support for mixed projects: Swift, C, C++, Objective-C and Objective-C++

**Status:** the direction was accepted on 2026-10-10 ([ADR-021](07_ARCHITECTURE_DECISIONS.md#adr-021-support-for-the-languages-of-a-mixed-swift-project)). Verification of the other project contexts is still to come. Completion is connected to the window ([ADR-022](07_ARCHITECTURE_DECISIONS.md#adr-022-swift-completion-in-the-window-tk-014)), the timeout and the server state in the window are done, live acceptance and a latency measurement are still to come. The shared document language (TK-015) is implemented ([ADR-024](07_ARCHITECTURE_DECISIONS.md#adr-024-the-document-language-in-one-place-tk-015)); highlighting of C, C++ and Objective-C is implemented ([ADR-025](07_ARCHITECTURE_DECISIONS.md#adr-025-highlighting-of-c-c-and-objective-c-tk-016)), Objective-C++ is not. The first slice of the language features of the C family (completion in a SwiftPM package) is done ([ADR-026](07_ARCHITECTURE_DECISIONS.md#adr-026-the-c-family-on-sourcekit-lsp-first-slice-of-tk-017)); hover, definition and diagnostics in the window are done as the second slice ([ADR-027](07_ARCHITECTURE_DECISIONS.md#adr-027-symbol-description-jump-to-definition-and-diagnostics-in-the-window-tk-017-second-slice)); the other project contexts are not. Bazel is a separate project context under [ADR-023](07_ARCHITECTURE_DECISIONS.md#adr-023-support-for-bazel-projects), not yet implemented.

The goal is to read, change and check related sources inside a Swift project. Syntax highlighting and language features are accepted separately: the presence of colours does not mean that completion, diagnostics or cross-language jumps are ready.

## Languages and determining the document type

| Language | Extensions for the first stage | Notes |
|---|---|---|
| Swift | `.swift` | The existing highlighting and synchronization |
| C | `.c`, `.h` | `.h` needs a context or a manual choice |
| C++ | `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh`, `.hxx` | `.h` may also be C++ |
| Objective-C | `.m`, `.h` | Headers and the bridging header are checked in the target's context |
| Objective-C++ | `.mm`, `.h` | Needs a grammar that understands Objective-C and C++ constructs at once |
| Plain text | An unknown extension | Editing is available without highlighting and LSP |

One mechanism for determining the language is used by highlighting, LSP and the editor commands. Do not add independent extension checks to every service.

The order of choice: a manual override for the document → the language from the build settings of the selected target → the known extension. For an ambiguous `.h` without a context use C as a provisional highlighting mode, show the chosen language and allow switching it to C++, Objective-C or Objective-C++. A provisional mode does not prove that the right flags exist for LSP.

An override belongs to the document, applies in all its views and is kept in the workspace settings. It does not change the file, its text version, the dirty state or Undo. With Save As the override is kept; without it the language is determined again from the new path. Changing the language cancels earlier requests, clears the presentation and restarts the corresponding consumers; old results are not accepted even when the text version is unchanged. To change the LSP `languageId` the document is closed and opened again in the shared write queue.

## Architectural boundaries

- `IDEDomain`: the language identifier as a value, without Tree-sitter grammars, AppKit and LSP types.
- `IDEApplication`: the document's effective language, the source of the choice and the revision of the language context; notifications to consumers when the language changes.
- `SyntaxInfrastructure`: the choice of grammar and highlight queries by language, a shared mapping to `HighlightKind`. Parsing stays in the background, the presentation uses the existing rendering attributes and the limits for large files.
- `LanguageInfrastructure`: translating the language into the LSP `languageId`, checking capabilities, ordered sync and the request context. The generation of the language context complements the checks of the text version, caret, server and IME.
- Workspace/project adapters: the root, the selected target and the build settings; the UI shows the language, the availability of features and the reason for restrictions.

These are the target responsibilities of the existing modules; new targets and a separate server per language are not required in advance.

## Highlighting without a language server

For each language, connect and pin the version of a suitable Tree-sitter grammar and its queries, check the licence and update the third-party notices. The presence of a C++ grammar is not taken as proof of Objective-C++ support.

Keywords, strings, numbers, comments, preprocessor directives and the available syntactic categories are highlighted. Highlighting works with the LSP off or crashed and without a build. Unfinished code is allowed; the colours do not change the text, the versions and Undo. Semantic classification of symbols and computing the active preprocessor branches are not part of this stage.

## Language features and the project context

The first candidate is the existing SourceKit-LSP: upstream describes support for Swift and the C family of languages based on `sourcekitd` and `clangd`. This is a ground for checking, not the result of our acceptance. [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp)

Completion, diagnostics, hover and definition need a correct context: SDK/target, include paths, defines, module maps, the language mode, the C++ standard and the Swift/C++ interoperability mode where it is needed. This data is obtained from the build system and not replaced with universal flags. [clangd compile context](https://clangd.llvm.org/design/compile-commands), [setting up Swift/C++ projects](https://www.swift.org/documentation/cxx-interop/project-build-setup/)

| Context | Policy |
|---|---|
| An already open workspace/project | Use the explicitly selected project and target; a nested package must not silently change the workspace |
| A single file in SwiftPM | The nearest `Package.swift` up the path |
| An Xcode project/workspace | An explicit choice of project, scheme, configuration and destination; BSP per ADR-019, support is experimental until mixed fixtures are verified |
| A Bazel workspace | An explicit root/targets/config and a verified `sourcekit-bazel-bsp` setup; a project path to LSP and a preparation status. TK-018–TK-020, not yet implemented; mixed languages are accepted separately |
| A project with `compile_commands.json` | A separate stage of discovering and verifying the compilation database; SourceKit-LSP declares support for such a context |
| A single file without a project context | The file's directory as a fallback root; highlighting is available, project language features are not promised |

Documents of one project context use a shared service. A change of target/flags invalidates requests and diagnostics of the previous context. If the settings obtained contradict the manual language choice, show the mismatch; do not declare full support and do not rewrite the build flags silently.

Check the capabilities, the availability of `clangd`, request timeout/cancellation and reopening documents after a restart. A failure of the language services does not block editing and highlighting. A diagnostic without a version stays `unverified`: a late report may already refer to old text on receipt. Cross-language jumps and the availability of generated headers are checked separately on built fixtures.

## Order of implementation and exit criteria

| Step | Task | Exit criterion |
|---|---|---|
| 1 | TK-014: Swift completion in the window | Open a Swift file → type a dot or Ctrl+Space → choose a suggestion → undo with one Undo; IME, focus, cancellation and timeout checked, the latency to the menu measured |
| 2 | TK-015: a shared document language | One choice for highlighting/LSP/commands; a manual override, Save As and a language change invalidate old results without changing the text |
| 3 | TK-016: highlighting of the other languages | C, C++, Objective-C and Objective-C++ accepted separately; they work without LSP, observe IME/Undo and the performance limits |
| 4 | TK-017: LSP of mixed projects | Completion/diagnostics/hover/definition, target settings, restart and jumps between languages verified in an extended matrix; a status is published for each combination of language and project |

Design TK-015 together with the shared project context TK-018, so as not to multiply the `.swift`/`Package.swift` checks. TK-017 starts after TK-016; Xcode/BSP, the compilation database and Bazel are verified in separate slices. A Bazel spike on Swift (TK-019) is allowed before the other grammars are finished; the language features of other languages require their own acceptance. [Bazel plan](13_BAZEL_SUPPORT.md). The new work is not automatically included in the earlier 12–22 weeks of alpha.

## Fixtures and acceptance

1. SwiftPM: Swift calls a C API from a separate target through a public header; check both files, an unsaved edit and a jump to the declaration.
2. SwiftPM: Swift/C++ with interoperability enabled, public headers and a known C++ standard; check the declared directions of jumps separately.
3. Xcode: Swift + Objective-C with a bridging header and Objective-C's access to Swift through the generated header; separately before/after a build.
4. Xcode: a `.mm` that contains Objective-C and C++ at the same time, including a `.h` in different language modes.
5. Compilation database: C/C++ with local includes and a define that changes the available API; check the update of the context when the flags change.
6. Without a project: each language is highlighted with LSP off; an ambiguous `.h` allows a language change; a setup error is not passed off as an error of the user's code.
7. Bazel: related Swift/C-family targets, generated sources/headers and real compiler settings through `sourcekit-bazel-bsp`; the languages and directions of jumps are accepted separately after a successful Swift spike.

For each fixture record the toolchain, the target/configuration, the build and the availability of generated headers, the raw answers and the limitations. Measure completion to the appearance of the menu, separately the server RTT; typing and highlighting — for each language. The checks of late answers, language changes, restart and scope closing have a bounded execution time.

The current Swift tests and the results of TK-009/TK-010 do not prove support for the other languages. The check plan: [quality and risks](06_QUALITY_AND_RISKS.md), [compatibility matrix](11_COMPATIBILITY_MATRIX.md), [manual acceptance](10_MANUAL_ACCEPTANCE.md).
