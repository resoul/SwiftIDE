# Manual acceptance: what to check by hand

Compiled on 2026-10-10. This is a list of what the automated tests do not cover or cover only through substitutes (an off-screen window, `insertText` instead of the keyboard, a bitmap instead of the screen). Each item gives what to do, what should result, and what has already been checked automatically, to avoid repeating the unnecessary. If an item does not work, send which one and what you saw; I will write a test that reproduces it before fixing.

Running the application from the repository:

```bash
swift run --package-path Apps/SwiftIDE SwiftIDE
```

Files for the checks (created in `/tmp`, not in the repository):

```bash
# a line of 33,000 characters (a minified file)
python3 -c "print('let values = [' + ', '.join(str(i) for i in range(6000)) + ']')" > /tmp/long-line.swift
# a file of about 6 MB: above the highlighting limit (5 MB)
python3 -c "print('let a = 1\n' * 600000, end='')" > /tmp/big.swift
# a small file for pasting large text: copy the contents of /tmp/big.swift
python3 -c "print('struct A { var b = 1 }\n// comment\nlet s = \"x\"', end='')" > /tmp/small.swift
```

## Results of the manual runs

The user ran these items in a live window and reported them as working (2026-10-10, one run each, on one machine). ✅ marks them in the tables below.

| Section | Items passed | Not yet run |
|---|---|---|
| A. Highlighting | A1–A5 | |
| D. Editing | D1, D5 | D2 (IME), D3, D4, D6, D7 |
| E. Saving and closing | E1, E2 | E3 |
| F. Recovery | F1, F2 | F3–F16 |
| G. File watching | G1–G7 | G8–G15 |
| K. Swift completion | K1 | K2–K20 |
| P. Description, jump, diagnostics | P21 | P1–P20, P22 |
| Q. Readiness, progress, trust, opened folders, targets (TK-018) | | Q1–Q25 |
| Q. Reusable workspace UI (TK-024, planned) | | Q13–Q14; repeat Q8 after extraction |
| R. Workspace and Git (TK-025–TK-029, planned) | | R1–R16; run each slice when implemented |

Everything else in the sections B, C, H, I, K, M, N, O and P is still unchecked by hand; the earlier statements "not checked in a live window" stay true for those items.

## A. Highlighting (TK-007)

| № | Do | Expected | Already checked automatically |
|---|---|---|---|
| A1 ✅ | ⌘O → `/tmp/small.swift` | Colours of keywords, strings, comments. Window subtitle: "TextKit 2". | Pixels in the light theme; both themes by eye from screenshots (readable) |
| A2 ✅ | Switch the system appearance light ↔ dark with the window open | The colours change by themselves and stay readable | Only screenshots of the two themes; I did not check the change on the fly |
| A3 ✅ | Type `/*` at the start of the file | Everything below turns grey (a comment). Type `*/` — the colours come back | Tests and a screenshot |
| A4 ✅ | Scroll down, return up after edits | No stale colours in a place already seen | Tests (with TextKit off screen) |
| A5 ✅ | Fast, continuous typing in a large file | Input without delays; the colours catch up within fractions of a second | Benchmark: input ≈ 9 ms with highlighting; colours ready after 57 ms (10 MB) after a burst |

## B. File size and type (new, remarks 1–2)

| № | Do | Expected | Already checked automatically |
|---|---|---|---|
| B1 | Open `/tmp/small.swift`, paste the contents of `/tmp/big.swift` at the end (⌘V) | The colours disappear from the **whole** window, the subtitle says "syntax colours off: large file". Typing is still smooth | The controller and pixels (at a small limit). At a real 6 MB — no |
| B2 | Immediately ⌘Z | The text is back; the colours return (no sooner than the text becomes smaller than 4.5 MB) | The logic and hysteresis — by tests; at 6 MB — no |
| B3 | Open `/tmp/big.swift` | Opens without colours, the subtitle says "syntax colours off: large file" | Only at a small limit |
| B4 | Memory: Activity Monitor, B1 before and after the paste | Memory grows by the pasted text itself, not by +500 MB of tree and a copy of the highlighter | Not measured in a window; the benchmark gives +503 MB at 10 MB when highlighting is on |
| B5 | A `.txt` file with Swift code → Save As… → `Name.swift` | Colours appear, the subtitle has no note | Test |
| B6 | A `.swift` file → Save As… → `Name.txt` | Colours disappear | Test |
| B7 | Open a file, enlarge it on disk with another program (above 5 MB), in the window — "Reload from Disk" | After the reload the colours are off | Test (at a small limit) |

## C. Long lines (TK-012, step 1)

| № | Do | Expected | Already checked automatically |
|---|---|---|---|
| C1 | Open `/tmp/long-line.swift` | A yellow bar above the text: "This file has a line of … characters…", buttons "Make Read-Only" and "Keep Editing". The window is open **for editing** | The bar in a test and in a screenshot (two themes). **Not seen in a live window** |
| C2 | "Make Read-Only" | Typing is impossible, the subtitle says "read-only", the bar: "This window is read-only…" with "Allow Editing" | The logic; the buttons in the window — no |
| C3 | "Allow Editing" | You can type; the bar does not return | the same |
| C4 | Open again, "Keep Editing" | The bar disappears and does not return while the document is open | The logic |
| C5 | Shorten the line below 16,000 characters | The bar disappears by itself (if you did not press "Keep Editing") | Test |
| C6 | Paste a long line into an ordinary file | The bar appears | Test |
| C7 | Typing in the longest line | **Expectedly slow** (step 1 only warns); note how slow | Measurement: ≈ 150 ms per keystroke at 100 KB |

