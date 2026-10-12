# Remaining Git work

**Recorded:** 2026-10-12, after TK-033/TK-034. This is a follow-up backlog, not a claim that these features are implemented or an instruction to start them now. The next active direction is workspace UI/UX; Git implementation resumes separately.

Implemented baseline: status and file/tab decorations, worktree/index Changes, read-only diff, paginated history, branch inspection, whole-file Stage/Unstage, Commit, local branch creation/switching, Clone, Fetch, reviewed Push, fast-forward-only Pull, conflict resolution and reviewed local Merge/Rebase with Continue/Skip/Abort. Contracts: [workspace and Git](15_WORKSPACE_AND_GIT.md), [conflicts and integration](16_GIT_CONFLICTS_AND_INTEGRATION.md).

## Recommended implementation order

The order below is a recommendation for resuming Git work, not an approved schedule. Assign development task IDs when a slice is selected.

| Priority | Feature | Scope and acceptance |
|---|---|---|
| 1 | Tracking branches and upstream | Create a local branch from a fetched remote ref; inspect, set and change upstream. Review repository, source ref/OID and destination before writes; handle missing/stale upstream and branches owned by another worktree. Push/Pull may suggest the configured upstream, while retaining explicit destination review. |
| 2 | Stash | List and inspect entries; explicitly create, apply, pop and drop. Choose whether to include untracked files; ignored files require a separate explicit choice. Reconcile open editors, handle conflicts and cancelled/partially completed operations, and preserve an entry if application fails. No automatic stash. |
| 3 | Stage/Unstage selected hunks or lines | Apply a patch to the intended index state without staging unrelated edits. Reject stale selections; cover independent staged/worktree changes, additions/deletions, encodings and line endings. Explain unsupported binary or oversized cases. |
| 4 | Branch, remote and tag management | Review rename/delete branch, add/edit/remove remote and create/delete tag workflows. Explain unmerged branch history and worktree ownership; deleting a remote branch/tag is a separate explicit network action. Local configuration changes must not imply publication. |
| 5 | History graph | Render branch/merge lanes over bounded, paginated history with ref labels and selection linked to commit details/diffs. Keep search and loading responsive on large repositories. |

## Conflict and integration extensions

- Choose Base/Ours/Theirs for individual conflict regions, with source syntax highlighting and synchronized diff scrolling. Preserve the original result editor, native Undo and explicit save/staging boundary.
- Interactive rebase: reorder, squash, fixup and edit, with a reviewed plan and recoverable paused state. Topology-preserving rebase is a separate extension; the current slice accepts a linear range only.
- Keep an empty replay as an explicit empty commit. Currently an empty stopped replay requires Skip/Abort or external Git.
- Support symlink, submodule and directory conflicts, plus paired multi-path rename conflicts. These currently require an external resolver.
- Review an override for intentional literal marker-looking text and raise source-preview limits only with a bounded-memory design. Current conservative checks and limits remain in force.
- Offer an explicit divergence workflow from Pull to reviewed Merge/Rebase. Pull currently remains fast-forward-only; the separate commands already work locally.
- Design continuation for cherry-pick/revert/am and other unsupported operations before exposing corresponding actions. Current operation detection explains that they must be completed externally.

## Optional later scope

These items are independent product decisions, not prerequisites for the implemented basic workflow:

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
