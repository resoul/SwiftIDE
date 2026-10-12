# Remaining Git work

**Recorded:** 2026-10-12, after TK-033/TK-034; updated after TK-037. Tracking branches/upstream (ADR-050) and Stash (ADR-051) are implemented, with manual acceptance pending. The user then approved the entire extended backlog (TK-039), including both GitHub and GitLab; **every entry below is now implemented with automatic validation and pending live acceptance R108–R121** (ADR-053, [contracts and defaults awaiting confirmation](19_EXTENDED_GIT_WORKFLOWS.md)). The entries are kept as the record of the starting backlog.

Implemented baseline: status and file/tab decorations, worktree/index Changes, read-only diff, paginated history, branch inspection, whole-file Stage/Unstage, Commit, local branch creation/switching, Clone, Fetch, reviewed Push, fast-forward-only Pull, conflict resolution, reviewed local Merge/Rebase with Continue/Skip/Abort, tracking/upstream and explicit Stash workflows. Contracts: [workspace and Git](15_WORKSPACE_AND_GIT.md), [conflicts and integration](16_GIT_CONFLICTS_AND_INTEGRATION.md).

## Recommended implementation order

The order below is a recommendation for resuming Git work, not an approved schedule. Assign development task IDs when a slice is selected.

| Priority | Feature | Scope and acceptance |
|---|---|---|
| Done; acceptance pending | Tracking branches and upstream (TK-036) | Create a local branch at a reviewed fetched OID without switching; set/change/remove upstream, inspect actual remote/source and suggest them in Push/Pull. Config/mapping/ref/worktree checks and partial failure are covered; live R94–R98 pending. Per-worktree/inherited branch configuration and ambiguous/unsupported mappings require external Git. |
| Done; acceptance pending | Stash (TK-037) | Newest 200 entries, central read-only diff including saved extras; reviewed create/apply/pop/drop. Tracked-only default, separate explicit untracked/ignored choices and restore-index checkbox. Editor reconciliation, stale list/head checks, conflicts/partial cancellation and post-apply removal covered; live R100–R107 pending. No automatic stash. |
| Done (TK-039); acceptance pending | Stage/Unstage selected hunks or lines | Apply a patch to the intended index state without staging unrelated edits. Reject stale selections; cover independent staged/worktree changes, additions/deletions, encodings and line endings. Explain unsupported binary or oversized cases. |
| Done (TK-039); acceptance pending | Branch, remote and tag management | Review rename/delete branch, add/edit/remove remote and create/delete tag workflows. Explain unmerged branch history and worktree ownership; deleting a remote branch/tag is a separate explicit network action. Local configuration changes must not imply publication. |
| Done (TK-039); acceptance pending | History graph | Render branch/merge lanes over bounded, paginated history with ref labels and selection linked to commit details/diffs. Keep search and loading responsive on large repositories. |

## Conflict and integration extensions (done in TK-039; acceptance pending)

"Currently" in this list describes the state before TK-039; cherry-pick, revert and am pauses now continue, skip or abort in the app.

- Choose Base/Ours/Theirs for individual conflict regions, with source syntax highlighting and synchronized diff scrolling. Preserve the original result editor, native Undo and explicit save/staging boundary.
- Interactive rebase: reorder, squash, fixup and edit, with a reviewed plan and recoverable paused state. Topology-preserving rebase is a separate extension; the current slice accepts a linear range only.
- Keep an empty replay as an explicit empty commit. Currently an empty stopped replay requires Skip/Abort or external Git.
- Support symlink, submodule and directory conflicts, plus paired multi-path rename conflicts. These currently require an external resolver.
- Review an override for intentional literal marker-looking text and raise source-preview limits only with a bounded-memory design. Current conservative checks and limits remain in force.
- Offer an explicit divergence workflow from Pull to reviewed Merge/Rebase. Pull currently remains fast-forward-only; the separate commands already work locally.
- Design continuation for cherry-pick/revert/am and other unsupported operations before exposing corresponding actions. Current operation detection explains that they must be completed externally.

## Optional later scope (done in TK-039; acceptance pending)

These were independent product decisions; the user approved all of them in TK-039:

- Hosting authentication/account UI and GitHub/GitLab pull requests or CI indicators. Current network commands use configured Git credential helpers and OpenSSH mechanisms.
- Explicit discard/revert/reset, cherry-pick and force-with-lease workflows, with concrete review of their effects and document reconciliation.
- Advanced Fetch options such as tags/prune and broader submodule workflows. Current Fetch intentionally has a narrow explicit scope.

## Acceptance and stabilization still pending

Acceptance is separate from missing features. Preserve the existing pending checks in [manual acceptance, section R](10_MANUAL_ACCEPTANCE.md); this file does not mark them passed.

- Run the applicable Git checks R40–R86 in a live workspace, especially network flows R54–R74 and conflicts/Merge/Rebase R75–R86. Include unsaved documents, another project window, restart during a paused operation and external Git changes.
- Verify actual SSH/HTTPS, credential helpers/Keychain and signing, authentication failures, slow/disconnected networks and cancellation after a remote may already have accepted a change.
- Check keyboard routing, real IME, VoiceOver, light/dark appearances, minimum window sizes and conflict-pane usability.
- Measure large histories, long lines and bounded blob/output handling; verify supported Git versions beyond the tested Apple Git 2.54/Xcode 27 environment.
- Recheck the existing foreground-activation App probe in an interactive desktop. Latest full App run: 35/36 passed, with that probe failing; final seven related Git App tests passed. Full package: 953 passed, final focused package: 17 passed; build/lint passed. See [recorded validation](16_GIT_CONFLICTS_AND_INTEGRATION.md#automatic-results) for the limits of those results.

## UI/UX work while Git implementation is deferred

Improve the shared shell, central editor tabs and arbitrary tool panels against [workspace UI/UX](11_WORKSPACE_UI_UX.md). Git Changes, history, diff and conflict views consume that same structure. Preserve document ownership, focus/Undo/save routing, repository ownership and existing explicit action/review contracts. New panels remain usable for Git, AI chat, Docker or other tools through the generic registration mechanism; the editor stays the primary content and can occupy the available workspace when panels are hidden.
