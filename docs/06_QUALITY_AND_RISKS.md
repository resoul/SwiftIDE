# Quality, checks and risks

## Definition of Done

A feature is done when the main scenario works, errors/cancellation are understood, the affected invariants are closed, the UI does not wait for long I/O and there are no unfinished tasks after the scope is closed. A stub with `fatalError` does not count as an implementation.

For an alpha release additionally: recovery after a forced termination, no silent overwrite of external changes, verified IME/VoiceOver, a reproducible compatibility matrix and known limitations in the release notes.

## Checks by level

| Level | What we check | Example |
|---|---|---|
| Backend contract | UTF-16 ranges, atomicity, snapshots, versions | The same transaction tests for TextKit and the headless backend |
| Application | Versions, lifetime, side effects | A delayed save + a new edit leave the document dirty |
| Infrastructure contract | Conformance of the port to the OS/process | File conflict; split JSON-RPC frames; stderr flood |
| Integration | Real external tools | SourceKit + a pinned fixture + the selected Xcode |
| UI/manual | Input, geometry, accessibility | CJK composition after scroll/wrap and undo |
| Performance | Latency, memory, scaling | Sequential edits with accumulated history and snapshots |

The target's tests live next to the package (`Tests/<Target>Tests`), and cross-package fixtures separately. The checks do not duplicate the implementation; they prove observable behaviour.

## TK-005: native input/undo/IME

- On a real NSTextView: typing/paste/programmatic replace, undo/redo and a new branch after undo; one document-scoped manager, no double registration and a correct origin.
- Preflight rejection leaves the text/version/undo history unchanged. An unexpected native mutation is reconciled through a correct before/after ChangeSet; repeated callbacks do not increase the version again. A snapshot does not join the new text to the old version.
- Every step of marked text that changes it creates a revision; cancellation returns the text with a new version. Attribute-only changes, selection and unmark without a text change do not create a revision. The end notification arrives even without a text event.
- Save during composition waits for it to finish and writes the resulting snapshot; autosave does not interrupt input. A Save N that finishes after edit N+1 does not clear dirty. Undo to the saved text keeps the version-based dirty.
- LSP receives the composition revisions in order; completion/format do not interfere with the marked range, stale results are dropped after the composition ends.
- Programmatic `insertText`/`setMarkedText`/`unmarkText` check the bridge, but not the whole system input method. Manual CJK IME/dead keys on real input, including cancel, scroll/wrap and undo, are mandatory for acceptance; UI automation complements them if it really uses the needed input source.

## TK-006: open/save and disk revisions

- Real files in a temporary directory: LF/CRLF/mixed without changing the bytes, the BOM is kept, an empty file, a path with spaces and non-ASCII, a file of ≈5 MB.
- Refusal without damage: malformed UTF-8, NUL (binary), UTF-16 BOM, exceeding the limit, a directory, a missing file; reading does not replace bytes.
- Conflict: an external write after the read, including one **with the same inode, size and a restored mtime**; a deleted file, a "new" file that already exists. The file is not changed and no temporary files remain. A touch and an identical rewrite (including with a new inode) are not a conflict.
- Metadata: mode, xattr and ACL are kept; a failure to carry them over aborts the save, the original (inode and bytes) is untouched, there are no temporary files. A symlink is written through to its target and stays a link, a read-only file is not replaced, a hard link is detached after an atomic save (fixed by a test).
- Sessions: one file — one session (another spelling of the path, a hard link, a parallel open); after an atomic save the file keeps its identity under the new inode, a cancelled open registers nothing, a closed document opens again from disk, saving N while N+1 is being edited leaves it dirty.
- Closing and quitting: a clean document does not raise a question; discard/cancel/save; a successful write with N+1 edits does not close the window; a save failure keeps the document; a second Close while a question is open does not multiply sheets; Quit asks only about unsaved ones and stops at the first cancel; a clean document modified during another question, and one saved or discarded and then modified, is asked about again; a window opened during the questions is enabled; "Don't Save" does not cover edits made after the answer.
- Recovery (ADR-016): the write happens no sooner than a 2 s pause and no later than 10 s during continuous typing; Save and Save As delete the record, an edit after Save protects it again; the order of writing and deleting; the text is not copied during marked text; size and state limits; a write failure is visible and retried; a damaged, truncated or modified record is not offered as the user's text but shown as such; permissions 0700/0600; a key cannot create a file outside the directory; a "crash" between launches on real files returns the text, the file is untouched; a file changed between the crash and the restoration gives a conflict on Save; quitting with "Don't Save" leaves no record.
- File watching (ADR-017): the document's own Save, a touch and a rewrite with the same bytes are not a change; a clean document is re-read like an ordinary edit; the user's edits are overwritten neither on reload nor in its race with typing; Keep Mine is silent about that version, but Save conflicts; deletion and return; a file that vanished for a moment; an unreadable change with a reason; Save As carries the watching over; a real file replacement through rename and the next edit of the new file (15 replacements in a row); noise from neighbouring files does not wake the document; cancelling the watch.
- Mutation checks: disabling the content comparison, the metadata transfer (including swallowing the error), the ACL flag and the stale-write check on closing breaks the corresponding tests.
- Not checked by hand: the Open/conflict/closing dialogs and ⌘Q in the application window. Not checked at all: network volumes, an uncoordinated external writer in the narrow window between the check and `rename`, durability on power loss, behaviour with real document-based windows and iCloud.

