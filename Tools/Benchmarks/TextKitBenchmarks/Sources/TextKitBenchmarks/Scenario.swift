import AppKit
import EditorPlatformTextKit
import EditorUI
import FileSystemInfrastructure
import IDEApplication
import IDEDomain

/// Lays out and draws the visible part of the editor synchronously into a bitmap. An off-screen
/// window may never be drawn by AppKit, so `displayIfNeeded` alone could report zero work.
@MainActor
enum Presenter {
    private static var canvas: NSBitmapImageRep?

    static func present(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        if canvas == nil || canvas!.size != host.bounds.size {
            canvas = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        }
        if let canvas { host.cacheDisplay(in: host.bounds, to: canvas) }
    }
}

@MainActor
final class PublishedChanges {
    var changes: [DocumentChangeSet] = []
}

/// One file shape and size, measured through the real pipeline, phase by phase.
///
/// Each phase prints its own line as soon as it finishes. Time budgets stop a phase that would
/// run for minutes; the line then says how far it got instead of pretending to be complete.
@MainActor
struct Scenario {
    let shape: Shape
    let megabytes: Double
    let phaseBudgetSeconds: Double

    /// A run that reaches this footprint is stopped and says so: an 8 GB machine must stay usable.
    static let memoryGuardMB = 3_000.0

    private var label: [String: Any] { ["shape": shape.rawValue, "mb": megabytes] }

    func run() async throws {
        let bytes = Int(megabytes * 1_048_576)
        let baseline = footprintMB()

        // Test data, written as a real file so opening goes through the real store.
        let text = Generator.make(shape, bytes: bytes)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk008-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Fixture.swift").path
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        let lineCount = text.utf8.reduce(into: 1) { if $1 == 0x0A { $0 += 1 } }
        emit(label.merging([
            "phase": "fixture", "bytes": text.utf8.count, "utf16_units": text.utf16.count, "lines": lineCount,
            "footprint_mb": round3(footprintMB() - baseline)
        ]) { $1 })

        // ---- open: read → editor → session → first layout and draw -------------------------
        let store = AtomicDocumentFileStore()
        var loaded: LoadedFile?
        let readStart = ContinuousClock.now
        loaded = try await store.read(path: path, maximumBytes: Int.max)
        let readMs = elapsed(since: readStart)
        let file = loaded!
        let afterRead = footprintMB()

        var editor: TextKitEditor?
        let makeEditorMs = milliseconds { editor = TextKitEditorFactory.makeEditor(loadedText: file.text) }
        let ed = editor!
        var sessionBox: DocumentSession?
        let sessionMs = milliseconds { sessionBox = DocumentSession(loaded: file, backend: ed.backend) }
        let session = sessionBox!
        // Every published change, kept so that the text can be rebuilt from them afterwards. The
        // list is appended to inside the measured calls but costs nothing proportional to the file.
        let published = PublishedChanges()
        session.subscribeToChanges { published.changes.append($0) }

        // The margin's line numbers come from this index, built by reading the text once at open.
        let beforeIndex = footprintMB()
        var trackerBox: DocumentLineIndex?
        let lineIndexMs = milliseconds { trackerBox = DocumentLineIndex(session: session, source: ed.backend) }
        let lineIndex = trackerBox!
        let afterIndex = footprintMB()

        let host = EditorHostView(editor: ed, lineIndex: lineIndex)
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        let firstLayoutMs = milliseconds {
            window.orderFrontRegardless()
            Presenter.present(host)
        }
        emit(label.merging([
            "phase": "open", "read_ms": round3(readMs), "make_editor_ms": round3(makeEditorMs),
            "session_init_ms": round3(sessionMs), "line_index_ms": round3(lineIndexMs),
            "line_index_footprint_mb": round3(afterIndex - beforeIndex),
            "first_layout_draw_ms": round3(firstLayoutMs),
            "total_ms": round3(readMs + makeEditorMs + sessionMs + lineIndexMs + firstLayoutMs),
            "footprint_after_read_mb": round3(afterRead - baseline),
            "footprint_after_open_mb": round3(footprintMB() - baseline),
            "text_kit_2": ed.compatibility.isTextKit2
        ]) { $1 })

        // ---- primitives: what each keystroke pays for, measured alone ----------------------
        primitives(session: session, backend: ed.backend)

        // ---- scrolling: jump to a place and show it -----------------------------------------
        scrolling(editor: ed, host: host, window: window)

        // ---- the margin: numbering what is in view, at three places --------------------------
        gutter(editor: ed, host: host, lineIndex: lineIndex)

        // ---- typing at three places ---------------------------------------------------------
        let total = ed.textView.string.utf16.count
        for (name, location) in [("start", 0), ("middle", total / 2), ("end", total)] {
            typing(name, at: location, editor: ed, host: host, window: window, session: session)
        }

        // ---- programmatic edits (format/completion path) ------------------------------------
        programmatic(session: session, editor: ed)

        // ---- undo / redo --------------------------------------------------------------------
        undo(editor: ed, host: host, window: window, session: session)

        // ---- save --------------------------------------------------------------------------
        try await save(session: session, store: store, length: { ed.backend.utf16Length })

        // The proof of correctness: the text rebuilt only from the published changes, applied in
        // order to the text the document started with, must be the text the view shows. Comparing
        // the session with the view would compare two reads of the same storage and prove nothing.
        let replayed = NSMutableString(string: text)
        for change in published.changes {
            for edit in change.edits {   // each change's edits are in coordinates of the text before it
                replayed.replaceCharacters(
                    in: NSRange(location: edit.range.location, length: edit.range.length), with: edit.replacement
                )
            }
        }
        // The index followed every edit above without reading the text again; a fresh scan must
        // agree with it on the totals and on lines spread over the document.
        let fresh = LineIndex(scanning: ed.backend)
        let followed = lineIndex.current
        var indexMatches = fresh.lineCount == followed.lineCount && fresh.utf16Length == followed.utf16Length
        for line in stride(from: 0, to: fresh.lineCount, by: max(1, fresh.lineCount / 997)) where indexMatches {
            indexMatches = fresh.startOffset(ofLine: line) == followed.startOffset(ofLine: line)
                && fresh.lineExtent(line).content == followed.lineExtent(line).content
        }
        let replayMatches = (replayed as String).utf8.elementsEqual(ed.textView.string.utf8)
        emit(label.merging([
            "phase": "summary", "peak_resident_mb": round3(peakResidentMB()),
            "footprint_end_mb": round3(footprintMB() - baseline), "final_version": session.version,
            "published_changes": published.changes.count,
            "reconciled_changes": published.changes.filter(\.isReconciled).count,
            "replay_matches_view": replayMatches,
            "line_index_matches_rescan": indexMatches, "line_index_rebuilds": lineIndex.rebuildCount
        ]) { $1 })
        window.orderOut(nil)
    }

