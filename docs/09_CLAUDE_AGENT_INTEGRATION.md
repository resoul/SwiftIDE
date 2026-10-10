# Claude: chat and agent in the IDE

Recorded on 9 October 2026. **Status: an integration plan, with no implementation.** The CLI/SDK were not installed as part of this task; connection, authorization and requests to the model were not performed. This feature does not change the current scope of the TextKit MVP.

## Purpose

The IDE can get a chat for explaining code and an agent mode: reading the project, proposing changes and running checks. A chat with a model and a coding agent are different: the direct Messages API provides the model's answers, while the CLI/Agent SDK additionally provide an agent loop, tools and sessions.

The recommended first scenario: explaining selected code, streaming the answer and cancelling. Editing the project and running tests are added after the document lifecycle and the tool permissions are verified.

## Ways of connecting

| Approach | What it gives | Use |
|---|---|---|
| Claude Code CLI | A local process, structured/streaming events, agent sessions | The initial Swift prototype |
| Claude Agent SDK | An agent runtime, tools, sessions, permission callbacks | A full managed agent mode |
| Direct Claude API | Model answers and streaming; we design the orchestration/tools ourselves | A separate simple chat provider if needed |

The CLI supports programmatic launch with `claude -p` and `stream-json`. The Agent SDK is available for Python and TypeScript; for a Swift IDE a separate helper process with local IPC is assumed. This is a project choice, not a ready Swift SDK in the repository. [CLI documentation](https://code.claude.com/docs/en/headless), [Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview).

A direct HTTP call of the model from Swift is not necessary with the CLI/SDK, but the runtime itself still contacts the provider and requires valid authorization/available limits.

## Authorization and OAuth

For a local prototype, investigate the installed Claude Code with its regular login. The IDE launches the official runtime; it does not extract tokens from its files/Keychain and does not reproduce the internal OAuth flow. [Claude Code authentication](https://code.claude.com/docs/en/iam).

For a distributed product we **do not build in our own claude.ai OAuth button as a guaranteed capability**. The SDK documentation states a requirement of Anthropic's prior approval for third-party products to offer claude.ai login/subscription limits. The base plan is the user's API key or a separately confirmed supported option. [SDK integration restriction](https://code.claude.com/docs/en/agent-sdk/overview).

At the same time a help article updated on 7 October 2026 allows using the SDK, `claude -p` and third-party applications with subscription limits. The user's access and a developer's permission to offer an OAuth login must not be taken for the same thing. Before the public release, clarify with Anthropic whether our particular scenario is covered. [Subscription usage](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan).

An API key, if used, is kept in the macOS Keychain and passed only to the adapter/helper that needs it. Do not write a credential into workspace settings, transcripts or logs. The IDE shows the active way of connecting; it does not promise the same billing/limits for the API and for a subscription. The terms of access are re-checked before implementation and before release.

## Clean Architecture and DI

```text
ChatPanel → AgentSession → CodingAgentProvider
                              ├─ ClaudeCodeProcessAdapter
                              ├─ ClaudeAgentSDKAdapter
                              └─ FakeAgentProvider
```

This is the runtime flow, not the import graph. ChatUI and the concrete adapters depend on the Application port; the Composition Root chooses the adapter. Domain/Application do not import the SDK and do not parse provider JSON.

| Component | Responsibility | Lifetime |
|---|---|---|
| AgentSession | Conversation, request state, context references, cancellation | A chat in the workspace |
| CodingAgentProvider | Starting/continuing a request and typed events | Provider connection/session |
| ClaudeCodeProcessAdapter | Process launch, JSON stream mapping, exits, interruption | The agent runtime |
| ClaudeAgentSDKAdapter | IPC with the helper, sessions, tools/permission callbacks | The helper/runtime |
| ChatPanel / ChatViewModel | Transcript, streaming, tool progress, errors | The panel |
| FakeAgentProvider | Deterministic events for tests | Test |

States: disconnected / ready / running / waitingForAction / cancelling / failed. Events: text delta, tool request/result, usage when available, completion and error. The context contains the workspace generation, the document IDs/versions and the request ID; late events of a closed session are ignored.

The ports are injected through constructors. Credential retrieval and ProcessLauncher are external dependencies of the adapter; ChatViewModel does not read credentials and does not build CLI arguments.

## Editor context and applying changes

The file on disk may differ from the unsaved document. To explain a selection, pass an immutable snapshot with a version and a range. For project operations, define a save/checkpoint policy before the agent is launched; dirty files are not overwritten implicitly.

The first CLI prototype works with read-only capabilities. The text "do not change files" in a prompt alone is not enough to restrict the tools. Later a chosen mechanism for controlling writes is needed: custom tools through the SDK/IPC or isolated staging with a diff review. The built-in CLI Edit writes to disk directly and does not automatically become a DocumentSession transaction.

IDE-managed edits contain expectedVersion and go through the same application transaction/undo path as format/refactoring. On a stale version — a refusal/a repeated suggestion. For closed files, disk revision checks are needed; for cross-file edits — preflight, staging and a recovery policy. External writes are handled by the watcher/conflict flow, not by a silent reload of dirty text.

Running tests uses agreed tool permissions and shows the command, progress and the exit result. Cancellation requires interrupting/terminating the runtime and the child processes; closing the panel must not leave an unknown running job.

## Testing without a mandatory API

| Level | Approach | Real access to the model |
|---|---|---|
| UI/Application | FakeAgentProvider: events, errors, tool decisions, cancel | Not needed |
| Adapter contract | JSON fixtures and a test helper/process: partial frames, exit, stderr | Not needed |
| Document integration | Snapshot versions, stale edit rejection, dirty file conflicts | Not needed |
| Live integration | Opt-in CLI/SDK smoke tests with an available way of auth | Needed |
| Evaluating the agent's quality | A set of tasks and verifiable results/tests | Needed |

Ordinary CI does not require an API key and does not contact the model. Check the streaming order, truncated/unknown events, an interrupted tool call, a runtime exit, an auth error, a rate limit and a workspace close. Live tests run separately with a bounded scope and account for the use of limits/credits.

The model's answer is non-deterministic: check the structure of events, the restrictions on actions and the outcome of the task, not an exact text match. The IDE's unit tests and the project tests run by the agent remain ordinary Swift/toolchain tests.

## Order and future files

1. A fake provider + a chat/session model.
2. The CLI adapter: read-only explanation, streaming/cancel, bounded context.
3. An auth/runtime compatibility spike; check the chosen distribution scheme.
4. An SDK helper if tool callbacks and managed editing are needed.
5. Document-aware tools, diff review and test execution.

Planned files, still absent:

```text
IDEApplication/Agents/CodingAgentProvider.swift
IDEApplication/Agents/AgentSession.swift
IDEDomain/Agents/AgentEvent.swift
ChatUI/ChatViewModel.swift
ChatUI/ChatPanel.swift
AgentInfrastructure/ClaudeCodeProcessAdapter.swift
AgentInfrastructure/ClaudeAgentSDKAdapter.swift
AgentInfrastructure/CredentialStore.swift
IDETestSupport/FakeAgentProvider.swift
Tools/ClaudeAgentHelper/
```

Go/no-go for the agent mode: a confirmed auth/distribution scenario, work with dirty documents, managed writes/tools, cancellation and reproducible offline tests. Neither a CLI prototype nor the use of an API key closes these checks by itself.