## Mixed languages (TK-015–TK-017): the check plan

Support for C/C++/Objective-C/Objective-C++ is not yet implemented or verified. Criteria per [ADR-021](07_ARCHITECTURE_DECISIONS.md#adr-021-support-for-the-languages-of-a-mixed-swift-project) and the [plan](12_MIXED_LANGUAGE_SUPPORT.md):

- One language choice is used by highlighting/LSP/commands. A manual `.h` mode, a rename through Save As and a change of target leave no results of the previous context, even when the text version is unchanged.
- For every grammar: strings/comments/preprocessor, unfinished code, UTF-16/CRLF, edits/Undo/IME, theme change and return into the viewport. In `.mm` check Objective-C and C++ constructs at the same time. Colours do not change the text, dirty state or Undo; no server or build is needed.
- Real SwiftPM Swift+C/Swift+C++, Xcode Swift+ObjC/ObjC++ and a C/C++ compilation database: known include paths, defines and language standard; diagnostics depend on the expected settings, completion/hover/definition are checked on unsaved text. Generated headers and jumps between languages are separate results before/after a build.
- Wrong/missing build settings, a missing `clangd`, restart, timeout, a change of language/target and closing the scope: the editor keeps working, old results are not applied. Tests that wait are bounded in time and end with an error rather than a hang.
- Measure typing/memory/highlighting for each language and completion from the trigger to the menu separately from the server RTT. Do not carry Swift measurements over to the other grammars and servers.

## Bazel (TK-018–TK-022): future checks

The integration is not yet implemented. For the spike and acceptance per the [Bazel plan](13_BAZEL_SUPPORT.md): record the LSP/BSP/Bazel/toolchain/rules and the targets/index flags; check cold/warm indexing, unsaved text, completion/hover/definition/diagnostics between targets, changes to BUILD and configuration, execution root paths/symlinks/generated files. Changing the project context with the text unchanged rejects old results. A crash/hang of LSP/BSP, cancellation and closing the scope bound the waiting and terminate the processes owned by the scope; the user sees the preparation, partial readiness and errors.

Setup and Build/Test are accepted as separate scenarios: viewing/saving settings, regenerating the config, save-before-build, streaming results and cancellation. The language features of other languages are checked separately under TK-017; existing SwiftPM/Xcode runs do not count for Bazel.

## Sets of hard data

- An empty file, one very long line, LF/CRLF/mixed, a file without a final newline.
- Cyrillic, CJK, combining marks, ZWJ emoji, regional indicators, bidi; edits on scalar/grapheme boundaries.
- UTF-8 BOM, malformed UTF-8, binary, read-only, symlink, rename/delete during work.
- Programmatic multi-edit replacements of different lengths, identical insertion positions, overlap, a stale transaction.
- Snapshots before/after native undo, a new edit branch, undo groups during IME; old snapshots are unchanged.
- Late completion/diagnostics, restart during didChange, queue overflow. Done in TK-010 ([ADR-020](07_ARCHITECTURE_DECISIONS.md)): the server model is compared with the document after random edits with mixed line endings and surrogates; completion after the recipient changes on a real sourcekit-lsp; a killed server; prolonged crashes; stale answers of five kinds.
- Closing the editor/workspace during reading, save, indexing, build and IME composition.

Random tests record the seed and a minimal reproducible scenario. The number of operations is chosen by the backend's runtime budget; the current planner is O(n). The stress of 100 000 edits from the original plan belongs to the future custom engine and is not an alpha gate for TextKit. A reference comparison can be expensive and is not a benchmark by itself.

## Performance budgets

These are the original goals from the concept plus suggested refinements. Measurements (M2, 8 GB, release, one run): [TK-008](benchmarks/TK-008-results.md) before the pipeline optimization, [TK-011](benchmarks/TK-011-results.md) after; the "Measured" column reflects the latter.

| Metric | Goal | Method | Measured |
|---|---|---|---|
| Cold launch to usable window | Under 1 second | Several cold runs on a fixed Mac | not measured |
| Opening 1 000 lines to usable text | Under 100 ms | From choosing the file to text, without waiting for LSP | 43 ms (warm process) — met |
| Input-to-present | p95 ≤ 16 ms | Event timestamp + layout/render signposts; commit latency separately | 5.7–7.8 ms at any size from 41 KB to 100 MB with honest scrolling and the line-number strip (it was 1.3–1.9 s at 100 MB; the TK-008/TK-011 figures for the middle and the end measured the top of the document, see [TK-007a](benchmarks/TK-007a-results.md)) — **in a synthetic scenario** (keystrokes through `insertText`, drawing into a bitmap); the real latency to the screen has not been measured. Not met for one very long line |
| Completion with LSP ready | p95 ≤ 300 ms | From trigger to popup; server RTT separately | not measured |
| TextKit backend 1/10/100 MB | Determine supported limits for input/memory | The current O(n) planner/snapshots; measure the full pipeline | Opening 100 MB 0.45 s, memory ≈5.4× the file after opening, peak 0.78 GB; editing within budget up to 100 MB; saving grows linearly (≈0.45 s per 100 MB) |
| Snapshot/history retention | A configurable budget | Current bytes, retained bytes, count and eviction events | not measured |
| Layout scrolling | No full relayout of the file | The number of layout paragraphs per viewport update | Jump and drawing ≤ 6 ms at 100 MB — met (the number of paragraphs was not counted). One line: ≈1.3 ms per KB, the budget is broken above ≈10 KB |

16 ms is the initial goal, not a universal frame budget for 120 Hz. State the refresh rate and the load. Choose the exact memory limits and the giant-line threshold after the M0/M1 measurements; until then do not promise numbers.

Profile cold/warm, p50/p95/p99, the maximum, peak RSS, indexing CPU and the memory of snapshots/native history. Run an ordinary Swift file, a large generated file and a giant line. Measuring tools are not in the release hot path unless necessary.

## Risk register

| Risk | Probability / damage (estimate) | Early check | Response |
|---|---|---|---|
| Xcode/BSP does not cover all projects | High / high | M0 fixture matrix ([first slice](11_COMPATIBILITY_MATRIX.md): without a Build the modules of neighbouring targets are unavailable; sourcekit-xcode-bsp has no choice of configuration; symlinks in the path break it) | Limited support, a build-only fallback, moving the promises |
| Mixed code gets a wrong language or build settings | High / high | TK-015–TK-017: `.h` in different modes, `.mm`, includes/defines, a change of target, generated headers | A shared document language, a manual choice, a context revision; highlighting/LSP are accepted separately per language and project |
| The native bridge breaks IME/undo/accessibility | Medium / high | NSTextView native input fixtures | System behaviour is preserved; manual tests are mandatory |
| Bazel BSP/LSP or the index build is incompatible with the project | High / high | TK-019: a pin of the toolchain/rules, targets/flags/WMO, generated sources and cold/warm indexing | An experimental matrix, a choice of LSP, status/timeout; a limited set of targets and a separate check of the cache/output base |
| Fallback to TextKit 1 | Medium / medium | Modern manager check + switch notifications | Do not touch the legacy layoutManager; check the UI integrations |
| Snapshot/planner/undo consume memory | High / high | Full-pipeline benchmark | Measure copies, bounded parsing, limits and retention budgets |
| UTF-16/line mapping or grouped changes are incorrect | Medium / high | Scalar/CRLF/native batch fixtures | Typed ranges, exact old/new snapshots, a coherent ChangeSet |
| A stale async result changes the current text | Medium / high | Controlled fakes | Version/context validation after an await |
| An external writer loses edits | Medium / high | Save race + watcher tests | Revision check, coordination, conflict flow, recovery |
| A long line blocks layout/planner | Medium / high | Giant-line fixture | Measured limits and an explicitly chosen degraded mode |
| Logs/indexing overload the UI | Medium / medium | Flood/cancel tests | Backpressure, batching, bounded queues |
| The architecture grows into features | Medium / medium | A graph review at milestones | A small set of targets, typed factories, narrow ports |

## Diagnostics and CI

TK-023 is implemented: [formatting and linting](14_CODE_STYLE_AND_LINTING.md) (`Tools/Lint/lint.sh`). SwiftFormat is the only formatter; SwiftLint and an additional syntax check enforce the chosen rules. The versions/config are the same locally and in CI; the check does not rewrite the sources. Criteria: examples of blank lines/parameters, no false positives, idempotence of formatting and consistency of the whole pipeline. Connecting the tools and the mass formatting are separate commits; after the latter a build and tests are mandatory. The CI workflow is written and has passed on a runner (the `xcode-27` image).

For the future Claude chat/agent, ordinary CI uses a fake provider, event fixtures and a test process, with no model/API key. Live CLI/SDK tests and an evaluation of the model's quality run separately, opt-in. The checks of dirty documents, stale edits, cancellation and auth errors are described in the [integration plan](09_CLAUDE_AGENT_INTEGRATION.md).

Structured logs: subsystem, workspace/session generation, operation ID, duration, outcome. By default without the full text of the user's files and without the content of a completion request. Exporting a diagnostic bundle is an explicit command with a preview of what it contains.

The first CI: build + application/backend tests on macOS in Swift 6 mode. The integration job is macOS with a pinned Xcode; the performance baseline is a dedicated identical Mac, do not compare the absolute numbers of different CI hosts. The UI/manual checklist is tied to the release candidate.

A check of the dependency graph can begin with `Package.swift` and the imports. An automated guard is added when a production graph appears. The example already uses SPM targets, which limit compile-time imports.
