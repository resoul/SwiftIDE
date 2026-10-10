# Xcode / BSP compatibility matrix (TK-009)

The result of the M0 investigation: what SourceKit-LSP can do with Xcode projects on a real toolchain, with a build server and without one. Tools, cases and raw answers: [Tools/CompatibilityMatrix](../Tools/CompatibilityMatrix/README.md). The decision on Xcode support: [ADR-019](07_ARCHITECTURE_DECISIONS.md) (accepted: the first integration is xcode-build-server inside SwiftIDE; Xcode projects are experimental).

## What exactly was checked

One `sourcekit-lsp` session on a fixture. Four questions about a file that has an **unsaved edit in memory** (this is how an IDE works):

| Question | What counts as success |
|---|---|
| diagnostics | an error arrived that can be found only by knowing the module's build settings ("cannot convert value of type 'String' to specified type 'Int'" for a method from another file) |
| hover | a type/method from **another file** and from the SDK |
| definition | a jump into another file (another project, a local package) |
| completion | the members of a type from another file |

"Before/after": without a build, after a build, after a server restart, a configuration change, a new file in a target, a path with spaces. Each cell is one run on one machine; this is not statistics.

## Environment (recorded)

| | |
|---|---|
| macOS | 27.0, Apple M2, 8 GB |
| Xcode | 27.0 (27A266a) |
| Swift | 6.4 (swiftlang-6.4.0.34.1); SwiftPM builds into `.build/out/Intermediates.noindex` (that is, through swift-build) |
| SourceKit-LSP | from the Xcode toolchain (`xcrun --find sourcekit-lsp`) |
| sourcekit-xcode-bsp | 0.1.0, commit `726ce70` (2026-09-19), Apache-2.0; swift-build `7f96ee0`, swift-tools-protocols `86ee393` (branch `main`, no lock file in the repository) |
| xcode-build-server | v1.3.0-11, commit `438d0ae` (2026-01-31), MIT, Python 3.9.6 |
| Fixtures | `Fixtures/`: SwiftPMPackage, MacApp (two configurations, differing by a compilation condition), IOSApp (simulator), Workspace (two projects, a local package, a file created by a build script) |

Both candidates declare Xcode 26+. There is no Xcode 26 on this machine: **it was not checked on it**.

## The matrix

OK — all the questions passed. The time is to the first diagnostic (hover, definition, completion are ≤ 0.5 s everywhere, mostly milliseconds).

| Fixture and situation | SourceKit-LSP without a build server | sourcekit-xcode-bsp | xcode-build-server (`parse` of the log) |
|---|---|---|---|
| SwiftPM, without a build | OK, 1.2–2.7 s | not needed | not needed |
| SwiftPM, after a build and after a restart | OK, 1.2 s | not needed | not needed |
| MacApp (.xcodeproj), without a build | **no**: only what is in one file works (a type from the SDK) | OK, 3.5–5 s | no data (a build log is needed) |
| MacApp, after a server restart | — | OK, 4.3 s | OK, 1.4 s |
| IOSApp (platform `iphonesimulator`; UIKit) | — | OK, 5.5 s (restart 3.7 s) | OK, 4.7 s (1.6 s) |
| Workspace: two projects + a local package, **without a build** | — | **no**, except a jump into the local package: "Could not build Objective-C module 'Core'" | no data |
| Workspace after a real build into the BSP root | — | OK, 6.3 s (restart 4.9 s), including the file created by the script | OK, 1.4 s, including the generated file |
| A path with spaces | — | OK | OK |
| A path through a symlink (`/private/tmp/...`) | — | **no**: "Found multiple indexing informations for the same source file" (the form `/tmp/...` works) | OK |
| A new file added to a target while the server is running | — | OK, 6.1 s (the server watches `project.pbxproj`) | OK, 1.3 s (the flags are taken from neighbouring files; the file is not in the log) |
| Switching the Debug/Release configuration | — | see below: **cannot be chosen in `buildServer.json`**; switching `defaultConfigurationName` in the project on the fly: 7.9 s | the flags come from the log of the configuration that was built (Debug confirmed); switching = a new build and `parse` |
| Cost, workspace | — | peak 216 MB (of which 144 MB a short-lived `xcodebuild`), at rest ≈ 27 MB (server 26 + service bundle 28), first diagnostic 4.2 s | peak 35 MB, first diagnostic 2.2 s |

