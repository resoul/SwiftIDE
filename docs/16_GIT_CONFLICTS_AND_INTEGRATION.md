# Git conflict resolution and Merge/Rebase

**Status:** TK-033/TK-034 implemented on 2026-10-12 (ADR-045/046); live R75–R86 pending. Automatic validation is recorded in the ADRs. These commands are local; Pull remains explicitly fast-forward-only and never initiates merge/rebase automatically.

## Conflict result and UI ownership

Source Control groups unmerged paths under Conflicts. Double-click or Resolve conflict… loads index stages 1/2/3 using NUL-delimited records and immutable blob IDs. Base is the ancestor, Ours stage 2, Theirs stage 3. During rebase Ours is the rebased upstream and Theirs the commit being replayed, not a guess about which work the user owns. Missing stages show Absent, distinct from an empty file.

The context appears inside central content. A regular UTF-8 result already owned by this project uses the ORIGINAL DocumentEditorController below the read-only stage panes: one storage/Undo/caret/save/language graph. Switching tabs detaches/re-attaches that same controller; closing preview restores the normal editor. Use Base/Ours/Theirs replaces result text as one undoable command after checking current stages/operation and document version/composition. It does not save or stage. Save/close/Undo continue to route to the actual document.

Binary/absent results use a central Resolve tool tab, with no invented editable text buffer. A file already owned by another project window remains there; Open result activates it, and repository-wide preparation checks it before writes. Restore side on disk and Resolve as deleted need explicit confirmation, Cancel by default. Restore uses the captured stage blob and executable mode, preserves existing read/write permissions, and leaves the index UNMERGED; reload stages to open a restored text result. Raw blob restoration does not apply smudge filters or line-ending conversions. Text-side choices use the native result's existing encoding/BOM policy. Source previews do not have syntax colouring or synchronized diff scrolling in this slice.

| Layer | Responsibility |
|---|---|
| IDEApplication | GitConflict/side, integration plan/status, typed actions/ports and GitWorkspace lifecycle |
| GitInfrastructure | Status/operation fingerprint, bounded blob/file reads, marker/type/path validation, frozen result staging and local commands under the common-metadata gate |
| WorkspaceUI | Immutable source panes, host-injected result view, buttons/review/status; no process, document storage or window ownership |
| App | Original editor embedding/command routing, save/cancel/locks, confirmation/review sheets, owner cancellation and disk reconciliation |

## Marking a result

Save and mark resolved prepares ALL open worktree documents through the existing save/cancel/composition checks and temporarily locks editing/Undo. It captures the current saved regular file bytes, checks configured conflict-marker-size and conservative marker-like prefixes, hashes those inspected bytes through Git's configured clean filters, checks the resulting blob again, and updates ONLY that path's cache entry. A later worktree read cannot substitute other bytes. External changes during a filter remain on disk and unstaged; filters that introduce markers cannot clear the unmerged index. Clean-filter failure or cancelled hashing can leave an unreferenced object; no false successful resolution is reported.

Deletion stages a deletion, not an empty file. Restoration/deletion require unchanged working bytes/mode since source review. Index stages, repository and operation fingerprints are revalidated; stale views must be reloaded. Other staged files remain untouched. Generic Stage is disabled/refused for unmerged paths so the resolution checks are not silently bypassed. Native Undo changes editor text, not Git index/commits; undoing a result after staging can create an ordinary unsaved/worktree change.

Limits: each stage blob at most 1,000,000 bytes; working/filtered result at most 8,000,000; operation metadata at most 65,536 per file. Binary contents can be restored/deleted or resolved after external editing, but have no binary editor. Symlink/submodule/directory conflicts require an external resolver. Rename conflicts are shown by actual index paths; automatic multi-path rename pairing is not implemented. Conservative marker validation may refuse intentional literal marker-looking lines; stage those through external Git after review. Large files/long lines retain the native editor policy. Unsupported types/encodings/limits are explained and not marked resolved.

## Reviewed Merge/Rebase

