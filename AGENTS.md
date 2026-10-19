# Architecture rules

Read `docs/02_CLEAN_ARCHITECTURE.md` for module boundaries and the current implementation.

## Composition and factories

- Keep dependency construction in `AppCompositionRoot` and feature-specific factories under `Apps/SwiftIDE/Sources/SwiftIDE/Composition`.
- `AppCompositionRoot` selects concrete infrastructure, configures shared services and supplies models with the required lifetime. Feature factories assemble ready UI modules from explicit dependencies.
- Window controllers and coordinators receive the assembled module or the narrow dependencies they actually use. They own presentation, user actions and lifecycle; do not add service construction or whole feature UI graph assembly to them.
- Views own their controls, constraints and appearance. Reusable view/controller components remain in the appropriate UI package; app factories compose those components.
- A module is a typed object graph with named members, not a generic dependency container. Do not add `Container.shared`, `resolve<T>()` or service lookup inside feature components.
- Use constructor injection and narrow output callbacks/delegates. Models must not depend on concrete window controllers or coordinators. Use weak captures for callbacks that point back to an owner.
- Add a factory protocol only when a real substitution or testing boundary needs it. A concrete factory or injected closure is sufficient otherwise. Split factories by feature as their responsibilities grow.
- AppKit assembly belongs on `@MainActor`. Factories must not initiate user operations, network requests or Git mutations. Owners start those flows after action callbacks and lifecycle handling are connected.

## Lifetimes and cleanup

- Application scope: shared infrastructure, preferences, account services and document registry.
- Project scope: workspace module/window, Files, Git, chat session, layout and document-tab state. Create the module once when a canonical project is opened; reuse its existing owner on subsequent opens.
- Document scope: document session, editor/backend, caret, scroll and Undo state. Keep these instances when switching/reordering tabs or moving a document between hosts.
- Operation scope: an individual task, progress state, review and temporary dialog. Cancel and disconnect it when its owner closes.
- Panel switching, rendering, refresh and appearance changes must not recreate project/document-scoped models or editors.
- Make project module teardown explicit and idempotent. Cancel owner operations, unsubscribe observers and stop project-owned models/controllers. Closing one project must not stop another project's state or shared application services.
- Preserve existing save/close/Undo behavior and the ownership of unsaved documents when moving construction code.

## Applying the rule

- `WorkspaceModuleFactory` assembles the main workspace; `ProjectWorkspaceController` receives a `WorkspaceModule` and binds its actions.
- Existing direct construction in legacy Git dialog routes is migration work, not a template for new features. When extending their assembly, introduce a focused factory rather than expanding dependency wiring in the window controller. Do not refactor unrelated flows merely to satisfy the rule.
- Verify changes with focused tests for object identity, containment, state preservation, project isolation and cleanup. Reuse the existing native integration tests for document editing, chat and Git behavior.
- Follow the pinned formatter and spacing checks described in `docs/14_CODE_STYLE_AND_LINTING.md`; format only files relevant to the change.
