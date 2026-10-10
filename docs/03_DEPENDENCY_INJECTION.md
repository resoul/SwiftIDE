# Dependency Injection: assembly and lifetimes

## Choice

Constructor injection and a single Composition Root in the application. DocumentSession receives DocumentEditingBackend; the root chooses TextKitDocumentBackend for the demo/product and StringDocumentBackend for headless tests. A container library is not needed to begin with: Swift checks dependencies at compile time, and manual assembly shows ownership well.

```swift
// IDEApplication: the contract belongs to the consumer.
public protocol DocumentFileStore: Sendable {
    func write(_ snapshot: DocumentSnapshot) async throws
}

// IDEApplication: a concrete scenario.
@MainActor
public final class SaveDocumentUseCase {
    private let store: any DocumentFileStore

    public init(store: any DocumentFileStore) {
        self.store = store
    }
    // execute(document:) captures the snapshot before the await.
}
```

The current implementation is `Packages/IDE` (`DocumentSession`, `SaveDocumentUseCase`) and `Apps/SwiftIDE/.../AppCompositionRoot.swift`. The snippets here show the shape of the API, not the production implementation of saving.

## Composition Root

```text
AppCompositionRoot
  ├─ SettingsStore
  ├─ ToolchainCatalog
  ├─ ProcessLauncher
  └─ makeWorkspaceScope(rootURL)
       ├─ DocumentRegistry
       │    └─ DocumentSession(backend: TextKitDocumentBackend)
       ├─ FileStore / FileWatcher / RecoveryStore
       ├─ SourceKitLanguageService
       ├─ BuildExecutor
       ├─ Use cases
       └─ makeEditorSession(documentID)
            ├─ EditorController
            ├─ Selection state
            ├─ Native view presentation state
            └─ TextKit NSTextView host
```

Only the root/factories know the concrete infrastructure types. EditorController receives the use cases and the editor session it needs; it does not receive the root and does not call `resolve()`.

## Scope rules

| Dependency | Scope | Why |
|---|---|---|
| Settings/toolchain catalog | App | Shared configuration |
| Process launcher factory | App | A shared launch policy, separate process handles |
| Language service | Workspace + toolchain/config generation | The index, URIs and capabilities are tied to the context |
| Build queue | Workspace | Do not run conflicting jobs in one build root |
| Document file store | Workspace or App | Depends on the access root and the write policy |
| Document registry | Workspace in the MVP | De-duplicating opens and a single owner of the buffer |
| Use cases | Usually Workspace | Workspace dependencies, save serialization shared by its views |
| Native selection/controller | Editor view | One writable view per document in the alpha; split later |
| TextKitDocumentBackend | Document | The only mutable storage; the session holds the backend |
| Change subscription | Consumer in the document scope | Explicit unsubscribe on close, no retain cycle |
| Cancellation handle | Request | Stopping a request does not destroy the workspace |

A new `SaveDocumentUseCase` must not be created on every keystroke if it contains an in-flight guard: the lock would stop protecting competing operations. In production the guard can be moved to a document-scoped SaveCoordinator.

## Shutdown

A scope provides an explicit `close() async`: it marks the generation closed, cancels tasks, drops subscriptions, sends `didClose`, terminates language/build processes with a deadline and releases watchers. Late callbacks check the generation.

`deinit` is a safety net for synchronous resources, not the main async shutdown mechanism. The root holds the scope until closing has finished. Closing a dirty document goes through the UI save/discard/cancel scenario.

## How to choose an abstraction

- A side effect or an external process: a protocol (`DocumentFileStore`, `BuildExecutor`).
- A policy with several real variants: a strategy protocol or an enum, for example the save conflict.
- A simple dependency: a concrete value (`EditorSettings`, `SearchQuery`).
- A small function: a `@Sendable` closure instead of a separate protocol.
- DocumentEditingBackend: a swappable platform implementation; a protocol is justified.
- LineIndex and the internal TextKit components: concrete types. Piece Tree remains a future decision.

A large `Environment` with all the services turns into a service locator even without `resolve()`. Pass exactly the dependencies that are needed. Do not use `shared` for mutable document/workspace state.

## Test implementations

In tests, MemoryFileStore or a controlled actor implementation replaces the disk. It can delay a save, return an error or simulate a conflict. A fake with version-tagged answers replaces SourceKit; a deterministic event stream replaces xcodebuild.

The scenario that is tested: "while version N was being saved, the user typed N+1" → the disk contains N, the document stays dirty. The test must not merely check that a port method was called.

Inject time/UUID only in scenarios where behaviour depends on them: debounce, recovery retention, restart backoff. The internal line-indexing algorithm does not need a DI clock.

## When a container becomes necessary

If manual assembly starts repeating across many targets/configurations, first extract typed factories. Consider a container after a measurable increase in complexity: a compile-time graph/code generation is preferable to hidden runtime resolution. This is a future fork, not a starting dependency.