Git ▸ Merge… / Rebase… and the branch picker review current local branch/OID, selected locally known branch/OID and repository. Remote refs describe previously fetched information; these commands never fetch or push. Input/head/target changes invalidate review or are refused before execution. The review sheet closes before document preparation so save sheets can use the invoking window. The working index/tracked files must be clean after saves; no stash or discard is automatic. Targets execute by the reviewed immutable OID, with final repository/head/index/operation/target-ref checks.

Merge explicitly uses no-ff/no-commit/no-autostash/no-overwrite-ignore/no-rerere-autoupdate. It preserves history and STOPS BEFORE COMMIT, including a clean merge that could have fast-forwarded. Already-up-to-date can finish without a merge state. Resolve conflicts, enter a merge message, and Continue creates the merge commit from ALL staged contents. Explicit flags override conflicting commit/ff/autostash settings; ordinary configured merge drivers/options and hooks still matter and can cause a refusal or custom resolution.

Rebase uses the merge backend with no autosquash/autostash/rebase-merges/update-refs/fork-point and reapply-cherry-picks/empty=stop. It rewrites only the current branch's linear range; other local refs remain unchanged. A range containing merge commits is refused before starting. It is not interactive rebase. Conflicts and commits becoming empty stop. Continue consumes ALL staged resolution content and keeps the original stored message without opening an editor. If the stopped replay has no staged changes, Continue is refused: explicit Skip or Abort is required, avoiding Git's otherwise implicit empty-commit drop. Keeping an empty replay as a new empty commit requires external Git in this slice.

## Continue, Skip, Abort and restart

GitSnapshot carries actual on-disk operation state and a fingerprint, included in mutation preflight and verified across the multi-command status read. Reopening a workspace sees an existing supported merge/rebase; Source Control shows phase and Continue/Abort/Skip. A stopped rebase may have detached HEAD. An unrelated cherry-pick/revert/bisect/am is reported with instructions to finish it externally; SwiftIDE does not invent its continuation.

Continue waits for all unmerged entries to be resolved. Merge needs an explicit nonempty message. Rebase Skip requires confirmation and can discard staged edits for that replay while proceeding to later commits. Abort requires confirmation and restores Git's original state; on-disk edits made after start can be lost. Unsaved editor buffers still go through Save or Cancel; saving is not a rollback promise. Ordinary disk monitors then reload clean changes as undoable edits or retain deleted/unreadable/conflicting text. Documents opened during an operation join the temporary locks.

The common-metadata gate prevents competing SwiftIDE writes, including linked worktrees. External writers are not atomically locked. Untracked AND ignored paths intersecting checkout/replayed/changed paths are refused before dangerous checkout; comparison is conservatively case-insensitive and includes transient paths from replayed commits. Git merge additionally disables overwriting ignored files. Read/output limits can refuse very large histories before writing.

Local commands are bounded to 120 s, 1 MB stdout, existing bounded streamed/error output and process-group termination. Configured hooks, drivers, clean filters and signing run; noninteractive editor settings do not promise suppression of every helper's own UI. Cancellation/failure can retain fetched refs, edited files, paused metadata or an already completed commit; cancelled hook children are terminated, final local refresh and editor unlock/disk checks still run. No automatic rollback/reset/retry/push occurs. Tested with Apple Git 2.54/Xcode 27; older Git option compatibility, large histories and live usability remain unverified.

Git behavior/reference: [merge](https://git-scm.com/docs/git-merge), [rebase](https://git-scm.com/docs/git-rebase), [unmerged index stages](https://git-scm.com/docs/git-ls-files).


## Automatic results

Full package: 953 tests passed; final focused package: 17 passed. Full App: 35/36, with the existing macOS foreground-activation probe failing unchanged; final seven related Git App tests passed. Build/lint passed with four existing warnings; conflict renders checked in both appearances. Exact run history/findings and pending acceptance are recorded in [ADR-045/046](07_ARCHITECTURE_DECISIONS.md#adr-046-reviewed-local-mergerebase-with-explicit-persistent-continuation-tk-034). No live pass, performance/mutation campaign or action on the user's Git history/index is claimed.
