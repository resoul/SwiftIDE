# Swift IDE — architecture, MVP and a custom Editor Engine

> Version: 0.1 · 9 October 2026 · Status: a historical design of a custom engine

> **A historical concept of a custom engine.** The decision was updated on 9 October 2026: the first version uses NSTextView on TextKit 2; a custom engine is considered after measurements. The current [architecture](docs/02_CLEAN_ARCHITECTURE.md), [development plan](docs/05_DEVELOPMENT_PLAN.md) and [TextKit implementation](docs/08_TEXTKIT_IMPLEMENTATION_PLAN.md) take priority over the choices and timelines below.

## 1. Product vision

A native macOS editor for Swift with navigation and refactoring convenience at the level of JetBrains AppCode and integration with existing Xcode projects. We replace Xcode as the main interface for writing code **without** rewriting the Swift toolchain, SDK and compiler.

**Principles:** Swift-first; a native AppKit UI; responsiveness independent of background indexing; correctness of editing; modularity; compatibility with `.xcodeproj`, `.xcworkspace` and SwiftPM; no changes to project files without an explicit user action.

**Main scenarios:** open an iOS/macOS project, search files and symbols, edit Swift, get diagnostics and completion, jump to a definition, format, build and run through the Xcode toolchain.

### 1.1 Product boundaries

- **Ours:** the editor, the text engine, UX, navigation, search, tab management, Git UI, LSP integration, launching builds.
- **Reused:** SourceKit-LSP, SwiftSyntax, swift-format, SwiftPM, xcodebuild, simctl, the Apple SDK.
- **After the MVP:** LLDB UI, SwiftUI Preview, complex semantic refactoring, plugins, AI, Interface Builder.

## 2. The overall IDE architecture

```text
macOS App (AppKit + SwiftUI panels)
  ├── EditorUI / EditorController
  ├── WorkspaceCore (files, tabs, projects)
  ├── SearchEngine (files, symbols, references)
  ├── LanguageClient (SourceKit-LSP JSON-RPC)
  ├── XcodeIntegration (workspace, targets, schemes, BSP)
  ├── BuildSystem (xcodebuild / SwiftPM / simctl)
  └── GitIntegration
          |
EditorCore (independent Swift package)
  ├── PieceTree / buffers / snapshots
  ├── transactions / changes
  ├── selections
  └── undo/redo
          |
LayoutEngine → RenderEngine (CoreText + Core Graphics)
```

The architecture is a **modular monolith** in Swift; heavy external processes are launched separately. The UI and changes to the active document run on `MainActor`, while LSP, indexing, background layout calculations and I/O work asynchronously on immutable snapshots.

### 2.1 Repository structure

```text
SwiftIDE/
├── Apps/
│   └── SwiftIDE/
│       ├── App/
│       ├── Windows/
│       └── Resources/
├── Packages/
│   ├── EditorCore/
│   │   └── Sources/EditorCore/
│   │       ├── Storage/          # PieceTree, Piece, BufferStore, TreeMetrics
│   │       ├── Document/         # TextDocument, TextSnapshot, TextEdit, ChangeSet
│   │       ├── Selection/        # Selection, SelectionSet
│   │       ├── History/          # UndoHistory, UndoGroup
│   │       └── Coordinates/      # TextPosition, LineIndex
│   ├── EditorUI/
│   ├── WorkspaceCore/
│   ├── LanguageClient/
│   ├── XcodeIntegration/
│   ├── BuildSystem/
│   ├── SearchEngine/
│   ├── GitIntegration/
│   └── Shared/
├── Tests/
│   ├── EditorTests/
│   ├── LanguageTests/
│   └── IntegrationTests/
└── Tools/Benchmarks/
```

## 3. Xcode and Swift Language Services

### 3.1 Integration

- `SourceKit-LSP`: completion, hover, diagnostics, definition, references, symbols.
- `SwiftSyntax`: syntactic transformations/parsing where appropriate; does not replace semantic analysis.
- `swift-format`: formatting.
- `IndexStoreDB`: a possible basis for extended index search.
- `xcodebuild`: building and obtaining project parameters; `simctl`: managing simulators.
- **Build Server Protocol (BSP):** passing the build configuration to SourceKit-LSP for Xcode projects. Investigate `sourcekit-xcode-bsp`, check its limitations and reliability on real projects; do not take it as a guaranteed production solution.

### 3.2 Data flow

```text
User edit
  → DocumentCore.commit (version N → N+1)
      ├── invalidate viewport/layout
      ├── schedule incremental syntax update
      ├── update selections and undo history
      └── serialize LSP didChange in document order
            → SourceKit-LSP ↔ BSP ↔ Xcode build settings
```