## What turned out to be important

1. **Without a build server an `.xcodeproj` hardly exists for SourceKit-LSP.** Questions about a single file work, everything cross-file is silent. So "Xcode support" is support of a specific build server, not of SourceKit-LSP.
2. **sourcekit-xcode-bsp works on Xcode 27**, although it is declared as "26+", and covers macOS, the iOS simulator, new files and a project change without a build. One exception: **the modules of other targets do not appear without a build.** In Workspace the application imports a framework from a neighbouring project: until that framework is built, the diagnostics and answers are empty. `sourcekit-lsp`'s background indexing does ask for `prepare`, and the server builds `Core.framework` and `LocalKit`, but the framework comes out without a Swift module in `Modules/` ("Could not build Objective-C module"): that does not help. What helped was a real build into the server's root (`xcodebuild … SYMROOT=<buildRoot>/Products OBJROOT=<buildRoot>/Intermediates.noindex`): after it everything works, including the script's file. **A consequence for this candidate: Build must build into its root** (`xcode-build-server` has no such requirement: it reads the log of any build).
3. **sourcekit-xcode-bsp chooses the configuration itself**: it takes the project's default (Release in the fixture) and does not accept a scheme or a configuration in `buildServer.json` (it is not in the sources). For Debug flags today the only option is changing `defaultConfigurationName` in the project, that is, editing the user's project file.
4. **Symlinks in the path break sourcekit-xcode-bsp.** The server normalizes paths through `standardizingPath` (`/private/tmp` → `/tmp`), while swift-build sees the real ones; as a result, "duplicates". For a project in an ordinary user directory this does not show; it will show for projects behind a symlink and for our own tests in temporary folders.
5. **xcode-build-server** is simpler and faster (memory 35 MB, first diagnostic 2 s) and gives **exactly the configuration that was built**, Debug flags included. Its weakness is freshness: until there is a full build log it knows nothing; after changes the flags are taken from neighbouring files or a new `parse -a` is needed. A Python script by a third-party author, the last commit in January 2026.
6. **Versions float.** For sourcekit-xcode-bsp only `swift-build` is pinned to a revision, while `swift-tools-protocols`, `swift-driver` and `swift-llbuild` come from `main`; the build took 5.4 min and 1.3 GB of memory. A reproducible build of the server will need our own `Package.resolved`.

## Not checked (honestly)

### A planned extension: mixed languages (TK-017)

