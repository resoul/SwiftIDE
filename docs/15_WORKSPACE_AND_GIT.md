# Workspace components and Git integration

**Status:** accepted direction on 2026-10-10 ([ADR-031](07_ARCHITECTURE_DECISIONS.md#adr-031-workspace-components-git-and-file-status-colours)); TK-026 and TK-030 are implemented and tested (2026-10-11, ADR-035/036), with live-window acceptance pending. TK-025 and TK-027–TK-029 remain planned. Workspace Preview and real project windows now use one reusable shell with different providers. Preview still contains sample content. This document defines the next working slices while the language/project backend continues separately.

## Interface and implementation order

The user's PhpStorm screenshots are the reference for organization: a welcome window, a project switcher and branch picker in the top bar, Files/Changes on the left, the editor or selected diff in the centre, and Git history in the bottom panel. Keep native macOS interaction, keyboard navigation, accessibility and light/dark appearances.

1. TK-024 extracts reusable project UI into `WorkspaceUI` inside `Packages/IDE` (ADR-030).
2. TK-026 connects Files and tabs to the existing document sessions, replacing the editor placeholder with the real editor.
3. TK-030 connects the common shell to real Files/editor providers before Git; project layout is shared across tabs and persisted by canonical root.
4. TK-027 adds Git Changes and a read-only diff, followed by the branch picker and a paginated history list.
5. TK-025 (Welcome and project switcher) can proceed alongside Files/Git against the same project-opening contract.
6. TK-028 adds local mutations; TK-029 adds network workflows. A lane graph and staging individual lines/hunks are later work, not prerequisites of the first history/diff slice.

Views can first be exercised with injected sample providers in a clearly labelled preview. This is not integration acceptance. Git does not depend on SourceKit-LSP or target preparation. Project opening and document ownership reuse the TK-018 context contract; UI development may use a substitute until that contract is available, without creating a second root-selection policy.

## Working components

| Task | Scope | Exit criterion |
|---|---|---|
| TK-025 | Welcome window and project switcher | Searchable recent projects with name/path, Open Folder, removing a recent entry without deleting files, handling missing paths; open/recent groups in the switcher; selecting an open project focuses its window. Branch information is optional and does not block the list. Clone is connected in TK-029; project templates and remote development are separate work |
| TK-026 | Files, tabs and path presentation | Lazy directory expansion, file icons, Reveal in Finder, real document opening and tabs; unsaved indicator, existing save/close reconciliation, selection/caret/scroll retained when switching; project exclusions and the colour policy below. Git badges connect with TK-027 |
| TK-030 | Common workspace shell before Git | Same reusable top/status bars, rails and split zones for Preview and real Files/editor; shared persistent project layout, original editor/tabs, disabled unavailable tools; see ADR-036 |
| TK-027 | Git inspection | Detect the repository/worktree; current branch or detached/unborn HEAD; staged/unstaged/untracked lists, read-only diff, searchable local/remote branches and paginated commits with files and changes. No branch switch, stage, commit or network action in this slice |
| TK-028 | Local Git actions | Stage/unstage whole files, commit, create and switch a branch; explicit actions, streamed result/errors and cancellation; reconcile unsaved editor documents before a change of checkout and refresh affected sessions afterwards. No automatic discard/stash/reset |
| TK-029 | Network Git workflows | Clone with destination/progress/cancellation and open on success; fetch and push with credentials through the configured Git mechanisms; pull with an explicit merge/rebase policy and conflict workflow. Local status/history still work offline. Never imply that cancelling a mutation rolls back changes already made |

UI states include loading, empty, unavailable, failed and cancelled. A missing Git binary, no repository or an unfinished refresh must not look like a clean repository. No visible enabled action is a placeholder for an unimplemented workflow.

## TK-026 implementation

File ▸ Open Folder now opens a real Files browser using the existing canonical explicit-root policy. Opening a file creates or focuses its existing document session, using native AppKit window tabs within that project. Each tab retains its original editor, undo manager, selection and scroll view; save, conflict, external-change, recovery, language services and read-only SDK behaviour keep their document controllers. Closing the last tab returns to the empty Files browser. File ▸ Close Project reconciles all current documents before closing any; Close Opened Folders retains its earlier meaning and releases roots/panels while keeping documents.

`IDEApplication/ProjectFiles` owns shared expansion/selection, one-level loading, cancellation/generation checks and exclusion rules. `FileSystemInfrastructure/ProjectDirectoryReader` reads off the main thread. `WorkspaceUI` supplies Files, the resizable container, semantic colours and the native-tab adapter; App composes them. Refresh reads only expanded folders, on request, activation and a document save. There is no directory event watcher yet, so unrelated external changes while the app stays active require Refresh.

Files offers double-click/Return to open, Reveal in Finder, Exclude/Include and Show Excluded. SwiftPM `.build` defaults are discovered when its parent listing contains `Package.swift`; inclusion overrides and explicit exclusions persist in app settings by canonical root. No manifest is run for tree discovery. Linked folders are visible but not expanded (including a directory replaced by a link); Reveal in Finder explains their handling. Linked files use the existing canonical document registry.

Git is not connected: Files explicitly says so and ordinary paths retain the normal foreground. The injected status model covers independent index/worktree badges, conflicts, ignored reasons, folder aggregation and precedence; this is tested presentation, not observed repository state. Show Ignored is disabled until an adapter supplies ignore information. Search/Quick Open are not implemented; their eventual enumeration must consume the same exclusions. Native tabs are the first implementation, not preview/pinned tabs or a custom tab strip. Selection and expanded folders persist for the open project; sidebar width uses AppKit autosave. Reopening documents/selection across launches is separate work.

## TK-030 implementation

The wider preview layout is now the common WorkspaceUI shell, injected with real Files and the original editor in project windows. It retains native document tabs and the existing document lifecycle. Layout is shared between a project's tabs and empty browser, persisted by canonical root and independent of Preview/other roots. Focus Editor restores the prior layout; Reset Layout changes geometry without losing text. Small-window compression does not replace saved preferred sizes. The bars consume existing document/target/readiness status; unavailable tools and their menu commands are disabled. All Git data and actions still belong to TK-027 onward. Manual acceptance R21–R24 is pending.

## File and folder colours

Use semantic colours for names in Files and matching file/tab labels. The colours below are SwiftIDE's accepted policy, inspired by the screenshots, not a promise to reproduce every PhpStorm theme. PhpStorm also distinguishes VCS states and propagates descendant changes to directories. [Reference](https://www.jetbrains.com/help/phpstorm/project-tool-window.html).

| Meaning | Name colour | Additional indication |
|---|---|---|
| Tracked, no disk/index change | Normal theme foreground | No Git change badge; this does not mean there are no unsaved editor edits |
| Untracked, not ignored | Red | `?` / “Untracked”; a newly created file stays red until it is added to the index |
| Added to the index, with no subsequent working-tree change | Green | `A` / “Added” |
| Modified tracked file, staged or unstaged; also a newly staged file edited again | Blue | Separate index/worktree status; preserve both `A` and `M` for an added file edited again |
| Excluded by the project's Files/search policy | Orange | “Excluded from project”; show the rule/source and any independent Git status |
| Ignored by Git | Orange | “Ignored by Git”; show the matching ignore rule where available. This is not project exclusion |
| Renamed or deleted | Blue for a visible changed path; deleted paths remain in Changes | Explicit `R` / `D` and old/new paths for a rename. Do not use orange to mean deletion |
| Conflict | Red with a distinct warning badge | “Conflict”; never rely on the same red used by untracked files to distinguish a conflict |
| Git status not available yet, or no repository | Normal theme foreground | Loading/unavailable explanation where applicable; project exclusions still display independently |

The name-colour precedence is exclusion/ignore (orange), then conflict (red), then modification/rename/deletion (blue), then index addition (green), then untracked (red), then normal. Conflict and Git badges remain visible even when exclusion gives the name its orange colour. Tooltip/context details expose all applicable states. An ignored path is not simultaneously presented as an ordinary untracked path; Git's tracking rules determine ignore status.

Folders aggregate repository statuses, including descendants in collapsed folders: a conflict gets a warning badge; modified/renamed/deleted descendants give blue; only newly staged additions give green; only untracked additions give red; a mix of new staged/untracked entries gives blue with a “Mixed changes” explanation. Excluded/ignored folders and their affected descendants are orange. Merely containing an ignored or excluded subtree does not make an otherwise included ancestor orange or changed. Git-tracked changes remain visible in Changes even if their paths are excluded from Files/search.

Use theme-aware tokens, not colour values copied from one screenshot. Labels, badges and accessibility descriptions explain the status without colour. A selected row must retain readable names and status badges; light/dark switching and increased contrast require manual checks.

## Exclusions and ignored files

Keep project exclusion and Git ignore as independent values with their reasons. A conventional SwiftPM build-artifact directory such as `Packages/IDE/.build` is a default project-exclusion candidate from the project adapter. When excluded, the folder and its displayed contents are orange, as in the user's screenshot. Do not classify every folder named `build`, or every `.bak` file, as excluded. A visible untracked `LanguageServices.swift.bak` remains red unless an actual exclusion/ignore rule applies.

The Files tree shows excluded/ignored entries by default, allowing the user to inspect them, with independent “Show Excluded” and “Show Ignored” filters. Contents are loaded only when expanded; large `.build` trees are never scanned recursively merely to colour their names. Explicit exclusions are kept in workspace/app settings and can be removed; editing `.gitignore` is a separate Git action. Use Git to resolve ignore rules, including negations, repository-local excludes and global excludes, rather than reimplementing a partial `.gitignore` parser. [Git check-ignore](https://git-scm.com/docs/git-check-ignore).

Project exclusions keep those paths out of SwiftIDE's default workspace file search/Quick Open and its own content enumeration. They do not delete files, prevent explicit opening, remove tracked changes from Git, or promise to control SourceKit-LSP/BSP indexing. Build systems may still need artifacts, headers and generated sources under excluded paths. Server-side exclusion/indexing needs an adapter-specific contract and separate verification.

## Architecture and Git adapter

- `IDEApplication` describes repository identity, status snapshots with separate index/worktree states, branches, commits, project path exclusions and the service ports. Use cases own state transitions and document reconciliation without AppKit or Git output types.
- `GitInfrastructure` implements those ports with the selected installed Git through a process adapter. Commands receive executable/arguments separately, without shell interpolation. Process output, errors, cancellation and cleanup are handled off the UI thread. Start with the CLI; the UI does not depend on that choice.
- `WorkspaceUI` owns Welcome, project/branch pickers, Files/tabs, Changes and Log presentation. A reusable read-only text/diff rendering component may live in EditorUI. Do not add a GitUI package until a real boundary calls for it.
- App composes services, chooses the owning project window, connects commands and retains lifecycle/main-menu wiring. Reuse the common context and document registry; a Git repository root may differ from a SwiftPM package root or a linked worktree's metadata location.

Inspect status with `git --no-optional-locks status --porcelain=v2 -z --branch` and parse both index/worktree fields, rename pairs, conflicts, untracked entries and optional headers. Request ignored entries separately as needed without enumerating all ignored descendants. Resolve repository/worktree paths through Git instead of assuming `.git` is a directory. Machine-readable status and NUL-delimited paths avoid ambiguity for spaces/newlines. [Git status](https://git-scm.com/docs/git-status), [Git rev-parse](https://git-scm.com/docs/git-rev-parse).

Read-only diff inspection disables external diff/textconv execution. Bound output and paginate history; binary files and large diffs get an explicit limited preview rather than blocking the UI. Refresh after relevant disk/repository events, explicit actions and regaining focus; coalesce events and reject results from an old repository/workspace generation. Background refresh never steals focus or resets selection/expanded folders.

Git status/diff represent disk and index contents. Unsaved buffers have a separate dirty indicator and are never silently saved to make Git views agree. If a future diff includes unsaved text, label that comparison explicitly. A failure retains an identified previous snapshot or displays an error; it must not silently replace Changes with an empty clean list.

Remote-branch and ahead/behind information refers to locally known refs, with the last fetch identified; network refresh is explicit in the first network slice. CI checks beside commits, as in the reference, require a hosting-service adapter and are not supplied by local Git. GitHub/other hosting integration is separate later work.

## Validation

Use real temporary repositories to compare adapter results with Git: initial and detached HEAD, staged/unstaged combinations, rename/delete/conflict, ignored/excluded paths, spaces/newlines, linked worktrees, external checkout and invalidation. UI tests use providers to verify colour precedence, folder aggregation, selection/focus, exclusion filters and honest unavailable states. Mutating operations test unsaved-document reconciliation and failures without losing buffers. Clone/fetch/push tests use a local bare remote before network/authentication acceptance.

Package tests live alongside the respective application/infrastructure/UI targets; App keeps composition and a few end-to-end checks. Live acceptance is section R in [10_MANUAL_ACCEPTANCE.md](10_MANUAL_ACCEPTANCE.md). The full Git graph, partial staging, merge editor, hosting CI, blame, templates, terminal and remote development remain separate follow-ups.