LSP uses UTF-16 positions. Change ranges must be translated with the **source version** of the text taken into account, and stale answers must be ignored or correctly carried over between versions. The global index may be incomplete before a build/indexing; the UI must show this state.

## 4. The custom Editor Engine

### 4.1 Architecture

```text
EditorView: NSView + NSTextInputClient
  ├── EditorController (commands, transactions)
  ├── SelectionEngine
  ├── LayoutEngine (visual lines, hit testing, viewport)
  ├── RenderEngine (glyphs, carets, decorations)
  └── SyntaxEngine (tokens, diagnostics)
          ↓
DocumentCore (NO AppKit/CoreText/SwiftUI/SourceKit dependency)
  ├── PieceTree
  ├── BufferStore
  ├── TextSnapshot
  ├── ChangeSet
  └── UndoHistory
```

### 4.2 Storage: an AVL Piece Tree

A **Piece Tree** is chosen — a balanced AVL tree whose nodes refer to ranges of the immutable original buffer or of append-only add buffers. An insertion does not copy the whole file; a deletion changes the structure of the tree. Split/merge, balancing, coalescing of adjacent pieces and subtree metrics are needed.

**Node metrics:** the number of UTF-8 bytes, UTF-16 code units, line breaks; additionally — the information needed for an efficient search of a line and for correct handling of CRLF boundaries. For Unicode grapheme segmentation one cannot limit oneself to a sum of metrics: grapheme boundaries may cross pieces.

**Snapshots:** stable read-only views of the tree. The options: persistent immutable nodes or copy-on-write; handing out a snapshot with a reference to a mutable root is forbidden. Buffers must live as long as snapshots or the history refer to them.

### 4.3 Coordinates

- Inside the Piece Tree — `UTF-8 byte offset`.
- LSP and `NSTextInputClient` — `UTF-16 offset/range`.
- Cursor navigation — Unicode extended grapheme cluster boundaries.
- Layout — visual positions, including bidi and affinity.

```swift
struct ByteOffset: Hashable, Comparable, Sendable {
    let value: Int
}
struct UTF16Offset: Hashable, Sendable {
    let value: Int
}
struct TextPosition: Hashable, Sendable {
    let offset: ByteOffset
    let affinity: Affinity
}
enum Affinity: Sendable { case upstream, downstream }

struct TextMetrics {
    var utf8Count: Int
    var utf16Count: Int
    var newlineCount: Int
}
```

Invariants: all edits validate the boundaries of UTF-8 scalar sequences; user commands do not split grapheme clusters; the chosen policy of handling CRLF and the original line endings is preserved.

### 4.4 The transaction model

```swift
public struct TextRange: Sendable, Hashable {
    public let start: Int // UTF-8 byte offset
    public let end: Int
}
public struct TextEdit: Sendable {
    public let range: TextRange
    public let replacement: String
}
public struct ChangeSet: Sendable {
    public let oldVersion: UInt64
    public let newVersion: UInt64
    public let edits: [TextEdit]
}

@MainActor
public final class TextDocument {
    private var tree: PieceTree
    private(set) public var version: UInt64 = 0

    public func apply(_ edits: [TextEdit]) throws -> ChangeSet {
        // Validate and normalize against the same pre-edit snapshot.
        // Reject/resolve overlaps, apply in descending offset order.
        // Commit atomically, bump version, emit ChangeSet.
        fatalError("Design sketch; implementation pending")
    }

    public func snapshot() -> TextSnapshot {
        fatalError("Design sketch; implementation pending")
    }
}
```

**One transaction** = one commit/version bump, one event for layout/syntax/LSP, one semantic undo record. Multiple edits are given relative to the source version and applied from the end. On an error the state of the document does not change. An example — 200 cursors edit 200 lines at the same time.

### 4.5 Selection Engine

```swift
struct Selection: Sendable {
    var anchor: TextPosition
    var active: TextPosition
    var preferredX: Double?
}
struct SelectionSet: Sendable {
    var selections: [Selection]
    var primaryIndex: Int
}
```

Support: single/multi-cursor, column selection, next/all occurrence, word/line/paragraph navigation, Shift-selection, visual Home/End. `anchor`/`active` keep the direction; `preferredX` is needed for vertical navigation. On edits the selections are transformed through a ChangeSet with explicit rules of affinity and of normalizing overlaps.

### 4.6 Undo/Redo

A history of our own in EditorCore, with no dependency on `NSUndoManager` (the system undo may act as an adapter).