## D. Editing: what I could not check (needs keyboard and mouse)

| № | Do | Expected |
|---|---|---|
| D1 ✅ | Type a few words in a coloured file, ⌘Z, ⇧⌘Z | Undo and redo by words as usual; highlighting creates no undo steps of its own (window title: the "edited" mark disappears after undoing everything) |
| D2 | **IME** (Japanese, Chinese or Korean): type a composition in the middle of a code line and inside a comment, confirm with Enter | The text is inserted correctly; the colours do not flicker during the composition and update after it; Backspace in the composition works |
| D3 | Dead keys: Option+E, then e (é), Option+U, u (ü) | The character is inserted correctly, the colours are fine |
| D4 | Select several lines with the mouse, drag the text, paste | Works as before, without losing colours |
| D5 ✅ | Double-click on a word, triple-click on a line | Word and line selection as in an ordinary NSTextView |
| D6 | Search (⌘F) — if connected in the menu | Not related to these changes; note it if something looks strange |
| D7 | VoiceOver: reading a coloured file | Not checked at all; the colours must not affect reading |

## E. Saving and closing

| № | Do | Expected |
|---|---|---|
| E1 ✅ | Edit, ⌘S, close | No question; the subtitle does not change |
| E2 ✅ | Edit, close without saving | The question "Do you want to save changes…" |
| E3 | Save a file of about 6 MB (`/tmp/big.swift` with an edit) | It is saved; the window may freeze for a fraction of a second (known: a copy of the text on the main thread, 100 MB ≈ 0.27 s) |

## F. Recovery of unsaved text (TK-006, ADR-016)

The record directory: `~/Library/Application Support/SwiftIDE/Recovery/` (`ls -la` on it: the directory is `drwx------`, the files `-rw-------`). A "crash" here is: `kill -9` of the application process (`pkill -9 -x SwiftIDE`); an ordinary quit with "Don't Save" is **not** a crash.

| № | Do | Expected |
|---|---|---|
| F1 ✅ | Open `/tmp/small.swift`, type a line, wait 3 s, `pkill -9 -x SwiftIDE`, start again | The dialog "Restore unsaved changes to “small.swift”?". "Restore": a window with your text, the title shows "edited"; the file on disk has not changed |
| F2 ✅ | In F1, after restoring, press ⌘Z | The edit is undone back to the file's text (restoring is an ordinary edit) |
| F3 | In F1 press "Discard" | The record is deleted (`ls` of the directory is empty), an Untitled window |
| F4 | Type a line and at once (within 2 s) switch to another application, then `pkill -9` | The edit still comes back (a record is written on going to the background) |
| F5 | Type without a pause for 15 seconds, then `pkill -9` | Text no older than ≈ 10 s comes back |
| F6 | Edit a file, F1 up to the "kill", **change the same file in another program** (`echo x >> /tmp/small.swift`), start | The dialog says the file has changed. After "Restore" ⌘S shows the conflict dialog (Overwrite / Reload / Cancel), the file is not overwritten |
| F7 | Edit, `pkill -9`, **delete the file**, start | "The file no longer exists"; after "Restore" an Untitled window with the text opens |
| F8 | A new Untitled window, type text, `pkill -9` | Untitled is restored with the text |
| F9 | Edit, ⌘S | There is no record (`ls` of the directory is empty) |
| F10 | Edit, ⌘Q → "Don't Save", start again | There is **no** restore dialog |
| F11 | Edit, close the window → "Don't Save" | There is no record |
| F12 | Damage a record (`truncate -s 50 <record file>`), start | A window "A saved copy of unsaved work could not be read" with a description; the record stays in the directory |
| F13 | Paste text > 16 MB into a window (`python3 -c "print('a'*20000000)" \| pbcopy`) | The subtitle says "recovery off: large file"; there is no record |
| F14 | Make the record directory inaccessible (`chmod 500 ~/Library/Application\ Support/SwiftIDE/Recovery`), edit | The subtitle says "recovery failing"; after `chmod 700` and the next edit it disappears |
| F15 | **IME:** start a composition, wait 5 s, `pkill -9` | The record contains no unfinished marked text (if necessary, check by restoring) |
| F16 | Two windows with unsaved edits, `pkill -9` | Two questions in a row, both documents come back |

