# Agent chat UI (TK-038)

**Status:** native UI and in-memory session implemented; the project uses a labelled local demo. A real provider, authentication, permission prompts and project mutations are separate work. Live acceptance S1–S8 is pending.

## Ownership

```text
AppCompositionRoot chooses the provider
  └─ ProjectWorkspaceController owns one AgentSession per project
       ├─ ChatUI / ChatPanelViewController renders the session
       ├─ IDEApplication / AgentSession consumes typed events
       └─ AgentInfrastructure / DemoAgentProvider produces local examples
```

`IDEDomain` defines immutable editor contexts, messages, stable block IDs and typed text/code/activity events. `IDEApplication` owns request identity, draft, limits, cancellation and error state through `CodingAgentProvider`. `ChatUI` is a separate library target in the existing IDE package, depending on Domain/Application/IconUI; it does not import a concrete provider, read files, launch processes or access credentials. App connects the active editor and native pasteboard. The demo adapter uses no network, shell, model or filesystem.

The Telegram macOS checkout in `refer/` informed native row reuse, bubble layout, Copy and disclosure patterns. Its GPL source, dependencies and assets were not copied, imported or modified. Our message text and input use explicit TextKit 2 graphs.

## Interaction

- Open a folder, then **View ▸ Assistant** or the right tool button. Opening the panel sends nothing. The header explicitly identifies the demo.
- Enter sends; Shift+Enter inserts a line. Native marked text cannot trigger Send. While a reply runs, the next draft remains editable. Stop preserves the partial reply and draft; another request waits for provider cancellation to complete.
- **Add selection** attaches only the selected unsaved editor text, with document ID, path, revision and UTF-16 range. Attachment is explicit, nonempty and bounded; splitting a surrogate pair or capturing during composition is refused. Later edits do not change the saved snapshot. A chip names the file/version and can be removed.
- User messages appear in compact bubbles; assistant content occupies the row. Code cards carry a language label and copy their exact text, including Unicode/newlines. Copy on a message joins its block contents. Activity cards show state and expandable details; in the demo these are simulated descriptions.
- Updates coalesce at 33 ms. Native rows and text views survive text deltas; only changed suffixes/row heights update. The list follows the bottom until the reader scrolls up. Stable message identity plus a pixel offset preserves the reading position during updates/resizing. **Latest response** resumes following.
- The input owns a separate UndoManager. Send clears it as a distinct undoable edit; Undo recovers the draft without resending. Clear is unavailable during a request and explicitly clears history, attachments, draft and input Undo.
- Hiding the panel or using Focus Editor retains the session and draft; responses can finish while hidden. Closing the project stops the session and disconnects its UI. Two project windows have independent conversations. Conversation state is not persisted in UserDefaults or SQL in this slice.

## Bounds and provider contract

Prompt: 64,000 UTF-8 bytes. Context: four selections, 64,000 UTF-8 bytes combined. Response: 256,000 UTF-8 bytes of retained text/code/activity content, 64 blocks; language/title/detail have additional bounds. History retains at most 200 messages, evicting complete earlier turns in pairs, with a 4 MB bound on earlier content and attached snapshots. These are content bounds rather than measurements of total AppKit/process memory.

The provider returns an async throwing stream with stable block IDs and an explicit completion event. Changing a block's type/code language, exceeding limits, ending with a running activity or closing without completion fails the response and preserves partial output. Late events cannot update a cancelled/replaced request. `cancel(requestID:)` must be idempotent and release its producer; the session also calls it after success/failure. Concrete adapters must bound their own queued events and runtime output. This first port contains the current prompt/context; real runtime conversation identifiers/history, timeout, usage and action permissions remain to be designed before connecting a provider.

## Next slices

1. Full Markdown parsing, links and highlighted code; currently ordinary text stays literal and code is a typed monospaced block. These need incremental streaming semantics and selection preservation.
2. Real provider adapter and connection UI, with bounded transport, timeout, authentication and explicit provider state. Recheck the selected provider's integration terms before implementation (docs/09).
3. Multiple conversations and durable transcripts, with workspace identity, migration and a clear retention policy.
4. Tool permission cards and reviewed file changes, routed through the document lifecycle, preserving dirty documents and native Undo. No activity card in this slice applies code or runs a command.

Automated validation and acceptance evidence are recorded in ADR-052; live IME, VoiceOver and subjective latency remain separate acceptance.
