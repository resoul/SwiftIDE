# Ideas for improving the product

## Assessment of the original idea

The project's strength is the combination of a native interface and the existing Swift toolchain. The current path to a first version uses TextKit 2; a custom engine remains a possible later development. The original document already accounts for the hard things: Unicode, IME, document versions, multi-cursor editing and virtualization. That is a good technical foundation.

The main gap is that the editor implementation is so far better described than the developer's daily experience. I suggest judging each feature by one question: how much faster and more reliable does it make the cycle "find code → understand → change → verify"?

The product promise for the first version: **fast and predictable Swift editing, convenient navigation, and a clear state of the build and of the language services**. AppCode level is a direction of growth, not a criterion for the first delivery.

The direction of supporting related C, C++, Objective-C and Objective-C++ files in mixed Swift projects is accepted. First a shared language choice and local highlighting, then language features on verified build settings. The current implementation supports only Swift; support for each additional language is accepted separately. Scope, order and criteria: [mixed-project support](12_MIXED_LANGUAGE_SUPPORT.md).

## Priorities

Bazel support is accepted as a separate direction: first the language features of an already configured workspace through `sourcekit-bazel-bsp`, then BSP setup and Build/Test. Run/debug/simulator have a separate estimate. There is no integration at the moment; criteria, dependencies and provisional estimates: [Bazel plan](13_BAZEL_SUPPORT.md).

| Priority | What to add | Why | Done when |
|---|---|---|---|
| P0 | Safe saving and recovery of unsaved documents | Protect the result of the work | Restarting after a crash offers to recover the text; a conflict with the disk is not overwritten |
| P0 | Status of the toolchain, LSP and indexing | Explain why completion or symbols are missing | The user sees the reason, the selected Xcode and an available action |
| P0 | Command Palette and a single command registry | Make the IDE usable from the keyboard | Command search, shortcut and availability come from one description |
| P0 | Quick Open by file and navigation history | Speed up the main navigation | Opening a file, back/forward and returning to a position work without LSP |
| P0 | Problems + jump to a build error | Close the loop of verifying changes | A diagnostic opens the right file and the correct position |
| P0 | External file changes / conflict UI | Account for Git checkout and other editors | A clean document is reloaded; a dirty one requires a comparison |
| P2 | Split editor and saving the workspace | Convenient reading of related code | Two views of one document have separate selections and a shared text history |
| P1 | Find in Files with ignore rules and cancellation | Search the project without a ready index | Results stream in, exclusions apply and a request can be stopped |
| P1 | Highlighting of C/C++/Objective-C/Objective-C++ and language choice | Read and change related sources of a Swift project | Works without LSP; `.h` allows a manual choice; changing the language does not change the text/Undo |
| P1 | Language features of mixed projects | Completion, diagnostics and navigation in related sources | Verified for each language and build context; unavailability is explained; colours are not taken as proof of LSP support |
| P1 | Language features of a configured Bazel workspace | Work with the Swift code of a Bazel project in SwiftIDE | A concrete LSP/BSP/toolchain configuration is accepted, preparation/errors are visible, dependent targets and process termination are verified |
| P1 | Format selection / file with a preview of large changes | Predictable transformations | Formatting is one undo group; a stale result is not applied |
| P1 | Git diff and changed-lines gutter | See the context of the current edit | Comparison with a selected base and navigation between changes |
| P1 | Test runner on top of the toolchain | Quickly check a local edit | Run a selected test, cancel, result and jump to the place of the error |
| P2 | Rename with a preview of cross-file edits | Controlled semantic refactoring | Versions, file availability and conflicts are checked before applying |
| P2 | Structure outline, breadcrumbs, inlay hints | Speed up reading | Features depend on capabilities and server state |
| P2 | Settings UI, themes, keymap presets | Adapting to habits | Settings are validated and change without losing the current session |
| P3 | Chat and coding agent based on Claude | Code explanation, then controlled edits and checks | Auth plan, read-only prototype, streaming/cancel and document-aware tools |
| P3 | LLDB UI, SwiftUI Preview, plugins | Extend the IDE after the core is stable | A separate project stage and a measured need |

P0 is a requirement for the first release usable for daily work. Recovery can start after basic save, but must be finished before that release. P1/P2 are the backlog, not a promise to fit into the MVP.

Claude integration is recorded as a separate direction, not a prerequisite of the current MVP. Details: [chat and agent](09_CLAUDE_AGENT_INTEGRATION.md).

## Interface direction

A workspace shell modelled on the PhpStorm references is agreed: a central editor, narrow tool strips on the left and right, resizable panels for files on the left, chat/inspector on the right and terminal/build at the bottom. The top bar shows the project context, scheme and destination; the bottom line shows the state of the document and the services.

By default the project tree and the editor are open. Panels can be toggled and hidden, keep their sizes per workspace and return focus to the editor. Focus Editor temporarily frees space for code. Details, window layout and future acceptance criteria: [workspace: UI and UX](11_WORKSPACE_UI_UX.md).

This is a target design, not a description of an already finished shell. Split editor and chat integration remain later stages; first the layout, resizing and focus are verified with the existing editor.

## What I would change in the original plan

1. Check Xcode language support before weeks of work on the renderer: it is the key promise of the product.
2. Start with a TextKit 2 prototype and end-to-end IDE features. EditorCore is not developed in parallel automatically; first measure the real limits of the backend.
3. Add a document session model, conflict detection, recovery and cancellation. These things are harder to build in once many features exist.
4. Remove the universal `Shared`: every model needs an owner. A large Shared quickly destroys module boundaries.
5. Set a memory budget for snapshots/undo/layout and a large-file mode. 100 MB is a stress benchmark; supported limits are determined by measuring TextKit and the whole edit/snapshot pipeline. The current implementation copies the text.
6. Introduce a capability-based UI: a feature is available when its dependencies are ready. A failed indexing run does not prevent typing and local search.

## Possible distinguishing features

- "Why is this unavailable": a short explanation for completion, refactoring and build, with a jump to the setting.
- "Working context": files, position, scheme and test filter as a saved set.
- Quick navigation through changes: dirty documents, Git diff and errors in a single command flow.
- A project health panel: toolchain versions, readiness, recent failures and restarting a service.
- Transparent refactorings: a preview, the files applied and undo, with no hidden project changes.

These are ideas to be tested on real tasks. First a few Swift developers should be given a small working scenario to carry out, and the time, errors and points of confusion measured.