    private func elapsed(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    // MARK: Phases

    /// What the pipeline pays for, measured alone: the old per-keystroke costs (copying the whole
    /// text, comparing it) and the new ones (planning against the storage, a snapshot).
    private func primitives(session: DocumentSession, backend: TextKitDocumentBackend) {
        let repeats = 3
        func median(_ body: () -> Void) -> Double {
            Stats((0..<repeats).map { _ in milliseconds(body) }).p50
        }
        var out: [String: Any] = ["phase": "primitives"]
        var copy = ""
        out["backend_text_copy_ms"] = round3(median { copy = backend.text })
        let other = copy
        out["compare_equal_ms"] = round3(median { _ = copy.utf8.elementsEqual(other.utf8) })
        out["snapshot_ms"] = round3(median { _ = session.snapshot() })
        let middle = backend.utf16Length / 2
        let edit = DocumentEdit(range: UTF16TextRange(location: middle, length: 0), replacement: "x")
        out["planner_prepare_ms"] = round3(median { _ = try? DocumentEditPlanner.prepare([edit], in: backend) })
        emit(label.merging(out) { $1 })
    }

    /// Whether the insertion point is inside the part of the document the scroll view shows. A
    /// measurement taken while the caret is somewhere else measures the wrong place.
    private func caretIsInView(_ editor: TextKitEditor) -> Bool {
        guard let layoutManager = editor.textView.textLayoutManager,
              let content = layoutManager.textContentManager,
              let location = content.location(
                content.documentRange.location, offsetBy: editor.textView.selectedRange().location
              ) else { return false }
        var inView = false
        let origin = editor.textView.textContainerOrigin
        layoutManager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: []) { _, rect, _, _ in
            inView = editor.textView.visibleRect.intersects(rect.offsetBy(dx: origin.x, dy: origin.y))
            return false
        }
        return inView
    }

    /// Producing the numbers for the visible rows, which is what the margin does on every redraw.
    private func gutter(editor: TextKitEditor, host: EditorHostView, lineIndex: DocumentLineIndex) {
        guard let ruler = host.verticalRulerView as? LineNumberRulerView else { return }
        var out: [String: Any] = ["phase": "gutter", "line_count": lineIndex.current.lineCount]
        let total = editor.textView.string.utf16.count
        for (name, location) in [("start", 0), ("middle", total / 2), ("end", total)] {
            editor.textView.setSelectedRange(NSRange(location: location, length: 0))
            editor.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            Presenter.present(host)
            out["in_view_\(name)"] = caretIsInView(editor)
            var labels = 0
            let samples = (0..<5).map { _ in milliseconds { labels = ruler.visibleLabels().count } }
            out["labels_\(name)_ms"] = round3(Stats(samples).p50)
            out["labels_\(name)_count"] = labels
        }
        let lookups = milliseconds {
            var line = 0
            for step in 0..<1_000 {
                line &+= lineIndex.current.line(containing: (total / 1_000) &* step)
            }
            _ = line
        }
        out["thousand_lookups_ms"] = round3(lookups)
        emit(label.merging(out) { $1 })
    }