The following rows are a plan per [ADR-021](07_ARCHITECTURE_DECISIONS.md#adr-021-support-for-the-languages-of-a-mixed-swift-project), not the results of existing runs. Support is published for each combination of language and context, separately from the local highlighting of TK-016.

| Fixture | What to check | State |
|---|---|---|
| SwiftPM: Swift + C | A public header, import, unsaved edits in both languages and a jump to a C declaration | Not checked |
| SwiftPM: Swift + C++ | Interoperability, module/header context, the C++ standard, language features and the declared directions of jumps | Not checked |
| Xcode: Swift + Objective-C | A bridging header, the generated Swift header, BSP, scheme/config/destination, before/after Build | Not checked |
| Xcode: Objective-C++ | A `.mm` with ObjC and C++, an ambiguous `.h`, the right mode and compile flags | Not checked |
| C/C++: compilation database | Discovery of `compile_commands.json`, include paths/defines and updating the settings | Not checked |
| Files without a project | Local highlighting without LSP; an explanation of the limits of project features | Not implemented / not checked |

In each project run: completion/diagnostics/hover/definition, restart, delays, a change of language/target and answers of the old context. Record the toolchain, the build settings and the raw answers; mark generated headers and cross-language jumps separately. Details of the fixtures: [12_MIXED_LANGUAGE_SUPPORT.md](12_MIXED_LANGUAGE_SUPPORT.md).

### A planned extension: Bazel (TK-019/TK-020)

Below is a plan, **there are no runs yet**. [ADR-023](07_ARCHITECTURE_DECISIONS.md#adr-023-support-for-bazel-projects), [scope and fixtures](13_BAZEL_SUPPORT.md). The SwiftPM/Xcode results above do not prove Bazel support.

| Configuration / scenario | Criterion | State |
|---|---|---|
| A prepared Swift Bazel workspace, two targets | Real compiler settings; completion/hover/definition/diagnostics between targets on unsaved text | Not checked |
| LSP from Xcode and a suitable upstream distribution | Pinned versions and the differences in bootstrap/indexing; a correct BSP configuration | Not checked |
| Cold/warm, a bounded set of targets | Time to the features and trigger → popup, memory/disk, partial readiness | Not checked |
| A change of BUILD/targets/config/index flags | Updating the context and rejecting old results without editing the text | Not checked |
| Generated files, execution root, symlinks and spaces in the path | Correct URIs, jumps and one session per file | Not checked |
| LSP/BSP restart, hang, cancel and closing the workspace | Timeout, UI state, recovery and termination of the processes owned by the scope | Not checked |
| Swift + C/ObjC/C++/ObjC++ | Each language/platform and jump direction is accepted separately under TK-017 | Not checked |
| Setup UI and Build/Test | Separate stages TK-021/TK-022; the ready capabilities of VSCode do not count as a SwiftIDE implementation | Not implemented / not checked |

For each run record macOS/Xcode/Swift, LSP, BSP, Bazel/wrapper, rules, targets, index flags and the state of the cache/build. No upstream minimums are declared a supported configuration before this run.

### Other limits of the current matrix

- **Xcode 26** and any versions other than 27.0.
- Real projects: ObjC/mixed targets, XCFrameworks and binary dependencies, SwiftUI/macros, test targets, several schemes, App Extensions, Mac Catalyst, visionOS/watchOS.
- SwiftPM plugins that generate sources (only a build script was checked).
- The `kind: xcode` mode of xcode-build-server (it watches logs built by Xcode itself) — only `parse` was checked.
- A real device instead of the simulator; switching the platform on the fly.
- Operation under load: large projects, dozens of targets; the reload time on them.
- The server's background indexing and its behaviour over long operation; leaks.
- Locks: what happens if the IDE and Xcode build into one root at the same time.

## The C family in a SwiftPM package (TK-017, first slice)

The fixture `Fixtures/SwiftPMMixed` (C, C++, Objective-C, Swift). The environment is the same (Xcode 27.0, SourceKit-LSP and clangd from the toolchain). Details and limits: [ADR-026](07_ARCHITECTURE_DECISIONS.md#adr-026-the-c-family-on-sourcekit-lsp-first-slice-of-tk-017).

| Situation | Completion |
|---|---|
| The package is built and lies in `Packages/IDE/.build` or `~/Library/Caches` | C, C++, Objective-C and Swift→C/Objective-C: OK |
| The package is not built | Swift→C/Objective-C OK; in the C files themselves the target's headers are not found, no members are suggested |
| The package is built but lies in `$TMPDIR` (`/private/var/folders/…`) | In C files there are no flags (as without a build); Swift OK |
| A document without a file, language chosen C | OK (the struct's members from the declaration in the text itself) |
| The first ≈2 s after opening a file | A stray list without the project's flags is possible |

Not checked: diagnostics, hover, definition; `compile_commands.json`; Xcode projects and Bazel for the C family; Swift/C++ interoperability; Objective-C++ on the server; a change of flags with a file open.

### Description, definition and diagnostics (second slice, ADR-027)

The same fixture `Fixtures/SwiftPMMixed`, the package is built and lies in `Packages/IDE/.build`.

| Request | Result on a real server |
|---|---|
| hover on a C function from Swift | OK (text with the function's name) |
| definition of a C function from Swift | OK: the declaration in the target's header (the file name with the module map's case: `CLib.h`) |
| definition of an Objective-C method from Swift | OK: the header `ObjCLib.h` |
| definition in the same document | OK, with an offset |
| hover and definition in a C file | OK (the definition — in a header or in the `.c` itself) |
| definition of an SDK symbol (`print`) | a `.swiftinterface` file in the server's temporary folder (`…/sourcekit-lsp/GeneratedInterfaces/…`) |
| Swift diagnostics (`let bad: Int = "text"`) | an error with a range containing the literal; **no version named** (the report is unverified) |
| C diagnostics (`int bad = ;`) | a clangd error on the line |

Not checked: several definitions; a jump into `.build/checkouts`; diagnostics on a change of flags; load (thousands of diagnostics).