Not checked at all: behaviour with two running instances (the second will offer to "restore" the first one's live documents), power loss (fsync does not guarantee), running out of disk space.

## G. File watching (TK-006, ADR-017)

The checks need two windows: SwiftIDE and a terminal. The file: `/tmp/small.swift` (see above). Open it in SwiftIDE.

| № | Do | Expected |
|---|---|---|
| G1 ✅ | In the terminal: `echo '// from terminal' >> /tmp/small.swift` (the document in the window is clean) | After a second the text in the window is updated, a bar "was changed on disk and reloaded" with Undo and OK buttons at the top. The title has no "edited" mark |
| G2 ✅ | In G1 press Undo | The text returns to what it was; the window is "edited" (⌘S will now show a conflict with the disk) |
| G3 ✅ | Instead of `echo`, replace the whole file: `printf 'let replaced = 1\n' > /tmp/x && mv /tmp/x /tmp/small.swift` (many editors save this way) | The same as G1. **Repeat the `mv` a second time after the update: the window is updated again** (an important check, the watching must not fall off after a replacement) |
| G4 ✅ | Type a line (unsaved edits), then `echo '// x' >> /tmp/small.swift` | The text does **not** change; a bar "was changed on disk. This window has unsaved changes" with Reload and Keep Mine |
| G5 ✅ | In G4 press Reload | The text is replaced by the file's contents, your edits are gone, but ⌘Z brings them back |
| G6 ✅ | In G4 press Keep Mine | The bar disappears; the same `echo` repeated does not bring it back, a **different** change does. ⌘S shows the conflict dialog (Overwrite / Reload / Cancel) |
| G7 ✅ | `rm /tmp/small.swift` | A bar "was deleted or moved" with Save As… and OK; the text in the window is intact |
| G8 | In G7 put the file back with the same contents (`cp` of a copy) | The bar disappears |
| G9 | In G7 press Save As… | A save dialog; after saving, the watching follows the new name (check G1 on the new file) |
| G10 | Save the document (⌘S) in SwiftIDE | No bars after its own save, even 2 seconds later |
| G11 | `touch /tmp/small.swift` | Nothing happens |
| G12 | A file with binary contents: `head -c 200 /dev/urandom > /tmp/small.swift` | A bar "cannot be read as text" with a reason; the text in the window is intact |
| G13 | Change the file during typing with IME (composition) | The text is not overwritten; after the composition a Reload / Keep Mine bar |
| G14 | A bar about an external change and about a long line at the same time (the file `/tmp/long-line.swift` + `echo`) | The bar about the external change is shown; after OK — the one about the long line |
| G15 | A folder with a large number of changing files nearby (for example, a build) | The window does not react to other files (no CPU spikes: Activity Monitor) |

Not checked at all: network volumes, iCloud Drive, external disks (events may not arrive; ⌘S still compares the file); two instances of the application.

## H. Saving large files (ADR-018)

A file of about 100 MB: `python3 -c "print('let a = 1\n' * 9000000, end='')" > /tmp/huge.swift` (≈ 100 MB; about 1.5 GB of free memory is needed, close what you can). Highlighting and recovery are off for such a file (the subtitle says "syntax colours off", "recovery off").

| № | Do | Expected |
|---|---|---|
| H1 | Open `/tmp/huge.swift`, type a character in the middle, ⌘S, and **keep typing at once** | The window does not freeze for ≈ 0.3 s (it used to); the text typed during the save stays in the window, the title says "edited" (it is newer than what was written) |
| H2 | After H1 ⌘S again | The file contains everything typed; "edited" disappears |
| H3 | Scroll the mouse wheel during ⌘S | Scrolling is not jerky (the first Save in a launch may give a noticeable jerk of ≈ 20–30 ms: cold memory) |
| H4 | A file of 5–10 MB: type, wait 3 s (recovery writes), type without pauses | No jerks every 2–10 s (it used to be ≈ 25–40 ms) |
| H5 | IME: start a composition, ⌘S | The text is saved without the unfinished composition (the composition is ended) |

## I. After the review (recovery, watching, capture)

| № | Do | Expected |
|---|---|---|
| I1 | A file >1 MB of emoji: `python3 -c "print('a' + '😀' * 600000)" > /tmp/emoji.txt`, open, type a character at the start, ⌘S, `cmp` with the expected (`python3 -c "print('X' + 'a' + '😀' * 600000)"`) | The file on disk equals the expected, no � characters |
| I2 | F6, but change the file **while the "Restore / Discard" dialog is open**, then press Restore and ⌘S | The conflict dialog (Overwrite / Reload / Cancel), the other party's edits are not overwritten |
| I3 | Change the file in the terminal and at once (within a second) do Save As to another name | The application does not crash; the window stays on the new name, there is no bar about the old file |
| I4 | F7 (file deleted) with an inaccessible record directory (`chmod 500` on `Recovery/` after launch, before pressing Restore) | The old record stays in the directory (`ls`) if the new one could not be written |
| I5 | ⌘Q → "Don't Save"; while the dialog is up, return to the window and type something | The quit does not happen silently: the question again about the new text. After Cancel the recovery record appears 2 s after the edit |

## J. Mixed languages: future acceptance (TK-015–TK-017)

**Not yet implemented:** this section is carried out after the corresponding stages of the [plan](12_MIXED_LANGUAGE_SUPPORT.md). Today only Swift highlighting and Swift-only synchronization are expected; the absence of the other features is not a regression.

| № | Do after implementation | Expected |
|---|---|---|
| J1 | Open `.c`, `.cpp`, `.m`, `.mm` with LSP off | Highlighting of each language; in `.mm` both ObjC and C++ are recognized; input/saving are available |
| J2 | Open `.h` without a project, switch C → C++ → Objective-C → Objective-C++ | The chosen language is visible; the colours match the mode; the text, dirty state and Undo do not change |
| J3 | Save As with a new extension, separately with a manual language choice and without it | Without an override the language is determined again; with it the manual choice is kept; old colours/answers are removed |
| J4 | In each language type an unfinished string/comment, do Undo/Redo, CJK IME input and a theme change | No extra Undo steps, no interference with marked text and no stale colours |
| J5 | On built mixed fixtures call completion/hover/definition and introduce an error | The results correspond to the chosen target and the unsaved text; jumps between languages correspond to the verified matrix |
| J6 | Change the language/target with a request pending and with the completion menu open | The old answer and the choice of an old item do not change the document; the diagnostics of the old context are cleared |
| J7 | Kill the server or open a file without the needed build settings/generated headers | Highlighting and typing work; the language features show the state/reason; after recovery there are no old results |

## K. Swift completion (TK-014, ADR-022)

Xcode 27 is needed (`xcrun --find sourcekit-lsp`). The package for the checks is `Fixtures/SwiftPMPackage`: open `Sources/App/main.swift` (⌘O) from the repository, not a copy in `/tmp`; it already has `let greeter = Greeter(name: "world")` (a type from the neighbouring module `Lib`). The first request after opening the window may arrive with a delay of up to a second: the server is just starting.

| № | Do | Expected |
|---|---|---|
| K1 ✅ | At the end of `main.swift`, on a new line, type `greeter.` | Right after the dot a list under the caret with methods and icons; focus stays in the text, typing goes on |
| K2 | Continue typing `greeter.gre`, then on another line `"x".pre` | The first list narrows to `greeting()` with no new request; in the second `prefix(_:)` is higher, `hasPrefix(_:)` (the start of the second word of the name) lower; a substring in the middle of a word does not match |
| K3 | Choose an item with Return, then separately with Tab; arrows ↑/↓, Page Up/Down | The typed word is replaced by the item; for a call with arguments the caret is inside the parentheses, for a property after it; ↑/↓ and Page move the selection, not the caret |
| K4 | Accept an item, press ⌘Z once | The insertion disappears in one step (only what was typed remains), not character by character |
| K5 | The list is open: Esc; call again and press space, a closing parenthesis, a mouse click elsewhere, scrolling with the wheel | Each action closes the list; Esc and a click leave no extra characters |
| K6 | No list: Return, Tab | An ordinary line break and a tab, nothing is "eaten" |
| K7 | Ctrl+Space in the middle of a word `greeter.gre|ting`; in an empty place; with text selected | The word to the left of the caret is replaced entirely by the choice; in an empty place a list at the caret; with a selection nothing happens. If Ctrl+Space does not work, check whether it is taken by layout switching in System Settings, and try Edit ▸ Complete, F5, Esc |
| K8 | In `main.swift` type `Greeter` and `Gr` with Ctrl+Space; `greeter.` (the type is declared in `Sources/Lib/Greeter.swift`) | `Greeter`, `greeting()` and `name` are suggested although they are defined in another file and module |
| K9 | A new Untitled window, type `let x = [1,2].` | A list of array methods (the SDK); Save As into the package directory, `.` again — the neighbouring files of the package are visible |
| K10 | A Japanese or Chinese input method: type text while the list is open; Ctrl+Space during a composition | During the composition the list is closed or does not open, Return and the arrows go to the input method; after the text is committed everything works |
| K11 | A file outside a package (`/tmp/small.swift`, ⌘O), on a new line `"x".` | Suggestions for String without the neighbouring files |
| K12 | While typing, `pkill sourcekit-lsp` in the terminal, wait a couple of seconds, `.` again | The editor does not freeze; the list returns within about ten seconds at most (restart 0.5 → 8 s) |
| K13 | A large list (`.` on a String or Array), the window at the bottom edge of the screen; resize the window and scroll with the list open | The list does not go off screen: it opens above the line if there is no room below; on resize and scroll it closes |
| K14 | Light and dark theme, then a change of appearance with the list open | Readable text and selection in both; the icons are distinguishable; no flicker |
| K15 | ⌘Q, then `pgrep -fl sourcekit-lsp` | No sourcekit-lsp processes remain |
| K16 | Close the last window of the package, `pgrep -fl sourcekit-lsp` | This package's server is stopped (the scratch server may remain while there are windows outside a package) |
| K17 | Freeze the server: `pkill -STOP sourcekit-lsp`, type `greeter.` or press Ctrl+Space; then `pkill -CONT sourcekit-lsp` | After 0.3 s the line "Waiting for SourceKit…", after 5 s "SourceKit is not responding"; the editor does not freeze; after `-CONT` the next request works |
| K18 | Right after opening a package window press Ctrl+Space; in an ordinary text file type `word.` and Ctrl+Space | In the first case, if the server is not ready, "SourceKit is starting…" instead of silence; in the second, after the dot nothing flickers, and Ctrl+Space shows "SourceKit is not available" |
| K19 | In a package press Ctrl+Space where there are no suggestions (inside a string literal or a comment) | "No suggestions" for 2 s; it disappears on the next key |
| K20 | Right after launching the application (a cold package) open a package file, type `greeter.`; if you like, load the CPU (`yes > /dev/null` in 4 terminals) | While the server is loading the package, "Waiting for SourceKit…" under the caret, then the list; with a very long load (>10 s) "SourceKit is not ready yet", and a repeated Ctrl+Space then works |

## L. Bazel: future acceptance (TK-018–TK-022)

**Not yet implemented:** carry out after the corresponding stages of the [Bazel plan](13_BAZEL_SUPPORT.md), on a fixture with pinned versions. The first checks concern an already configured workspace; setup and Build/Test belong to the later stages.

| № | Do after implementation | Expected |
|---|---|---|
| L1 | Open a prepared Bazel workspace with related Swift targets | A Bazel context is selected, the tools and the preparation are visible; completion/hover/definition/diagnostics know the dependent target |
| L2 | Open a file of a nested SwiftPM package inside an explicitly selected Bazel workspace | The context does not switch silently; the explicit project choice is kept |
| L3 | Open without a cache and then again; wait for the current target to be prepared | Progress/partial readiness are visible; the time to the features and the menu is recorded separately for cold/warm |
| L4 | Change BUILD/targets/config while a request is waiting or a menu is shown | Old results are not applied; the new context and the preparation are visible |
| L5 | Jump to a generated source/header and to a file through a Bazel symlink | The right file/position opens, opening again does not create a second session |
| L6 | Stop the fixture's LSP/BSP, check for a hang and close the workspace/application | Typing and highlighting are available; errors/timeout are visible; the processes owned by the scope terminate |
| L7 | On separate mixed targets check each language and the jumps | The result matches the accepted matrix; a Swift success is not counted for the C family |
| L8 | At the TK-021 stage change the setup parameters and repeat the setup | The changes are visible before applying; the user's settings are kept, the result is checked again |
| L9 | At the TK-022 stage run Build/Test, cancel and jump to an error | The right target/config, saving before the run, a streaming result, a working cancel and an exact position |

## M. Document language (TK-015, ADR-024)

The window subtitle begins with the language; the menu is Edit ▸ Language. Highlighting exists for Swift, C, C++ and Objective-C (section N), a language server for Swift and the C family (sections K, O); Objective-C++ has no highlighting.

| № | Do | Expected |
|---|---|---|
| M1 | Create `/tmp/api.h` (`echo 'int f(void);' > /tmp/api.h`), open | The subtitle "C (guess)"; Edit ▸ Language: Automatic is checked |
| M2 | Language ▸ C++ | The subtitle "C++ (chosen)", C++ is checked; the window title has no "edited" dot, ⌘Z undoes nothing, the text is the same |
| M3 | Close the window, open `/tmp/api.h` again | The language is C++ (chosen), it was kept; Language ▸ Automatic brings back "C (guess)" |
| M4 | Open a Swift file, Language ▸ Plain Text | The colours disappear at once, the text does not change; Ctrl+Space shows "SourceKit is not available" |
| M5 | Language ▸ Automatic | The colours return (the same look as on opening), Ctrl+Space gives a list again |
| M6 | A text file, Language ▸ Swift | Colours appear, completion works (in a file, not in a package — only the SDK) |
| M7 | Open the completion list (`.`), without closing it switch the language through the menu | The list closes; an answer that arrives later does not appear |
| M8 | A Swift file, Language ▸ C++ | The colours change to C++ (Swift code is read by the C++ grammar with errors — this is expected), Swift suggestions do not come; editing and saving work |
| M9 | Choose a language and do Save As with a different extension | The language stays chosen; without a choice — it is determined by the new extension (the Swift colours appear or disappear) |
| M10 | Untitled: Language ▸ Plain Text, then Save As `x.swift` | Plain Text (chosen) is kept, no colours; Automatic turns Swift on |
| M11 | Restart the application, open a file with a language chosen earlier | The choice is remembered |

## N. Highlighting of C, C++ and Objective-C (TK-016, ADR-025)

The files for the check are in the SDK: `echo $(xcrun --show-sdk-path)/usr/include/sys/stat.h`, `.../usr/include/c++/v1/__algorithm/sort.h`, `.../System/Library/Frameworks/Foundation.framework/Headers/NSArray.h` (copy them into `/tmp` so as not to edit the SDK).

| № | Do | Expected |
|---|---|---|
| N1 | Open a copy of `stat.h` | The subtitle "C (guess)", without "no syntax colours"; keywords, types, directives, strings, comments in different colours; `Edit ▸ Language ▸ C++` does not break the look |
| N2 | Open a copy of `sort.h` | The subtitle "C++"; `template`, `namespace`, `class` are keywords; types and calls differ |
| N3 | Create `/tmp/t.m` with `@interface Foo : NSObject … @end`, `NSLog(@"x")`, `[self foo:1]` | "Objective-C"; `@interface`/`@end` are keywords, `Foo` is a type, `NSLog` and `foo` are functions, `@"x"` is a string |
| N4 | Open a copy of `NSArray.h`, then `NSURL.h` | The first is coloured almost everywhere; the second — only comments and keywords (the grammar reads it as one error, a known limitation, not an application error). The window does not hang |
| N5 | In a `.c` file type `/*` in the middle of the file | Everything below becomes a comment at once; add `*/` — the colours return; ⌘Z does not take extra steps |
| N6 | The line `char *s = "a /* b"; // c /* d` | Nothing below is painted as a comment |
| N7 | Open a `.mm` | The subtitle "Objective-C++", "no syntax colours", "no code completion"; a manual choice of Objective-C gives approximate colours |
| N8 | In a `.c` choose Language ▸ Plain Text and back ▸ Automatic | The colours disappear and return, the text and Undo are the same |
| N9 | Typing with a Chinese/Japanese IME in a comment of a `.cpp` | No interference with marked text, the colours do not flicker |
| N10 | Paste 1–2 MB of C code (repeat `stat.h` ~100 times) | The window is responsive; above 5 MB the subtitle says "syntax colours off: large file" |

## O. Completion of C, C++ and Objective-C (TK-017, first slice, ADR-026)

Open `Fixtures/SwiftPMMixed/Sources/…` from the repository. **Build the package first:** `swift build --package-path Fixtures/SwiftPMMixed` (without a build the headers of the C target are not found). Do not copy the package into `/tmp`: there will be no flags there.

| № | Do | Expected |
|---|---|---|
| O1 | `Sources/CLib/clib.c`, at the end of the file type `void t(clib_point p) { clib_` | A list: `clib_add`, `clib_length`, `clib_point` (labels without a leading space or "•"); Return inserts the name |
| O2 | In the same place `void u(clib_point p) { p.` | Only `x` and `y` (in the first 1–2 seconds after opening a stray list is possible) |
| O3 | `Sources/CxxLib/cxxlib.cpp`, `void t() { cxxlib::Greeter g("x"); g.` | The class members: `greeting`, `greetings` |
| O4 | `Sources/ObjCLib/ObjCGreeter.m`, inside `@implementation` type `- (void)t { [self gre` | `greetingForTimes…` |
| O5 | `Sources/App/main.swift`, type `clib_` and `greeter.` | C functions and methods of the Objective-C class are visible from Swift |
| O6 | Return the package to an unbuilt state (`rm -rf Fixtures/SwiftPMMixed/.build`), close and open `clib.c`, type `p.` | No members: a known limitation, not an application error |
| O7 | A new window, Edit ▸ Language ▸ C, type `struct P { int x; }; void f(struct P p) { p.` | `x`; Save As `t.c` does not break it |
| O8 | In a `.h` choose C++, then Objective-C, then Plain Text | The subtitle without "no code completion" for the first two; for Plain Text — no list appears |
| O9 | A `.mm` in a package (create it yourself) | No highlighting, completion is offered by the server, the subtitle says so |

## P. Description, jump to definition and diagnostics (TK-017, second slice, ADR-027)

Open the files `Fixtures/SwiftPMMixed/Sources/…` from the repository after `swift build --package-path Fixtures/SwiftPMMixed` (as in section O).

| № | Do | Expected |
|---|---|---|
| P1 | In `Sources/App/main.swift` rest the pointer on `clib_add` | After ≈0.5 s a small window under the word with the description of the function; it does not take focus, does not interfere with a click |
| P2 | Move the pointer to another word, outside the text, press a key, scroll | The window disappears at once; it returns to the same word only after a new pause |
| P3 | Put the caret in `clib_add`, press ⌃⇧Space (and the Edit ▸ Quick Help item) | The description at once; in an empty place or without a server — words ("No quick help here", "SourceKit is not available") |
| P4 | ⌘-click on `clib_add` | A window of `clib.h` opens at the line of the declaration (the file name may be `CLib.h`); the window of an already open file is brought to the front |
| P5 | ⌘-click on `total` in `print(total, …)` | The caret goes to `let total`, the line scrolls into the visible area, no windows open |
| P6 | The caret on a word, ⌃⌘J (Edit ▸ Jump to Definition) | The same as ⌘-click |
| P7 | ⌘-click on `print` | `Swift.Misc.swiftinterface` opens read-only, the subtitle "read-only (system file)", Swift colours |
| P8 | ⌘-click on an empty place/a word without a definition | A short "No definition found" under the place, disappears after 2 s |
| P9 | Add `let bad: Int = "text"` at the end of `main.swift` | After a second or two a red wavy line under `"text"`, a red dot in the line margin, "1 error" in the subtitle; Cmd-Z and saving do not break it |
| P10 | Keep typing text before the error and after it | The line moves with the text, fades while there is no new report, then returns bright |
| P11 | Fix the error | The line, the dot and the counter disappear |
| P12 | Rest the pointer on the underlined word | In the window first the text of the error ("error: …"), below the description of the symbol |
| P13 | An error and a warning (`let unused = 1` in a function) | Red and yellow colours, the counter "1 error, 1 warning"; on one line the red dot outweighs the yellow |
| P14 | The same in `clib.c` (`int bad = ;` at the end) | A clangd error with a red line |
| P15 | Dark theme, then light | The lines, dots and the window are readable |
| P16 | A window with IME input: type Chinese/Japanese text while the pointer rests on a word | The description does not appear during the composition |
| P17 | Two definitions (for example, overloads of one name in two files; in the fixture add `clib_add` to `clib.h` and `Other.h`) and ⌘-click | A pop-up menu "file:line — folder"; choosing opens the right file; Esc closes the menu, nothing opens |
| P18 | After a jump to another file, Edit ▸ Go Back (⌃⌘←) | A return to the place the jump started from, in its window; the item is inactive until there has been a jump; a second "Back" goes to the previous jump |
| P19 | A project located in `/Applications/…` or `/opt/…`, and a jump into its file | The file opens for editing (without "read-only (system file)"); SDK files and `.swiftinterface` — read-only |
| P20 | Unverified diagnostics: type an error and quickly keep typing | The line is paler than usual at once (the server names no version), after the next edit paler still, after a new report it returns |
| P21 ✅ | A Swift file, `struct S { let a: Int }` and below `S()` (an argument is missing) | The red wavy line is not under a single character but under a word or the whole line; a red dot in the line margin |
| P22 | Rest the pointer on the red or yellow dot in the line-number margin, then move away | Under the line a window "error: …" (with several problems line by line, the worst first); it disappears when the pointer leaves, on an edit and on scrolling; on a line without a dot nothing appears |

## Q. Readiness, progress, trust, opened folders and targets (TK-018, slices 1–4, ADR-029, ADR-032, ADR-033, ADR-034)

Use a copy of `Fixtures/SwiftPMPackage` outside the repository (for example under `~/Library/Caches`) so that the package is cold: `rm -rf <copy>/.build`. For the trust checks add `<copy>/.sourcekit-lsp/config.json` with `{"backgroundIndexing": false}`. The previous decisions are kept in the application's settings: forget one with Project ▸ Ask About Project Configuration Again.

| № | Do | Expected |
|---|---|---|
| Q1 | Open `Sources/App/main.swift` of the cold copy (no `.sourcekit-lsp` folder) | No dialog. While the package is prepared the subtitle shows "Preparing package · n / m" (or "Reloading package") and then nothing |
| Q2 | Add `let bad: Int = "text"` to `main.swift` right after opening, while the subtitle still says "Preparing package" | No underline and no counter while it prepares; when it has finished the error appears (a fresh report is asked for), without typing anything |
| Q3 | Add the `.sourcekit-lsp/config.json` above, reopen the file | A dialog "Allow the project configuration?" with the buttons "Don't allow" (default, Return) and "Allow configuration" |
| Q4 | Press "Don't allow" | The subtitle says "Project configuration disabled"; the package is still prepared and completion across modules still works (the configuration is ignored, the preparation is not stopped) |
| Q5 | Close the window, open the file again | No dialog (the decision is kept); the subtitle still says "Project configuration disabled" |
| Q6 | Project ▸ Allow Project Configuration | The server restarts (the subtitle shows "Language server restarting"/"starting"); no dialog; completion of a member of another module no longer works within a few seconds (indexing is off, as the configuration says); the menu item is checked |
| Q7 | Project ▸ Ask About Project Configuration Again, then reopen the file | The dialog is asked again; the menu item is unchecked while undecided |
| Q8 | Leave the dialog open and look at the window; switch to another open document window | The subtitle says "Waiting for your decision on the project configuration". The sheet blocks editing in its parent window; the other window and language-server message processing continue |
| Q9 | A file outside any package (⌘O on `/tmp/small.swift`, or a new window) and a C file that includes a header from another folder | The subtitle says "Using fallback settings"; the errors of the missing header look paler and their description ends with "(using fallback settings)" |
| Q10 | Project menu with a window of a loose file | The trust items are disabled (no project, nothing to decide) |
| Q11 | While "Preparing package" shows, `pkill sourcekit-lsp` | The subtitle changes to "Language server restarting", then the new server prepares afresh; no stale "Preparing package · n / m" from the old one |
| Q12 | Quit and start the application again, open the trusted copy | No dialog, the stored decision applies |
| Q13 | File ▸ Open Folder… and choose a folder that holds a package one level down (no `Package.swift` in the folder itself); then choose a file of that package | A file panel opens inside the folder; the file opens; completion of a member of another module of that package works; the subtitle does not say "Using fallback settings" |
| Q14 | With a file of a package already open, File ▸ Open Folder… on the package's parent folder | The open document keeps working after a moment (it moved to the folder's server: the subtitle may show "Language server starting"); completion still works |
| Q15 | File ▸ Close Opened Folders (enabled only while a folder is open) | The document goes back to the package's own server and keeps working; the item is disabled afterwards |
| Q16 | Open a folder with no project anywhere below it and a file in it | The subtitle says "Using fallback settings"; a member of another file of the folder is not suggested |
| Q17 | Open a folder that holds a package nested inside another structure (for example a `MODULE.bazel` at the top and a package below) | The file is served from the opened folder, not from the nested package (the server's root is the folder) |
| Q18 | A C file in a package that lies under `~/Library/Caches` or in your home folder, then the same under `/tmp` | The subtitle shows "temporary folder: C-family flags may be missing" only for the one under `/tmp` (and not for a Swift file there) |
| Q19 | Open the same folder twice | Nothing changes, no restart |
| Q20 | Open `Sources/App/main.swift` of a package | Within a few seconds the subtitle adds "Target: App" (the package lists the file, so no qualifier); nothing is shown before |
| Q21 | Open a file of the test target (`Tests/LibTests/GreeterTests.swift`) and a header of a C target (`Sources/CLib/include/clib.h`, in `Fixtures/SwiftPMMixed`) | "Target: LibTests"; "Target: CLib (inferred)" (a header is not in the package's list of sources) |
| Q22 | Open a loose file outside any package; a new Untitled window; then Save As the Untitled one into `Sources/App/` | No target for the first two; after Save As, "Target: App (inferred)" (by the folder, the file is not yet in the manifest's list) |
| Q23 | Rename a target in `Package.swift` (and the folder), save it | After a moment the subtitle of the open files shows the new target name |
| Q24 | Break `Package.swift` (a syntax error), save, then open another file of that package | No error dialog and no crash; the target is not shown; the rest works as before |
| Q25 | Open a package that has never been built and look at its folder (`ls -a`) right after the first window | The describing did not create `.build` by itself (the server's own preparation does; look only for `.build/arm64-…` appearing without it, which it does not) |
| Q26 | A package with two targets sharing one folder (`.target(name: "A", path: "Sources/Shared", sources: ["A.swift"])` and the same for `B`); open `A.swift`, `B.swift`, then add `C.swift` to that folder and open it | "Target: A", "Target: B", and for `C.swift` "Target: ambiguous (A, B)" (no chooser yet) |
| Q27 | In a target's folder add `Skip/S.swift` and put `exclude: ["Skip"]` in the manifest; save the manifest, open `Skip/S.swift` | "Target: App (inferred)": the exclusion is not reported by SwiftPM, so the guess is shown as a guess |
| Q28 | With "Target: App" showing, break `Package.swift` (syntax error) and save it in the application | After a moment the target disappears from the subtitle (it does not stay as if the old manifest still held); mend the manifest, save: it returns |
| Q29 | Add `.sourcekit-lsp/config.json` with `{"swiftPM": {"configuration": "release"}}` to a trusted project (Project ▸ Allow) and save it in the application | The language server restarts once (subtitle "Language server restarting/starting"); the target is shown again after a moment. `ls <copy>/.build/index-build/*/` shows a `release` folder after the preparation. Without trust ("Don't allow") the same file leaves the preparation in `debug` |
| Q30 | Change the same file with another editor while the application is in the background, then switch back to it | The server restarts once on activation; nothing happens on activating when nothing changed |
| Q31 | Edit `Package.swift` with another editor (rename a target), switch back to the application | The subtitle shows the new target name after a moment, without saving anything in the application |
| Q32 | `sudo xcode-select -s` another Xcode (if you have two), switch back to the application | The server restarts with the other toolchain; the open files keep working. Skip if there is one Xcode |
| Q33 | With the application running, `ps aux \| grep -E "sourcekit-lsp\|swift-package"` | The server and the description are of the same Xcode as `xcrun --find sourcekit-lsp` / `swift` print |

### Additional acceptance after the UI extraction (TK-024, ADR-030)

These are planned checks, not results for the currently implemented TK-018 slice. Repeat Q3–Q8 and Q12 after the extraction to confirm that the refusal default, wording, status and stored decisions are preserved.

| № | Do | Expected |
|---|---|---|
| Q13 | Open two different project windows A and B, with no saved configuration decision for A. Keep B active while A raises the configuration question | The sheet belongs to A, names A and cannot apply a choice to B; B remains usable |
| Q14 | Close the owning project window through its lifecycle while its configuration question is pending; reopen the project with no other window for it | The pending presentation is cancelled, no decision is stored and no automatic permission is granted; the question is asked on reopening |

## R. Workspace components and Git: future acceptance (TK-025–TK-029, ADR-031)

These are future checks, not passed results or capabilities of Workspace Preview. Use disposable repositories, including a linked worktree and a local bare remote for mutation/network checks. The contract is [15_WORKSPACE_AND_GIT.md](15_WORKSPACE_AND_GIT.md). Run R1–R4 with TK-025/026, R5–R13 with TK-027, R14–R15 with TK-028 and R16 with TK-029.

| № | Do | Expected |
|---|---|---|
| R1 | Search recent projects in Welcome, open a folder, select an already open project in the switcher | Correct project/window; no duplicate project caused by a canonical-path alias; empty and loading states are useful |
| R2 | Remove a recent entry; choose an entry whose folder has been moved/deleted | Removal affects only the list; missing path explains the problem without deleting files or showing an empty working project |
| R3 | Expand Files, open two documents and switch tabs, scroll/type, close a modified tab | Real editor sessions; selection/caret/scroll survive switching; dirty indicator and existing save/cancel procedure work |
| R4 | Expand an excluded `.build` and toggle Show Excluded/Show Ignored | Folder and affected children are orange; children load lazily; filters are independent; included ancestor is not orange solely because of `.build` |
| R5 | Create an untracked file, add it externally with Git, then edit it on disk | Red untracked → green added → blue with both added/modified states; refresh preserves selection |
| R6 | Modify an existing tracked file, stage part of its changes, then edit again | Blue; Changes and diff distinguish index and working-tree changes, including when both apply |
| R7 | Ignore one untracked file through Git, exclude a different tracked/modified file through project settings; include an ordinary untracked `.bak` | Ignored/excluded are orange with different reasons; excluded tracked change remains in Changes; `.bak` is red unless a real rule applies; Files exclusion makes no server-indexing promise |
| R8 | Collapse a folder containing changed descendants, then stage/unstage/add/conflict in a disposable repository | Folder aggregation follows the documented policy without scanning excluded contents; conflicts have a distinct badge, not just red |
| R9 | Rename/delete a tracked file and create a conflict externally | Changes identifies old/new paths, deletion and conflict explicitly; missing paths do not appear as ordinary readable tree files; orange remains an exclusion/ignore colour |
| R10 | Open a file in a linked worktree, a repository with no commits, a detached HEAD and a non-Git folder | Correct identity and honest branch/status states; no assumption that `.git` is a directory or that no result means clean |
| R11 | Inspect a file with unsaved editor text; select a diff, a binary/large diff and commits in paginated Log | Git comparison is disk/index with unsaved text marked separately; no silent save; limited previews are explained; history does not block the editor |
| R12 | Switch project windows during a slow refresh; change repository externally; make Git unavailable or fail a refresh | Old-project answers are discarded; no focus/selection theft; errors do not turn Changes into a clean empty list; last known state is identified if retained |
| R13 | Switch light/dark appearance; select coloured rows; navigate tree/pickers/Changes/Log by keyboard and VoiceOver | Red/green/blue/orange remain readable; selected rows preserve status; accessible labels explain statuses and exclusions without colour |
| R14 | Stage/unstage whole files, commit selected index contents and create a branch in a disposable repository | Explicit operations report the actual result; staged/unstaged views refresh; errors and cancellation preserve buffers and do not claim rollback |
| R15 | Switch a branch while a document has unsaved changes; cancel, then resolve changes and retry | Existing unsaved-document reconciliation runs; cancellation keeps text/checkout; successful switch reconciles affected open sessions without losing text |
| R16 | Clone from a local remote, cancel/fail a clone, Fetch/Push, then Pull using the selected policy with a conflict | Progress/errors/credentials/cancellation are clear; project opens only on successful clone; conflicts have a recovery workflow; offline inspection works; locally known remote refs are not claimed current without a fetch |

## Known limitations that should not be taken for errors

- Editing a long line is slow (≥ 16,000 characters): step 1 only warns. Step 2 was investigated and not accepted (it hangs in TextKit), see [TK-012-step2-prototype.md](benchmarks/TK-012-step2-prototype.md).
- "Make Read-Only" acts on the window's view; the session's programmatic edits are not blocked, saving is allowed.
- The limits (5 MB for highlighting, 1000 characters and 50 spans in a line, 16,000 characters for the warning, 10% hysteresis) are provisional, from one machine.
- An ordinary regex literal with an escaped slash (`/a\/b/`) is read incorrectly by the grammar: the code after it has no colours (not because of our changes).
- Completion: no placeholders and no documentation window; a 5 s timeout and a status line exist (K17–K20). Xcode projects (ADR-019) are not covered by it.
- Highlighting exists for Swift, C, C++ and Objective-C ([ADR-025](07_ARCHITECTURE_DECISIONS.md#adr-025-highlighting-of-c-c-and-objective-c-tk-016)); Objective-C++ has none. Apple headers with macros around enumerations (`NS_OPTIONS`) are read by the Objective-C grammar with errors — the colours there are partial.
- The Bazel context/BSP is not implemented ([ADR-023](07_ARCHITECTURE_DECISIONS.md#adr-023-support-for-bazel-projects)); a Bazel file outside SwiftPM is currently served as a single file without the project's compiler settings.