    private func scrolling(editor: TextKitEditor, host: EditorHostView, window: NSWindow) {
        var out: [String: Any] = ["phase": "scroll"]
        let total = editor.textView.string.utf16.count
        for (name, location) in [("end", total), ("middle", total / 2), ("start", 0)] {
            editor.textView.setSelectedRange(NSRange(location: location, length: 0))
            let ms = milliseconds {
                editor.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                Presenter.present(host)
            }
            out["jump_to_\(name)_ms"] = round3(ms)
            out["jump_to_\(name)_in_view"] = caretIsInView(editor)
        }
        emit(label.merging(out) { $1 })
    }

    private func typing(
        _ name: String, at location: Int, editor: TextKitEditor, host: EditorHostView,
        window: NSWindow, session: DocumentSession
    ) {
        // Putting the caret there is not part of typing; the jump itself is measured in "scroll".
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
        editor.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        Presenter.present(host)

        let versionBefore = session.version
        let reconciledBefore = session.reconciliationCount
        var native: [Double] = [], present: [Double] = [], total: [Double] = []
        let started = ContinuousClock.now
        var position = location
        var abortedForMemory = false
        while native.count < 60, elapsed(since: started) < phaseBudgetSeconds * 1_000 {
            // Without a pool per keystroke this top-level loop never returns to the run loop, and
            // Cocoa's temporary objects pile up until the end: that would inflate memory numbers.
            if footprintMB() > Self.memoryGuardMB { abortedForMemory = true; break }
            autoreleasepool {
                let nativeMs = milliseconds {
                    editor.textView.insertText("x", replacementRange: NSRange(location: position, length: 0))
                }
                let presentMs = milliseconds { Presenter.present(host) }
                position += 1
                native.append(nativeMs)
                present.append(presentMs)
                total.append(nativeMs + presentMs)
            }
            // The end of a real event: lets NSUndoManager close its per-event group.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.0005))
        }
        emit(label.merging([
            "phase": "typing", "where": name, "aborted_for_memory": abortedForMemory,
            "keystrokes_done": native.count,
            "published_versions": session.version - versionBefore,
            "reconciled": session.reconciliationCount - reconciledBefore,
            "caret_in_view": caretIsInView(editor),
            "input_to_draw": Stats(total).json, "native_commit": Stats(native).json,
            "layout_draw": Stats(present).json, "footprint_mb": round3(footprintMB())
        ]) { $1 })
    }

    private func programmatic(session: DocumentSession, editor: TextKitEditor) {
        var times: [Double] = []
        let started = ContinuousClock.now
        while times.count < 10, elapsed(since: started) < phaseBudgetSeconds * 1_000 {
            let middle = editor.backend.utf16Length / 2
            autoreleasepool {
                let ms = milliseconds {
                    try? session.apply(
                        [DocumentEdit(range: UTF16TextRange(location: middle, length: 0), replacement: "y")],
                        expectedVersion: session.version, origin: .formatting
                    )
                }
                times.append(ms)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.0005))
        }
        emit(label.merging(["phase": "programmatic_edit", "apply": Stats(times).json]) { $1 })
    }

    private func undo(editor: TextKitEditor, host: EditorHostView, window: NSWindow, session: DocumentSession) {
        let manager = editor.undo.undoManager
        var undoTimes: [Double] = [], redoTimes: [Double] = []
        let started = ContinuousClock.now
        while manager.canUndo, undoTimes.count < 8, elapsed(since: started) < phaseBudgetSeconds * 1_000 {
            autoreleasepool {
                undoTimes.append(milliseconds {
                    manager.undo()
                    Presenter.present(host)
                })
            }
        }
        while manager.canRedo, redoTimes.count < 4, elapsed(since: started) < phaseBudgetSeconds * 1_000 {
            autoreleasepool {
                redoTimes.append(milliseconds {
                    manager.redo()
                    Presenter.present(host)
                })
            }
        }
        emit(label.merging([
            "phase": "undo", "undo": Stats(undoTimes).json, "redo": Stats(redoTimes).json
        ]) { $1 })
    }

    private func save(
        session: DocumentSession, store: AtomicDocumentFileStore, length: () -> Int
    ) async throws {
        let useCase = SaveDocumentUseCase(store: store)
        var times: [Double] = []
        for _ in 0..<2 {
            let end = length()
            try session.apply(
                [DocumentEdit(range: UTF16TextRange(location: end, length: 0), replacement: "z")],
                expectedVersion: session.version
            )
            let start = ContinuousClock.now
            _ = try await useCase.execute(document: session)
            times.append(elapsed(since: start))
        }
        emit(label.merging([
            "phase": "save", "first_ms": round3(times[0]), "second_ms": round3(times[1]),
            "clean_after": !session.isDirty
        ]) { $1 })
    }
}
