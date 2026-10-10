# Workspace: UI and UX

**Status:** the agreed design direction of 2026-10-10. This describes the target interface, not a list of capabilities that are already implemented. Sizes, palette and details are refined on a prototype.

The reference is the provided PhpStorm screenshots: a single window, compact tool strips at the edges, a central editor and flexible auxiliary panels. For SwiftIDE we use this organization of space with the familiar behaviour of a native macOS application.

## Window structure

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Project ▾  Branch ▾       Scheme ▾  Destination ▾  Run / Stop  Search │
├───┬────────────────┬─────────────────────────────┬───────────────┬───┤
│ L │ Left panel     │ File tabs                   │ Right panel   │ R │
│ e │ Files          ├─────────────────────────────┤ Chat          │ i │
│ f │ Search         │                             │ Structure     │ g │
│ t │ Source Control │           Editor            │ Inspector     │ h │
│   │                │                             │               │ t │
│ r ├────────────────┴─────────────────────────────┴───────────────┤ r │
│ a │ Bottom panel: Terminal / Build Output / Problems             │ a │
│ i │                                                             │ i │
│ l │                                                             │ l │
├───┴─────────────────────────────────────────────────────────────┴───┤
│ Ln / Col   Indent   UTF-8   LF         Toolchain / LSP / Indexing      │
└──────────────────────────────────────────────────────────────────────┘
```

The panels in the diagram are open to explain the layout. By default the project tree and the editor are visible; the right and bottom panels are hidden. The bottom panel takes the width of the work area between the tool strips, like the terminal in the reference.

| Zone | Purpose |
| --- | --- |
| Top bar | Project/workspace, Git branch, build scheme, device or destination, Run/Stop and command/file search. For an Xcode project the scheme and destination are visible explicitly: the user understands what is being run. |
| Left strip | Switches for Files, Search and Source Control; in the lower part — Terminal, Problems and Build, which open the bottom panel. |
| Left panel | The file tree, search results or Git changes. The selected tool has its own content and state. |
| Centre | File tabs and the editor. A later stage is splitting the area into several editors. |
| Right strip and panel | Switches for chat, file structure and the inspector. The panel opens at the user's request. |
| Bottom panel | Terminal, build output and diagnostics with switching between the tools. |
| Status bar | Cursor position, indentation, encoding, line endings and the state of the toolchain/LSP/indexing. |

Features are connected as their services become ready. The states "indexing", "limited support" and "server unavailable" are distinguishable from "no errors". An unavailable action explains the reason; decorative buttons do not create the impression of a working build or integration.

## Panel behaviour

1. Clicking a tool opens the corresponding panel; clicking the active tool again hides it. Choosing another tool in the same zone changes the panel's content.
2. The panels can be resized independently in width or height. The dividers look thin but have a comfortable grab area for the mouse and the matching cursor.
3. The minimum sizes do not allow unreadable panels or the disappearance of the editor. When the window is shrunk and restored on another screen, the layout is limited to the available space.
4. The size, visibility and selected tool of each zone are saved per workspace. Hiding a panel keeps its content and state.
5. Opening the terminal or chat by an explicit command moves focus there. Hiding returns focus to the previous editor if it exists, otherwise to the active editor.
6. A background build result, a diagnostic or a chat answer do not grab focus. A new result can be signalled by an indicator on the tool.
7. The Focus Editor command temporarily hides the auxiliary panels. Repeating the command brings back the previous layout.
8. The Reset Layout command returns the initial sizes and visibility of the panels, keeping open documents and unsaved text.

The scenario "tree + editor + chat + terminal" must remain manageable. The user can quickly remove any panel or go into Focus Editor when little room is left for code. Arbitrary dragging of panels between all edges and separate floating windows are not part of the first stage.

## Visual principles

- Code takes the main area. The tools at the edges are always available, and their content is shown when needed.
- The window is perceived as a single space: close background shades, thin borders or small gaps between the areas, moderate rounding.
- In the current prototype the editor and each open panel have a separate surface: a 10 pt corner radius, a thin border and a 4 pt inset inside their zone. The shell's background differs from the panels' background, and the editor is set apart by one more shade. The backgrounds update when the theme changes; the content does not overlap the rounded corners. These values are an initial visual setting for further review.
- One accent marks the selected tool, the active tab and the selection. Errors and warnings have separate semantic colours.
- A panel header is compact: a title, the necessary actions, a menu of additional actions and a hide button. Secondary commands do not take permanent space.
- Icons have a single style, tooltips and accessible names. Activity and focus are indicated not only by colour.
- The light and dark themes are checked together, including a theme change in a running window. The system window buttons, menus, keyboard navigation and VoiceOver support are kept.
- An empty editor offers to open a file, invoke Quick Open and go to recent files, with a few useful key combinations.

Document warnings (an external change, a long line, read-only mode) stay next to the editor and follow the existing priority of the bars. The status bar shows a short state; an explanation and an action are available next to it.

## Tabs and the editor

A tab shows the file name, activity and the presence of unsaved edits. Closing uses the existing reconciliation of unsaved changes. Switching tabs keeps the position, selection and scrolling of each document.

Preview and pinned tabs can be added as a next stage: a modified preview tab becomes an ordinary one. Split editor is introduced after the lifecycle of several views of one document is verified; the shared session and undo must not turn into independent copies of the text.

The provided screenshots show no open code. The editor font, line spacing, the highlighting palette, the cursor, selection and diagnostic marks need a separate visual pass on a real Swift file.

## Implementation order

1. **The workspace shell.** The top bar, two tool strips, a central editor and three panel zones. Simple content allows checking resizing, switching, focus, hiding and layout persistence before all the tools are connected.
2. **Files and tabs.** Connect the tree and the existing document sessions, opening, saving, switching documents and the empty state. Check the document warnings in the new shell.
3. **Tools.** Connect search, Problems, build, terminal and the Xcode context as the corresponding services become ready. The scheme and destination reflect the real configuration.
4. **Later capabilities.** Split editor, structure, inspector and chat. Having room for a right panel does not change the priority of the agent integration from the [separate plan](09_CLAUDE_AGENT_INTEGRATION.md).

A welcome window with recent projects is considered separately. The reference sets the direction for the list of projects and the open actions; creating projects and Clone need their own working scenarios.

## Acceptance of the shell

### The first prototype

A separate window **Window → Workspace Preview** was added; direct launch: `swift run --package-path Apps/SwiftIDE SwiftIDE --workspace-preview`. It has native dividers, switching and hiding of tools, Focus Editor, Reset Layout and layout persistence. The View → Preview: Light/Dark/System Appearance commands change the theme of this window only.

The panels' content is demonstrational, and the centre holds an editor placeholder. The tree does not open files, the terminal does not execute commands, the chat does not send messages. Real documents are still opened in the old windows. The layout is saved as common to the prototype; binding to a specific workspace will appear when projects are connected. Three application tests check the switching of zones, the serialization of the layout and the return of sizes after Focus Editor.

Checked in a live window: opening Assistant/Terminal, returning from Focus Editor, keeping a draft while hiding, and the change of light/dark theme. Resizing and its restoration were checked by a test on native split views; dragging the dividers with the mouse was not confirmed through automation. Full keyboard navigation, VoiceOver and operation in a small window remain for acceptance.

### Target checks

- Each panel opens, switches and hides by a button and by a keyboard command.
- Resizing the two side panels and the bottom panel keeps a usable central area; the result is checked in a small window too.
- Returning focus after hiding a panel works; background events do not change it.
- Focus Editor brings back the original layout, Reset Layout does not lose documents and text.
- Reopening a workspace restores the layout; a smaller screen leaves no elements outside the window.
- The light and dark themes, keyboard navigation and the accessible names of elements are checked in a live window.

These are future acceptance criteria, not a report of checks passed. The exact sizes, palette, typography and key combinations are fixed after the first prototype.