```swift
struct HistoryEntry {
    let forward: [TextEdit]
    let inverse: [TextEdit]
    let selectionsBefore: SelectionSet
    let selectionsAfter: SelectionSet
    let timestamp: ContinuousClock.Instant
    let groupID: UUID
}
```

`inverse` contains ranges in coordinates **after** the forward transaction. Sequential typing is grouped by meaning; cursor movement, paste, formatting and a change of the set of cursors usually close the group. The history has a memory budget and keeps only the buffers/snapshots that are necessary.

## 5. Layout Engine

**CoreText for shaping and measuring**, our own model of lines, viewport, hit testing and caching. Account for emoji, ligatures, tabs, variable fonts, bidi, line breaks and word wrap.

```swift
struct VisualLine {
    let logicalLine: Int
    let byteRange: TextRange
    let origin: CGPoint
    let size: CGSize
    let baseline: CGFloat
    let glyphRuns: [GlyphRun]
    let caretStops: [CaretStop]
}
```

This is a schematic API: `CGPoint/CGSize` belong to the UI/layout module, **not** to the pure DocumentCore. One logical line may produce several visual lines. Caret stops connect byte offsets with visual x positions and affinity.

### 5.1 Virtualization

- Compute layout only for the visible viewport and a small prefetch range.
- `HeightIndex` maps a scroll offset to visual lines/paragraphs.
- Unmeasured lines have estimated heights that are refined at layout.
- When the text changes, invalidate the affected paragraphs and the dependent visual lines, not the whole document.
- Background layout works on a snapshot and is published only for the current version.

## 6. Render Engine

For the MVP — **Core Graphics + CoreText**, not Metal. The renderer receives an immutable layout/display list and does not read the mutable Piece Tree. The initial drawing is through `NSView.draw(_:)`, with CALayer/tiled caching if needed. Metal is possible later after profiling, but will require a glyph atlas and an infrastructure of our own for text quality.

The composition order: background/gutter → selection backgrounds → glyphs with the right selection foreground → diagnostics/decorations → carets/IME. Some overlays and decorations need a separate z-order.

## 7. AppKit Integration

`EditorView: NSView, NSTextInputClient` implements `keyDown` through `interpretKeyEvents`, as well as `insertText`, `setMarkedText`, `unmarkText`, `selectedRange`, `markedRange`, `attributedSubstring`, `firstRect`, `characterIndex`, `validAttributesForMarkedText`, `hasMarkedText`, `doCommand` and the necessary APIs. Add the clipboard, drag/drop, keyboard shortcuts, mouse selection, scrolling and accessibility.

**IME:** a temporary `CompositionSession` with marked text, a selected range and correct display without a premature commit into the document. Check CJK IME, dead keys, the accent picker, emoji, VoiceOver.

```swift
@MainActor
final class EditorView: NSView, NSTextInputClient {
    let controller: EditorController
    let layoutEngine: LayoutEngine
    let renderer: EditorRenderer
    private var markedText: NSAttributedString?
    private var markedRange = NSRange(location: NSNotFound, length: 0)

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func draw(_ dirtyRect: NSRect) {
        renderer.draw(in: dirtyRect, layout: layoutEngine.visibleLayout)
    }
    // Required NSTextInputClient methods omitted in this design sketch.
}
```

## 8. Concurrency

| Component | Execution |
|---|---|
| Keyboard/mouse | MainActor |
| Document mutations | MainActor |
| Selections, undo/redo | MainActor |
| Visible layout | MainActor, bounded work |
| Offscreen layout | Background, immutable snapshot |
| Syntax parsing | Background |
| LSP I/O | Actor/process |
| File loading/saving | Background I/O |
| Rendering | Main thread, prepared data |

Do not route every keypress through an actor hop. For all background results keep the document version; cancel or drop old results. The order of `didChange` within one document must be guaranteed.

## 9. The product MVP

### 9.1 An approximate 8-week plan for a small experienced team

| Period | Result |
|---|---|
| Weeks 1–2 | The basic window, opening files, tabs, buffer, selection, undo/redo |
| Weeks 3–4 | SourceKit-LSP, completion, diagnostics, definition, hover |
| Weeks 5–6 | `.xcodeproj`/`.xcworkspace`, BSP, scheme, xcodebuild |
| Weeks 7–8 | Search Everywhere by files, format on save, Git status, errors |

**A clarification:** this 8-week MVP was proposed before the decision to write a fully custom engine. After that decision the schedule must be recalculated; a full custom layout/rendering/IME in 8 weeks is unrealistic without a substantial reduction of scope or a parallel team.

### 9.2 The plan for the custom engine

