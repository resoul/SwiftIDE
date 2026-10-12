# Workspace components and Git integration

**Status:** accepted direction on 2026-10-10 ([ADR-031](07_ARCHITECTURE_DECISIONS.md#adr-031-workspace-components-git-and-file-status-colours)); TK-025, TK-026, TK-027, TK-028, TK-030 and TK-031 are implemented and tested (2026-10-11, ADR-035/036/037/038/040/041), with live-window acceptance pending. TK-029 Clone/Fetch/Push/fast-forward Pull are implemented (ADR-042/043/044); explicit local conflicts/Merge/Rebase are implemented in TK-033/034 (ADR-045/046); live acceptance pending. Workspace Preview and real project windows use one reusable shell with different providers; normal startup shows Welcome. Preview still contains sample content. This document defines the next working slices while the language/project backend continues separately.

## Interface and implementation order

After the implemented TK-033/TK-034 slices, remaining features and acceptance are collected in [Remaining Git work](17_GIT_BACKLOG.md). Workspace UI/UX is the next active direction.

The user's PhpStorm screenshots are the reference for organization: a welcome window, a project switcher and branch picker in the top bar, Files/Changes on the left, the editor or selected diff in the centre, and Git history in the bottom panel. Keep native macOS interaction, keyboard navigation, accessibility and light/dark appearances.

1. TK-024 extracts reusable project UI into `WorkspaceUI` inside `Packages/IDE` (ADR-030).
2. TK-026 connects Files and tabs to the existing document sessions, replacing the editor placeholder with the real editor.
3. TK-030 connects the common shell to real Files/editor providers before Git; project layout is shared across tabs and persisted by canonical root.
4. TK-025 connects Welcome and the project switcher before Git, against the same project-opening contract.
5. TK-031 moves document tabs into the central content and makes tool registration extensible (ADR-038).
6. TK-027 adds Git Changes and a read-only diff, followed by the branch picker and a paginated history list.
7. TK-028 adds local mutations; TK-029 adds network workflows. A lane graph and staging individual lines/hunks are later work, not prerequisites of the first history/diff slice.

Views can first be exercised with injected sample providers in a clearly labelled preview. This is not integration acceptance. Git does not depend on SourceKit-LSP or target preparation. Project opening and document ownership reuse the TK-018 context contract; UI development may use a substitute until that contract is available, without creating a second root-selection policy.

## Working components

| Task | Scope | Exit criterion |
|---|---|---|
| TK-025 | Welcome window and project switcher | Searchable recent projects with name/path, Open Folder, removing a recent entry without deleting files, handling missing paths; open/recent groups in the switcher; selecting an open project focuses its window. Branch information is optional and does not block the list. Clone is implemented in the first TK-029 slice; project templates and remote development are separate work |
| TK-026 | Files, tabs and path presentation | Lazy directory expansion, file icons, Reveal in Finder, real document opening and tabs; unsaved indicator, existing save/close reconciliation, selection/caret/scroll retained when switching; project exclusions and the colour policy below. Git badges connect with TK-027 |
| TK-030 | Common workspace shell before Git | Same reusable top/status bars, rails and split zones for Preview and real Files/editor; shared persistent project layout, original editor/tabs, disabled unavailable tools; see ADR-036 |
| TK-027 | Git inspection | Detect the repository/worktree; current branch or detached/unborn HEAD; staged/unstaged/untracked lists, read-only diff, searchable local/remote branches and paginated commits with files and changes. No branch switch, stage, commit or network action in this slice |
| TK-028 | Local Git actions | Stage/unstage whole files, commit, create and switch a branch; explicit actions, streamed result/errors and cancellation; reconcile unsaved editor documents before a change of checkout and refresh affected sessions afterwards. No automatic discard/stash/reset |
| TK-029 | Network Git workflows | Clone with destination/progress/cancellation and open on success; fetch and push with credentials through the configured Git mechanisms; pull with an explicit merge/rebase policy and conflict workflow. Local status/history still work offline. Never imply that cancelling a mutation rolls back changes already made |

UI states include loading, empty, unavailable, failed and cancelled. A missing Git binary, no repository or an unfinished refresh must not look like a clean repository. No visible enabled action is a placeholder for an unimplemented workflow.

## TK-026 implementation

**Stability follow-up, 2026-10-12 (ADR-049):** cached children remain visible while refreshing; only changed tree edges are inserted/removed, while decoration/selection changes preserve row/cell identities and the viewport anchor. A failed refresh keeps prior entries with an explicit error row. Git snapshots no longer cause directory reads; coalesced repository disk notifications retain external filesystem refresh, alongside explicit Refresh/save/activation. Live R93 pending.

File ▸ Open Folder now opens a real Files browser using the existing canonical explicit-root policy. Opening a file creates or focuses its existing document session, using the content-owned tab strip of one project window (TK-031 / ADR-038). Each tab retains its original editor, undo manager, selection and scroll view; save, conflict, external-change, recovery, language services and read-only SDK behaviour keep their document controllers. Closing the last tab returns to the empty Files browser. File ▸ Close Project reconciles all current documents before closing any; Close Opened Folders retains its earlier meaning and releases roots/panels while keeping documents.

`IDEApplication/ProjectFiles` owns shared expansion/selection, one-level loading, cancellation/generation checks and exclusion rules. `FileSystemInfrastructure/ProjectDirectoryReader` reads off the main thread. `WorkspaceUI` supplies Files, the resizable container, semantic colours and the content tab strip; App composes them. Refresh reads only expanded folders, on request, activation and a document save. There is no directory event watcher yet, so unrelated external changes while the app stays active require Refresh.

Files offers double-click/Return to open, Reveal in Finder, Exclude/Include and Show Excluded. SwiftPM `.build` defaults are discovered when its parent listing contains `Package.swift`; inclusion overrides and explicit exclusions persist in app settings by canonical root. No manifest is run for tree discovery. Linked folders are visible but not expanded (including a directory replaced by a link); Reveal in Finder explains their handling. Linked files use the existing canonical document registry.

The original TK-026 slice used injected statuses; TK-027 now connects real Git snapshots to Files and central tabs. The injected status model covers independent index/worktree badges, conflicts, ignored reasons, folder aggregation and precedence; this is tested presentation, not observed repository state. Show Ignored becomes available after a successful real Git snapshot, and inherits matching rules into expanded ignored directories. Search/Quick Open are not implemented; their eventual enumeration must consume the same exclusions. The first native-window tab implementation is replaced by TK-031; preview/pinned tabs remain separate work. Selection and expanded folders persist for the open project; sidebar width uses AppKit autosave. Reopening documents/selection across launches is separate work.

## TK-030 implementation

The wider preview layout is now the common WorkspaceUI shell, injected with real Files and the original editor in project windows. TK-031 keeps document lifecycle in retained window-independent editor controllers and hosts them in central content tabs. Layout is shared between a project's tabs and empty browser, persisted by canonical root and independent of Preview/other roots. Focus Editor restores the prior layout; Reset Layout changes geometry without losing text. Small-window compression does not replace saved preferred sizes. The bars consume existing document/target/readiness status; unavailable tools and their menu commands are disabled. TK-027 now supplies inspection data and providers; local/network actions remain later slices. Manual acceptance R21–R24 is pending.

## TK-025 implementation

Normal startup presents Welcome and then scans the existing recovery journal; it does not create a sample Untitled automatically. Explicit File ▸ New retains its scratch workflow, and File ▸ Open opens inside the active project, or as a standalone document when no project is active. Welcome's sidebar has app/version branding, Projects and an unavailable Settings footer; its content has search, Open Folder and recent projects or an empty state. Clone Repository opens its implemented form as a Welcome sheet. New Project and remote-development actions are not exposed before their workflows exist.

Welcome, File ▸ Open Folder and the top-bar project switcher share one validated entry point. A successful opening records the canonical root and focuses an existing project instead of duplicating it. The switcher separates open and recent projects. Closing the last project/document returns to Welcome; closing Welcome leaves the application running. Window ▸ Welcome and Dock reopening show the retained Welcome window. Recovery still offers Restore/Discard per document and retains its disk-conflict and unsaved-text rules.

Recent projects persist as versioned Codable metadata in UserDefaults: canonical path, last successful opening and pinned flag. Pins sort first, then recency; at most 50 unpinned entries are retained. Search matches name/path. Open roots, query/selection and availability stay in memory; root checks are bounded to four background requests and do not enumerate trees, execute manifests or launch processes. Cancelled/older checks cannot overwrite a newer refresh or explicit opening. Missing entries remain visible with Locate/Remove actions. Locate validates the chosen directory, carries the pin and merges a duplicate recent entry; it does not copy settings or configuration trust from the old path. Remove affects only history.

This list is separate from project layout, exclusions, document language choices, configuration permission and crash recovery. SQLite and restoring open tabs across launches are deferred. An unreadable/newer archive is preserved, writes to it are blocked and Welcome displays a warning; new history remains usable for the session. Branch labels come with TK-027. Folder selection, keyboard/VoiceOver, relaunch and recovery interaction remain live acceptance R1–R2 and R25–R29 (ADR-037).

| Data | Storage / lifetime |
|---|---|
| Recent canonical roots, last opening, pin | Versioned UserDefaults archive, app-wide |
| Live projects, query/selection, availability checks | Memory for this app session |
| Preferred workspace panel layout | Existing UserDefaults adapter, by canonical root |
| Project exclusions and inclusion overrides | Existing UserDefaults adapter, by canonical root |
| Manual document language | Existing UserDefaults adapter, by file path |
| Permission for project configuration | Existing UserDefaults adapter, by canonical root; not a safe-opening guarantee |
| Unsaved-text recovery | Existing separate journal in Application Support; independent of Recent |
| SQLite / reopening the previous tab session | Deferred until a concrete workflow requires them |

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


### Content-owned tabs before Git (TK-031)

ADR-038 replaces the first native-window tab slice: a project keeps one window and one Files tree; the editor content owns its tab strip and active document view. Reusable UI stays in WorkspaceUI, document tab state in IDEApplication, service/lifecycle wiring in App. Tool panels are generic registered view hosts, able to contain Git, AI chat, Docker or any later tool. Focus Editor keeps central tabs/editor and temporarily hides surrounding panels/chrome. Panel content and services are independent of document navigation. Git starts after this composition change; editor splits, tear-off tabs and session restoration are outside this slice.


## TK-027 implementation (ADR-040)

Opening a folder composes a project-scoped GitWorkspace and GitCLI. Git reports the actual repository, per-worktree metadata and common metadata paths, canonicalized with the same path policy as documents. A package nested inside a repository inspects that repository; the Changes footer names its root. A non-Git folder or missing/failed Git process has an explicit explanation. An identified older snapshot remains on refresh/error with a previous-snapshot label, rather than becoming a clean list.

`GitInfrastructure` uses the installed `/usr/bin/git`, injectable in tests. Status is porcelain v2 with NUL-delimited paths and complete untracked files; matching ignored directories stay collapsed in Git's report. Batched check-ignore reports the actual source/line/pattern. An ignore rule inherits to visible descendants; project exclusions remain separate. Folder aggregation includes rename source parents and recomputes for changed project exclusions/defaults; excluded untracked files do not invent changes in their included ancestors, while tracked changes remain visible.

Source Control / Command-3 shows Conflicts, Staged, Working tree and Untracked groups. A file present in both index and worktree appears in both groups with distinct comparisons. Selecting a row opens one reusable read-only Diff tab in the central editor area; this is an inspection view without a DocumentSession or save/Undo lifecycle. Its close/Command-W returns to remaining content tabs, and ordinary tab selection restores the retained editor. Git compares disk/index/committed content and never saves unsaved buffers. Binary diffs get Git's explicit binary notice; previews above 512 KB or unsupported encodings explain their limitation.

The top-bar branch control searches local/remote references and explicitly offers View history. It does not switch checkout. The bottom Git Log panel filters the loaded commits by subject/hash/author, loads 50 commits per page, and shows the selected commit's changed files. A file selection opens its diff, comparing a merge to its first parent and supporting root commits/renames. Pagination stays anchored to an object ID; external HEAD changes reset the history to HEAD. Remote references/ahead-behind values are locally known information, with no implied fetch freshness or hosting CI state.

Recursive FSEvents watch the worktree and per-worktree/common Git metadata without enumerating directories. Events coalesce before refreshing Git; expanded Files listings then refresh. Save, Files Refresh, View → Refresh Git and app activation also request refresh. Cancellation, independent request generations and explicit project shutdown reject late status, diff and commit-file results. Refreshing an open comparison updates its view without opening/selecting another tab or taking focus. Process output/time are bounded; diff/textconv/fsmonitor external helpers are disabled and child processes are terminated with their process group where the launched process owns it. Repository/environment routing is explicit; argument arrays never pass through a shell.

Tests include real temporary repositories, initial/detached HEAD, linked worktrees/common ref events, both sides of status, ignores, newline/space/pathspec-like names, conflicts, rename/root-commit history and binary previews; command limits/cancellation/child cleanup; stale requests, exclusions and native UI; and a real project window retaining a dirty editor through diff/background updates. Automated renders were inspected in light/dark appearances. Live keyboard/VoiceOver, larger repositories and subjective latency still need manual acceptance; no live result is claimed on the user's behalf. Stage/unstage/commit/create/switch belong to TK-028; Clone/Fetch/Push/Pull to TK-029.


## TK-028 implementation (ADR-041)

Source Control supplies Stage file and Unstage for the selected whole file. Stage reads current disk bytes (including a deletion/rename pair) and replaces any partial staging; it never saves an editor buffer. Unstage restores the index from the captured HEAD, or removes only index entries in an unborn repository, leaving disk bytes untouched. Conflicts can be staged to mark resolution; resolving their text is the user's responsibility. Changes remain separate from the editor dirty marker.

Commit… opens an in-memory multiline message form; Git → Commit Staged… (Command-K) focuses it in the owning project. Commit includes ALL staged files, without implicit add or commit-all. The current Changes groups show the scope. Blank/oversized messages and unresolved conflicts are rejected. A successful commit clears the draft; failure/cancellation retains it. Configured Git hooks, filters and signing keep their ordinary behavior; subprocess stdin is noninteractive and output is a bounded live preview. The UI provides Cancel and explicitly does not promise rollback.

The branch picker keeps remote refs inspectable. Create at HEAD creates a local branch without switching or setting an upstream. Switch local branch is a separate explicit action; remote tracking-branch creation is deferred. No force/discard/merge/stash/remote guessing or submodule recursion is used. Duplicate/invalid names, conflicting disk edits and a branch checked out in another worktree report Git's failure.

GitWorkspace admits one action at a time, defers its own refresh during the action, rejects old output by operation identity, and refreshes on success, failure and cancellation. GitInfrastructure serializes writes by canonical common metadata inside this process, then checks repository identity and a SHA-256 token of the current porcelain report (HEAD/index/status records) before writing; a selected local ref must still match its captured object ID. This is preflight validation, not an atomic transaction against external Git. Stage still reads current disk bytes rather than an editor/diff snapshot. The process limit for local actions is 120 s, stdout limit 1 MB, delivered output preview 128 KB and retained UI tail 32,000 characters; diagnostic stderr retains its existing bounded tail.

Before switching, App's GitCheckoutCoordinator checks every open document under the canonical worktree root, including other project windows and standalone editors. Dirty documents offer Save or Cancel; IME composition, a failed save, edits made while saving or an outstanding save prevent the switch. After reconciliation, affected editors and their user Undo/Redo are temporarily locked without clearing history; files opened during checkout inherit the lock. The target and original HEAD are checked again after saving. Every prepared exit path unlocks and asks the existing ExternalChangeMonitor to inspect disk: clean documents reload with Undo, while a removed/unreadable file or a newly dirty buffer keeps its text and existing notice/recovery policy. Untitled documents without a repository path are outside this reconciliation.

Reusable action/form/output controls stay in WorkspaceUI, ports and states in IDEApplication, CLI in GitInfrastructure, and document/window ownership in App. No persistent Git cache, credentials, network workflow, hunk staging or merge editor is added. Manual R14–R15/R45–R53 remain pending; automated results are recorded in ADR-041.


## TK-029 first slice: Clone and Fetch (ADR-042)

Welcome and Git ▸ Clone Repository… open a package-owned clone form hosted by App as a Welcome sheet. Enter an HTTPS/SSH/git/file source or absolute local path, choose a parent directory and enter one new directory name. Clone never adopts even an empty existing folder or symlink: an exclusive mkdir reserves the destination. Success is verified as the requested worktree before App opens it and adds its canonical root to Recent through the existing opening contract. Failure/cancel retains the form, output and destination; partial data is left for inspection, without recursive cleanup or a rollback promise. Closing Welcome cancels the owner and rejects late success.

Git ▸ Fetch… opens the branch picker with a configured-remote selector. Fetch explicitly updates `refs/remotes/<name>/*` using `--refmap=` and a heads-only destination refspec. A real test found that an explicit refspec alone still permits opportunistic mappings from `remote.<name>.fetch`; clearing refmap is required. No local heads, index or worktree are updated, so dirty editors stay editable and require no save prompt. Tags, pruning, FETCH_HEAD and recursive submodule fetching are disabled in this slice. Remote names come from NUL-delimited config keys; URLs are not stored in UI snapshots. Per-window last successful fetch time is in memory and is not a guarantee that refs remain current. There is no automatic/periodic fetch.

Fetch shares TK-028's operation state/output/cancel, common-metadata write gate, preflight identity/status check and final refresh, even after failure/cancel. Clone has its own application model and destination gate. Network commands allow only file/HTTP/HTTPS/SSH/git transports, use a 300 s command deadline, 1 MB stdout limit, 128 KB stream preview and 32,000 retained characters. Progress is Git's streamed text, with no invented percentage or completion estimate. stdin is closed, terminal/askpass prompts are disabled; configured Git credential helpers remain available. SSH uses `ssh -oBatchMode=yes` with ordinary SSH configuration, keys and agent; inherited GIT routing variables and custom core.sshCommand/GIT_SSH wrappers are not supported. No credentials are stored by SwiftIDE. Embedded HTTP userinfo, URL passwords/query/fragment and custom transport syntax are rejected, including resolved URL rewrites before networking.

Configured helpers, templates, checkout filters/hooks and SSH/Git configuration can execute external programs; this is not a safe-opening or workspace-trust boundary. Helpers may have their own UI or print arbitrary output; SwiftIDE does not claim universal secret redaction. On cancellation a Git lock or partial ref update may remain; no lock is silently removed. Destination reservation does not defend against a separate process replacing the reserved directory. This first slice does not include Push, Pull, branch tracking creation, conflict editing, custom SSH commands or app authentication UI. Push is implemented in the second slice below; fast-forward Pull is implemented in the third slice below; divergence must stop with an explanation until merge/rebase/conflict recovery is implemented.

Automatic tests use disposable local repositories and a bare remote, a hanging process with a child, a configured credential helper and native model/UI/window integration. SSH/HTTPS servers, Keychain login, unknown hosts, offline retries, keyboard/VoiceOver, actual folder selection and real-window resizing require R54–R60; no manual pass is claimed.


## TK-029 second slice: reviewed Push (ADR-043)

Git ▸ Push… and the branch picker's Push… button open a reusable form as a sheet on the invoking project. Choose an existing local branch, one configured remote and the destination branch name; Review Destination reads configuration without connecting or writing. The review shows the source commit, remote, actual expanded push address (including pushurl/insteadOf/pushInsteadOf), and full destination ref. Changing a field invalidates review. Only the explicit Push button publishes; Return has no publishing shortcut. Empty/unborn or remote-only sources cannot be pushed through this form. Detached HEAD can use an existing local branch. A new destination branch is allowed; upstream configuration is not changed.

GitPushPlanning/GitPushPlan/GitPushReview live in IDEApplication. WorkspaceUI owns selectors, review/output/error/cancel controls; App owns the parent sheet and closes it with its project. Push shares the existing GitWorkspace operation gate/state/stream/refresh. Dirty editors remain editable without save/reconciliation/Undo locks. The form preserves inputs and shows the last submitted destination after failure/cancel; another attempt needs another explicit review.

Before sending, repository/status, the captured source branch and resolved push address are revalidated. Multiple push URLs are refused rather than causing an unseen fan-out. Relative file addresses are resolved against the worktree root for display and command use. The command uses the reviewed URL and immutable commit OID with one explicit `OID:refs/heads/<destination>` refspec. This avoids a hook/ref race changing the commit sent, and bypasses named-remote mirror/custom push mappings and push.default. Force/lease/includes, follow-tags and recursive submodule pushing are disabled; auto upstream setup is disabled. Ordinary pre-push/server hooks and configured signing remain active and can fail. The pre-push hook sees Git's URL-based destination and OID-based source, rather than a named remote/local branch; wrappers that require those names need later design.

Non-fast-forward or policy/auth failures are shown with bounded porcelain/progress output; no automatic Fetch, Pull, merge, rebase or force retry follows. Push does not imply a successful Fetch: local remote-tracking refs/ahead/behind can remain stale, especially because the command deliberately uses the URL. Success means Git accepted this single update (or reported it already up-to-date); cancellation/transport failure can leave the actual remote outcome uncertain. Local refresh still runs, with no claim of rollback or authoritative remote state. The 300 s/1 MB/128 KB stream/32,000-character limits and noninteractive credentials policy of ADR-042 apply. Actual SSH/HTTPS, signing/third-party helpers, network loss after acceptance, live keyboard/IME/VoiceOver and R61–R66 remain pending. This Push slice excludes Pull and conflict recovery; fast-forward Pull is implemented below.


## TK-029 third slice: fast-forward Pull (ADR-044)

Git ▸ Pull… and branch-picker Pull… open the project-owned reusable form. Choose a configured remote and source branch; the current committed local branch is fixed as destination. Review Source shows the actual fetch URL (not pushurl), source ref and local OID without connecting. Then explicit Pull checks/saves or cancels all open worktree documents, fetches just that branch and fast-forwards its frozen fetched OID. Changing fields invalidates review. Detached/unborn HEAD or multiple fetch URLs are unsupported. Upstream configuration stays unchanged.

During document preparation the form frees the parent for save sheets; during network/checkout it returns with output and Cancel. Editors and Undo/Redo are locked after preparation until the action exits. Disk monitors reload clean changed files as undoable edits; dirty/conflicting/unreadable/deleted content retains the existing protective rules. Saving an unsaved tracked file does not make Git clean: Pull refuses remaining tracked/index changes with a commit-first explanation; no stash or discard. Untracked files may remain, with overwrites refused by Git, including ignored paths via explicit no-overwrite-ignore.

Explicit single-head fetch overrides custom mappings/prune/tags/submodule settings, and preserves FETCH_HEAD. Revalidate local identity and state after fetching, freeze the target OID, then `merge --ff-only --no-autostash --no-overwrite-ignore`; configured pull.rebase/autostash cannot trigger merge/rebase/stash. Divergence and ongoing repository operations stop. Failure/cancel may retain fetched refs or an already completed fast-forward (including cancellation during a post-merge hook), so final local refresh and editor disk checks run without claiming rollback. Network/checkout limits are 300/120 s under the shared common-metadata gate; configured credential/helper/hook/filter policy remains unchanged. Live R67–R74, real SSH/HTTPS, network delays and merge/rebase/conflict recovery remain pending.


## TK-033/034: explicit conflicts and local Merge/Rebase

[Conflict/integration contract](16_GIT_CONFLICTS_AND_INTEGRATION.md) (ADR-045/046) defines the central stage context with original TextKit result, frozen saved-result staging, binary/absent/deletion cases and bounds. Git ▸ Merge…/Rebase… reviews immutable targets separately from Pull. Merge stops for commit; linear rebase stops for conflicts/empty replay. Source Control and menu provide actual persistent phase, Continue and confirmed Skip/Abort, with save/cancel/locks/disk reconciliation. Ordinary native Undo survives, and does not undo Git state. Live R75–R86 remain pending.
