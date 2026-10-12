# Extended Git workflows (TK-039)

**Decision:** 2026-10-12. The user requested completion of the entire extended Git backlog and explicitly selected **both GitHub and GitLab** for hosting integration. **State:** all slices are implemented and covered by automatic tests; live acceptance ([manual acceptance R108–R121](10_MANUAL_ACCEPTANCE.md#extended-git-workflows-tk-039--adr-053-pending)) is pending. Nothing in this document marks a manual check passed.

## Implementation slices

| Slice | Scope | Current state |
|---|---|---|
| A | Partial index staging/unstaging, exact frozen bytes and stale selection refusal | Implemented; native/UI tests pass; live acceptance pending |
| B | Branch/remote/tag management and reviewed remote deletion | Implemented; native/UI tests pass; live acceptance pending |
| C | Bounded paginated topology graph and known ref labels | Implemented; native/pure tests pass; visual acceptance pending |
| D | Regional conflict choices, source syntax, linked relative scrolling, literal markers, index-only special-mode resolution, bounded larger previews | Implemented; native/pure tests pass; live acceptance pending |
| E | Interactive linear replay, topology-preserving rebase, explicit empty replay, divergence transition, paired renames and other-operation recovery | Implemented; native/UI tests pass; live acceptance pending |
| F | Reviewed discard/reset/cherry-pick/revert/force-with-lease, advanced Fetch and submodule add/update/sync/deinit/remove | Implemented; native/UI tests pass; live acceptance pending |
| G | GitHub and GitLab accounts, PR/MR list/creation and CI of an exact commit (local HEAD or a selected history commit) | Implemented with injected HTTP/credentials; no real account, Keychain item or publication was used |

## Invariants

The existing native result editor and document session retain text, Undo, versioning, save and IME ownership. Application services own immutable review plans; WorkspaceUI owns presentation; App owns windows, sheets, navigation and document reconciliation. GitInfrastructure owns native Git and later hosting adapters. Tests use disposable repositories and injected HTTP/credential stores. Development does not stage, commit or reconfigure the user's repository.

A cancelled or failed native mutation can already have changed local or remote state. Refresh actual state, retain recoverable operation metadata and report partial effects. Never claim rollback or silently retry destructive/publication actions. Reviews bind repository, checkout, immutable objects and the additional configuration/remote state relevant to the action. SwiftIDE serializes its own writes across linked worktrees; external writers remain outside that gate.

## Index and history

Partial staging reconstructs a candidate index blob from canonical native diff and exact immutable base bytes. Index changes publish through an owned native index lock and alternate index; disk/editor bytes and unrelated staged changes remain intact. Selection bounds are 512 KB of diff and 16 MB of index blob. Filters, working-tree-encoding, sparse/assume-unchanged entries, binary, rename, submodule and mode-only changes explain why partial staging is unavailable. Original full-file actions remain available where supported. New files honor native clean/line-ending normalization.

Repository management reviews actual refs/configuration, worktree ownership and remote addresses. Unmerged branch deletion needs an explicit choice. Remote branch/tag deletion is a distinct network operation using the exact observed remote object as a lease. Tags are lightweight or annotated; this form does not promise signed-tag creation.

History is topologically ordered, paginated, bounded to 5000 loaded commits and up to 512 known reference tips. Filtering hides the graph rather than inventing edges between omitted rows. Labels cover locally known branches and tags; Fetch remains explicit.

## Conflicts and replay

Regional choices replace only one versioned UTF-16 region in the original editor, preserving outside text and native Undo. A Base choice is enabled only when frozen diff3 data has one unambiguous exact matching region. Ambiguous/nested structures require manual editing. Source panes may link **relative scroll positions**; this is not matched-line alignment.

Source blobs retain at most 8 MB each; display and syntax parse at most 128000 UTF-16 units with surrogate boundaries preserved. Short previews never become whole-side replacements. Larger/binary sources and gitlinks remain eligible for reviewed index-only choices, without reading a nested checkout or following a symlink target. Choosing an index stage or deletion leaves every disk byte intact. Removing a directory or submodule checkout is not implied by resolving its index entry.

Interactive replay supports up to 200 linear commits. Every reviewed commit occurs exactly once in the plan, with Pick, Squash, Fixup, Edit or explicit Drop. Squash combines messages; Fixup keeps the preceding message; Edit pauses for changes. The application writes a private native sequence-editor helper containing only whitelisted actions and full validated object IDs. No arbitrary shell commands are accepted. It checks the plan again immediately before starting, and paused state remains in Git metadata after app closure. Topology preservation is a separate Rebase option (`--rebase-merges=no-rebase-cousins`); arbitrary interactive editing of merge topology is not promised.

Originally empty commits are kept. A replay that becomes empty stops for explicit Keep empty, Skip or Abort. Keep verifies the resulting empty child, original author/message and unchanged tree; recovery metadata prevents duplicate empty commits if cancellation occurs after native commit. Refer to [Git rebase documentation](https://git-scm.com/docs/git-rebase) and [index commands](https://git-scm.com/docs/git-update-index) for native semantics.

## Repository operations and submodules

Git ▸ Repository Operations… reviews one typed operation at a time and re-plans immediately before execution; the plan binds HEAD/branch, the index listing, staged and unstaged binary diffs, the full configuration listing and, for network kinds, the advertised remote refs. Discard restores one tracked file from the index (staged bytes stay). Reset soft/mixed/hard moves the current branch to an exact commit; hard reset refuses untracked/ignored collisions. Cherry-pick/revert replay one exact commit, with an explicit mainline for merge commits; conflicts pause in the existing Continue/Skip/Abort flow. Advanced Fetch reads one remote address and fetches heads into its own `refs/remotes/<remote>/` namespace, optionally pruning only there; tags are a separate fetch that never prunes or overwrites local tags. Force push lives in the Push form and uses the exact observed remote object as the lease.

Submodules: **Add** reviews the remote's unique HEAD, clones into a new, empty, symlink-free path with clean parent index/tracked files and stages `.gitmodules` plus the gitlink; a HEAD that moved after review is reported, with partial cloning/staging left for inspection. A relative address is resolved to a concrete absolute path before review (default awaiting confirmation; native relative URLs are not recorded). **Update** initializes/checks out exactly the recorded gitlink with an explicitly passed reviewed URL, without force, recursion or custom update commands. **Sync** copies the `.gitmodules` URL into local configuration. **Deinit** removes a clean checkout and its local registration; parent gitlink, `.gitmodules` and `.git/modules` objects stay. **Remove** removes a clean checkout and stages the gitlink/`.gitmodules` deletion; Git objects stay for recovery. Update, Deinit and Remove refuse nested tracked, untracked **or ignored** content; every existing-submodule kind refuses a nested integration and ambiguous `.gitmodules` mappings, and every kind refuses paths crossing a symlink. Nothing is committed or pushed.

## Hosting (GitHub and GitLab)

Git ▸ GitHub / GitLab… opens a sheet owned by its project window, with an Accounts tab and a PR/MR and CI tab. Account metadata (service, web URL, login; at most 16 accounts) is stored in app settings; tokens are stored only in Keychain (`com.swiftide.git-hosting`, this-device, when-unlocked) behind the `GitHostingCredentials` port, never in source files, logs or UserDefaults. A connection is saved only after the service confirms the login; cancelling a pending connection persists neither metadata nor token. The repository is derived from the selected configured remote, which must have exactly one address on the account's host; credentials never follow cross-host redirects or guessed API hosts. Responses are bounded (2 MB per response, up to 500 records per endpoint, disclosed as partial) and cancellable.

Routes: GitHub REST `user`, `pulls?state=open`, `branches/{branch}`, `commits/{sha}/statuses` plus `commits/{sha}/check-runs`, `POST pulls`; GitLab v4 `user`, `merge_requests?state=opened`, `repository/branches/{branch}`, `repository/commits/{sha}/statuses`, `POST merge_requests` (Draft as a `Draft:` title prefix). Reading is always an explicit Refresh; opening the sheet or choosing an account does not use the network.

CI belongs to one exact full commit SHA (40 or 64 hex digits, normalized to lowercase): local HEAD by default, or the commit selected in History via **CI…**, which opens the same sheet pre-filled with that SHA. After an explicit Refresh the result is labelled on that commit's History row as passed / failed or cancelled / running or pending / partial / none reported / other, with its repository and time; up to 100 labels are kept in memory per project window and are never persisted. A changed local HEAD invalidates creation but keeps the retained CI labelled with its SHA.

Creation reviews source/base/title/body/draft and requires the published source branch to equal the local commit; it is checked again immediately before the request and never pushes. A cancelled or failed creation may already have published a request, so the notice asks to Refresh before retrying. Routes reflect the GitHub REST and GitLab v4 shapes as implemented; they were not re-checked against live documentation or a real account in this session ([GitHub pulls](https://docs.github.com/en/rest/pulls/pulls), [GitLab merge requests](https://docs.gitlab.com/api/merge_requests/)). Tests never sign into an account, write user Keychain items or publish a request.

## Defaults awaiting confirmation

These product choices were taken as defaults while the user was away and are recorded in ADR-053:

- Add submodule resolves a relative address to an absolute local path and clones the remote's default HEAD (no branch choice).
- Deinit/Remove keep `.git/modules` objects; Remove does not commit.
- CI labels in History are in-memory per window (100 commits); "passed" means every reported check is `success`.
- Hosting results are bounded to 500 records per endpoint; at most 16 accounts.

## Validation record

Automatic, 2026-10-12 (local Apple Git 2.54 / Xcode 27 toolchain): full IDE package **1065 tests passed** (67 WorkspaceUI, 46 SyntaxInfrastructure, 214 LanguageInfrastructure, 3 IconUI, 561 IDEApplication, 95 GitInfrastructure, 69 FileSystemInfrastructure, 8 ChatUI, 2 AgentInfrastructure); full App suite **44 tests passed**. The existing foreground-activation probe passed in that final run but failed in one earlier run of this session; it still needs an interactive desktop recheck. TK-039 suites: GitInfrastructure 40 (partial staging 9, management 5, conflict groups 2, special conflicts 4, interactive replay 6, operation recovery 2, repository operations 8, hosting client 4) plus pipe/timeout regressions in GitCLITests; IDEApplication 9 (graph 2, regions 3, hosting workspace 4); WorkspaceUI 6; App 2. `Tools/Lint/lint.sh` passes with the four existing test warnings.

Regressions found and fixed in the final pass: the Add submodule URL field was never placed in the Repository Operations form (so Add could not be used from the UI); a history-commit CI read was announced as "local HEAD" and passed the SHA unnormalized; a partial-staging UI test compared against a diff that the post-action refresh had already cleared. Each got a test that failed first. Eleven single mutants of the new form, hosting and History CI logic were all killed. In App tests, `performClick` on a sheet button stops the test process's main run loop (the remaining suites silently do not run, exit 0); the App test sends the button's action instead. Component renders are written only with `SWIFTIDE_RENDER_GIT_EXTENDED=1` and were inspected in light and dark.

Not verified: real accounts/tokens/Keychain prompts, real GitHub/GitLab responses and permissions, SSH/HTTPS credential helpers and signing, network failure after a remote accepted a change, real IME/VoiceOver, supported Git versions other than Apple Git 2.54, large-repository measurements and every live check in R108–R121.