| Stage | Content | Rough estimate |
|---|---|---|
| 1 | Piece Tree, snapshots, transactions, Unicode, tests | 2–3 weeks |
| 2 | Multi-selections, history, commands | 2–3 weeks |
| 3 | CoreText layout, visual lines, viewport, rendering | 4–6 weeks |
| 4 | NSTextInputClient, IME, clipboard, accessibility | 3–5 weeks |
| 5 | Syntax highlighting, SourceKit-LSP integration | 2–4 weeks |

The estimates are indicative and optimistic for an experienced developer. Production quality, Unicode edge cases, performance and compatibility with large Xcode projects will require additional time.

## 10. Performance targets (goals, not guarantees)

| Metric | Goal |
|---|---|
| The application window | Under 1 s on a test Mac |
| Opening a 1,000-line file | Under 100 ms without waiting for LSP |
| Input handling | p95 under 16 ms |
| Completion after LSP is ready | p95 under 300 ms on a test project |
| Xcode project | Opening without changing `.pbxproj` |
| Build | An equivalent result to `xcodebuild` with the same settings |
| EditorCore milestone | A 100 MB file, 100,000 random edits with no divergence from the reference |

Test cold/warm startup, different sizes of files and projects, the same hardware, p50/p95/p99, memory usage and indexing time.

## 11. Testing and invariants

- **Differential/property-based tests:** random insertions/deletions and a comparison with a simple reference model.
- **Piece Tree invariants:** AVL balance, metric aggregates, the correct order of pieces, the immutability of snapshots.
- **Unicode:** UTF-8/UTF-16, grapheme clusters across piece boundaries, ZWJ emoji, combining marks, bidi.
- **Newlines:** LF, CRLF, mixed endings, the absence of a final newline.
- **History:** reversibility of edit transactions, multi-cursor, grouping, undo/redo after complex replacements.
- **UI:** IME composition, hit testing, scrolling, word wrap, drag selection, VoiceOver.
- **Integration:** SourceKit-LSP after edits, diagnostics versions, Xcode build configurations, SwiftPM, large projects.

## 12. Decisions and open questions

### Accepted decisions

1. Swift + AppKit as the basis of the macOS application; SwiftUI is acceptable for auxiliary panels.
2. A fully custom Editor Engine instead of TextKit 2.
3. A Piece Tree with AVL balancing and append-only buffers.
4. UTF-8 byte offsets inside; UTF-16 at the LSP/AppKit boundaries.
5. Transactional edits, immutable snapshots, our own selections and undo/redo.
6. CoreText shaping + a Core Graphics renderer at the first stage.
7. Viewport virtualization and incremental layout.
8. SourceKit-LSP and the Xcode toolchain instead of our own compiler implementation.

### Requires research

- Persistent AVL nodes versus copy-on-write for cheap snapshots.
- The strategy of preserving line endings and a byte-for-byte round trip.
- The optimal organization of buffers and the coalescing of pieces.
- Incremental Unicode segmentation across piece boundaries.
- HeightIndex with word wrap and dynamic line heights.
- The real compatibility of BSP with Xcode targets/configurations.
- How far one can go with Core Graphics without Metal.
- Support for huge files, binary detection, encoding detection.
- Crash-safe save: a temp file + atomic replace, preserving permissions/attributes.

## 13. The next milestone: EditorCore v0.1

**Goal:** a standalone Swift Package without UI that can load text, make edits and guarantee the integrity of the result.

**Order of implementation:**

1. Coordinate types, ranges and validation rules.
2. BufferStore and Piece.
3. An AVL Piece Tree with subtree metrics.
4. TextSnapshot and managing the lifetime of buffers.
5. An atomic `apply(edits:)` and ChangeSet.
6. A line index + UTF-8 ↔ UTF-16 conversion.
7. Selection transformations.
8. Undo/Redo and grouping.
9. Property-based/differential tests.
10. A benchmark harness for 1 MB, 10 MB and 100 MB.

**Definition of Done:** 100,000 random operations without data corruption; correct snapshots; undo/redo return the expected text; stable tree metrics; a 100 MB document does not require a full copy on every insertion.

## 14. Useful source projects

- [Swift](https://github.com/swiftlang/swift)
- [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp)
- [SwiftSyntax](https://github.com/swiftlang/swift-syntax)
- [swift-format](https://github.com/swiftlang/swift-format)
- [IndexStoreDB](https://github.com/swiftlang/indexstore-db)
- [sourcekit-xcode-bsp](https://github.com/slime-studio/sourcekit-xcode-bsp) — a candidate for checking, not a pinned dependency

---

*The document records the architecture and plan that were discussed; the Swift examples are design interfaces, not a finished implementation.*
