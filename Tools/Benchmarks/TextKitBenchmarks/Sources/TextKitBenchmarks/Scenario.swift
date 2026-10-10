import AppKit
import EditorPlatformTextKit
import EditorUI
import FileSystemInfrastructure
import IDEApplication
import IDEDomain
import SyntaxInfrastructure

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
        // Experiment: NOWRAP=1 lays lines out without wrapping and scrolls sideways instead.
        if ProcessInfo.processInfo.environment["NOWRAP"] == "1", let container = ed.textView.textContainer {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ed.textView.isHorizontallyResizable = true
            ed.textView.autoresizingMask = []
            host.hasHorizontalScroller = true
        }
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
        if wants("primitives") { primitives(session: session, backend: ed.backend) }
        if wants("capture") { await capturePhase(session: session) }

        // ---- scrolling: jump to a place and show it -----------------------------------------
        if wants("scroll") { scrolling(editor: ed, host: host, window: window) }

        // ---- the margin: numbering what is in view, at three places --------------------------
        if wants("gutter") { gutter(editor: ed, host: host, lineIndex: lineIndex) }

        // ---- typing at three places ---------------------------------------------------------
        let total = ed.textView.string.utf16.count
        for (name, location) in [("start", 0), ("middle", total / 2), ("end", total)] where wants("typing") {
            typing(name, at: location, editor: ed, host: host, window: window, session: session)
        }

        // ---- programmatic edits (format/completion path) ------------------------------------
        if wants("programmatic") { programmatic(session: session, editor: ed) }

        // ---- undo / redo --------------------------------------------------------------------
        if wants("undo") { undo(editor: ed, host: host, window: window, session: session) }

        // ---- save --------------------------------------------------------------------------
        if wants("save") { try await save(session: session, store: store, length: { ed.backend.utf16Length }) }

        // ---- colours: rendering attributes against attributes in the storage (TK-007b) -------
        if wants("attributes"), shape != .giantLine || megabytes <= 0.11 {
            attributes(editor: ed, host: host, session: session)
        }

        // ---- tree-sitter colours (TK-007c) -------------------------------------------------
        if wants("syntax"), (shape == .swift || shape == .mixedEndings || shape == .wideLines) && megabytes <= 25 || shape == .giantLine && megabytes <= 0.11 {
            await syntax(editor: ed, host: host, session: session)
        }

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

    /// `PHASES=syntax,typing` runs only those phases (an 8 GB machine does not need the rest every time).
    private func wants(_ phase: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["PHASES"] else { return true }
        return only.split(separator: ",").contains { $0 == phase }
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

    // MARK: Capturing the text for a save (ADR-018)

    /// What a save holds the main thread for: the old way (one synchronous copy) against the new
    /// (slices, with the main thread given back between them). A ticker on the main actor shows the
    /// longest stretch in which nothing else could run.
    private func capturePhase(session: DocumentSession) async {
        var out: [String: Any] = ["phase": "capture"]
        out["synchronous_snapshot_ms"] = round3(Stats((0..<3).map { _ in milliseconds { _ = session.snapshot() } }).p50)

        final class Ticker: @unchecked Sendable {
            var longest = 0.0
            var longestAtMs = 0.0
            var ticks = 0
            var startedAt = ContinuousClock.now
            var running = true
        }
        var runs: [[String: Any]] = []
        for _ in 0..<3 {
            let ticker = Ticker()
            let task = Task { @MainActor in
                var last = ContinuousClock.now
                while ticker.running {
                    let now = ContinuousClock.now
                    let gap = Double((now - last).components.seconds) * 1_000 + Double((now - last).components.attoseconds) / 1e15
                    if gap > ticker.longest {
                        ticker.longest = gap
                        ticker.longestAtMs = Double((now - ticker.startedAt).components.seconds) * 1_000 + Double((now - ticker.startedAt).components.attoseconds) / 1e15
                    }
                    ticker.ticks += 1
                    last = now
                    await Task.yield()
                }
            }
            let started = ContinuousClock.now
            ticker.startedAt = started
            let capture = try? await session.capture()
            let total = elapsed(since: started)
            ticker.running = false
            await task.value
            runs.append([
                "total_ms": round3(total), "longest_main_thread_gap_ms": round3(ticker.longest), "longest_gap_at_ms": round3(ticker.longestAtMs), "ticks": ticker.ticks,
                "bytes": capture?.snapshot.text.utf8.count ?? -1
            ])
        }
        out["capture_runs"] = runs
        out["footprint_mb"] = round3(footprintMB())
        emit(label.merging(out) { $1 })
    }

    // MARK: Syntax colours (TK-007c)

    /// The real chain on the benchmark's editor: coordinator, tree-sitter in the background,
    /// presenter. Measures what it costs on the main thread while typing, how long until the
    /// first colours, how far colours lag behind a keystroke, and what the parser's copies take.
    /// It waits with `await`, not by spinning the run loop: results come back as main-actor tasks.
    private func syntax(editor ed: TextKitEditor, host: EditorHostView, session: DocumentSession) async {
        var out: [String: Any] = ["phase": "syntax"]
        guard let highlighter = try? TreeSitterHighlighter() else {
            out["error"] = "highlighter unavailable"
            emit(label.merging(out) { $1 })
            return
        }
        let total = ed.textView.string.utf16.count
        let before = footprintMB()
        var coordinatorBox: SyntaxCoordinator?
        out["start_main_thread_ms"] = round3(milliseconds {
            coordinatorBox = SyntaxCoordinator(session: session, source: ed.backend, highlighter: highlighter)
        })
        let coordinator = coordinatorBox!
        // Wide lines are measured to find the limit, so there nothing is held back by the policy.
        let policy = shape == .wideLines
            ? SyntaxPolicy(maximumDocumentLength: .max, maximumFragmentLength: .max, maximumSpansPerFragment: .max)
            : SyntaxPolicy.standard
        let presenter = SyntaxPresenter(textView: ed.textView, coordinator: coordinator, policy: policy)
        // The presenter's refresh is the main-thread cost of applying a result; time it.
        let refreshMs = Samples()
        let applyRefresh = coordinator.onChange
        coordinator.onChange = { ranges in
            let began = ContinuousClock.now
            applyRefresh?(ranges)
            refreshMs.values.append(Double(began.duration(to: .now).components.attoseconds) / 1e15
                + Double(began.duration(to: .now).components.seconds) * 1_000)
        }

        ed.textView.setSelectedRange(NSRange(location: total / 2, length: 0))
        ed.textView.scrollRangeToVisible(NSRange(location: total / 2, length: 0))
        Presenter.present(host)
        let started = ContinuousClock.now
        while coordinator.lastResultVersion != session.version, elapsed(since: started) < 120_000 {
            try? await Task.sleep(for: .milliseconds(2))
            Presenter.present(host)
        }
        out["first_colours_ms"] = round3(elapsed(since: started))
        out["spans_in_window"] = coordinator.state.spans.count
        out["window_units"] = coordinator.state.window.count
        out["footprint_mb"] = round3(footprintMB() - before)
        out["first_refresh_main_ms"] = round3(refreshMs.values.first ?? 0)
        refreshMs.values.removeAll()

        // Typing with colours on, one keystroke at a time, waiting for the colours after each:
        //  - result: until the highlighter's answer for this version has been received. It may still
        //    describe another part of the text than the one in view.
        //  - picture: until an answer for this version covers what is in view AND the frame that
        //    follows it has been drawn: what a person sees.
        var native: [Double] = [], keystroke: [Double] = [], result: [Double] = [], picture: [Double] = [], redraw: [Double] = []
        var position = total / 2
        for _ in 0..<60 {
            if footprintMB() > Self.memoryGuardMB { break }
            let keyed = ContinuousClock.now
            var nativeMs = 0.0, presentMs = 0.0
            autoreleasepool {
                nativeMs = milliseconds { ed.textView.insertText("x", replacementRange: NSRange(location: position, length: 0)) }
                presentMs = milliseconds { Presenter.present(host) }
            }
            position += 1
            native.append(nativeMs)
            keystroke.append(nativeMs + presentMs)
            while coordinator.lastResultVersion != session.version, elapsed(since: keyed) < 5_000 {
                try? await Task.sleep(for: .milliseconds(1))
            }
            result.append(elapsed(since: keyed))
            while !covers(coordinator, viewportCharacters(ed)), elapsed(since: keyed) < 5_000 {
                try? await Task.sleep(for: .milliseconds(1))
            }
            redraw.append(milliseconds { Presenter.present(host) })
            picture.append(elapsed(since: keyed))
            endEvent()
        }
        let lag = result
        out["keystroke_input_to_draw"] = Stats(keystroke).json
        out["keystroke_commit"] = Stats(native).json
        out["colour_result_ms"] = Stats(result).json
        out["colour_picture_ms"] = Stats(picture).json
        out["redraw_after_colours"] = Stats(redraw).json
        out["refresh_main"] = Stats(refreshMs.values).json
        out["resyncs"] = coordinator.resyncCount
        out["stats_one_at_a_time"] = await Self.describe(highlighter.statistics())
        _ = lag
        emit(label.merging(out) { $1 })

        // A burst: sixty keystrokes as fast as they can be typed, with no wait for colours between
        // them. Shows whether work piles up behind the highlighter, and what the background pays
        // for it (parsing, and the search for an unclosed comment that reads the whole text).
        let beforeBurst = await highlighter.statistics()
        var burst: [Double] = []
        let burstStart = ContinuousClock.now
        let versionBefore = session.version
        for _ in 0..<60 {
            if footprintMB() > Self.memoryGuardMB { break }
            autoreleasepool {
                burst.append(milliseconds {
                    ed.textView.insertText("y", replacementRange: NSRange(location: position, length: 0))
                    Presenter.present(host)
                })
            }
            position += 1
            endEvent()
        }
        let typedAt = elapsed(since: burstStart)
        while !(coordinator.lastResultVersion == session.version && covers(coordinator, viewportCharacters(ed))),
              elapsed(since: burstStart) < 120_000 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let drainedAt = elapsed(since: burstStart)
        Presenter.present(host)
        let afterBurst = await highlighter.statistics()
        var delta = afterBurst
        delta.answered -= beforeBurst.answered; delta.skipped -= beforeBurst.skipped; delta.parses -= beforeBurst.parses
        delta.parseMilliseconds -= beforeBurst.parseMilliseconds
        delta.commentSearchMilliseconds -= beforeBurst.commentSearchMilliseconds
        delta.spanMilliseconds -= beforeBurst.spanMilliseconds
        emit(label.merging([
            "phase": "syntax_burst", "keystrokes": burst.count, "versions": session.version - versionBefore,
            "keystroke_input_to_draw": Stats(burst).json, "typing_took_ms": round3(typedAt),
            "colours_ready_after_last_key_ms": round3(drainedAt - typedAt),
            "background": Self.describe(delta)
        ]) { $1 })
        _ = presenter
        coordinator.onChange = nil
    }

    private static func describe(_ s: HighlighterStatistics) -> [String: Any] {
        ["answered": s.answered, "skipped": s.skipped, "parses": s.parses, "parse_ms": round3(s.parseMilliseconds),
         "comment_search_ms": round3(s.commentSearchMilliseconds), "spans_ms": round3(s.spanMilliseconds)]
    }

    /// Whether the colours the coordinator holds (from an answer for the current version) reach over what is in view.
    private func covers(_ coordinator: SyntaxCoordinator, _ viewport: NSRange) -> Bool {
        let window = coordinator.state.window
        return window.lowerBound <= viewport.location && viewport.location + viewport.length <= window.upperBound
    }

    // MARK: Colours (TK-007b)

    private struct Span {
        let location: Int
        let length: Int
        let color: NSColor
    }

    /// The end of a real event: lets NSUndoManager close its per-event group.
    private func endEvent() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.0005))
    }

    private final class Samples {
        var values: [Double] = []
    }

    private final class Tally {
        var calls = 0
        var spans = 0
        var validatorMs = 0.0
    }

    /// A stand-in for a highlighter: words of three or more letters and numbers get a colour.
    /// It gives about as many spans per line as real Swift code does; its own cost is small and
    /// is the same for both ways of applying colours, so only the application is compared.
    private static func spans(in text: NSString) -> [Span] {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemGreen, .systemOrange]
        var found: [Span] = []
        var index = 0, count = 0
        let length = text.length
        while index < length {
            let unit = text.character(at: index)
            let isWord = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
            if isWord {
                var end = index + 1
                while end < length {
                    let u = text.character(at: end)
                    if (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F { end += 1 } else { break }
                }
                if end - index >= 3 {
                    found.append(Span(location: index, length: end - index, color: palette[count % palette.count]))
                    count += 1
                }
                index = end
            } else {
                index += 1
            }
        }
        return found
    }

    /// The part of the document the layout is working on, as a character range.
    private func viewportCharacters(_ editor: TextKitEditor) -> NSRange {
        guard let layoutManager = editor.textView.textLayoutManager,
              let content = layoutManager.textContentManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else {
            return NSRange(location: 0, length: 0)
        }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let length = content.offset(from: viewport.location, to: viewport.endLocation)
        return NSRange(location: start, length: length)
    }

    /// Two ways to colour what is in view, measured on the same synthetic spans:
    /// rendering attributes (a validator colours each fragment as it is laid out; nothing in the
    /// storage changes) and attributes written into the storage.
    private func attributes(editor ed: TextKitEditor, host: EditorHostView, session: DocumentSession) {
        guard let tlm = ed.textView.textLayoutManager, let content = tlm.textContentManager,
              let storage = ed.textView.textStorage else { return }
        let total = ed.textView.string.utf16.count
        let places = [("start", 0), ("middle", total / 2), ("end", total)]
        func go(_ location: Int) {
            ed.textView.setSelectedRange(NSRange(location: location, length: 0))
            ed.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            Presenter.present(host)
        }
        var out: [String: Any] = ["phase": "attributes"]

        // A. Rendering attributes. The validator runs when a fragment is laid out; to colour what
        // is already laid out, the storage is told that attributes (not text) changed.
        let tally = Tally()
        tlm.renderingAttributesValidator = { manager, fragment in
            guard let paragraph = fragment.textElement as? NSTextParagraph else { return }
            let started = ContinuousClock.now
            let found = Self.spans(in: paragraph.attributedString.string as NSString)
            let origin = fragment.rangeInElement.location
            for span in found {
                guard let from = content.location(origin, offsetBy: span.location),
                      let to = content.location(from, offsetBy: span.length),
                      let range = NSTextRange(location: from, end: to) else { continue }
                manager.setRenderingAttributes([.foregroundColor: span.color], for: range)
            }
            tally.calls += 1
            tally.spans += found.count
            let spent = started.duration(to: .now)
            tally.validatorMs += Double(spent.components.seconds) * 1_000 + Double(spent.components.attoseconds) / 1e15
        }
        var renderingUnchanged = true
        for (name, location) in places {
            go(location)
            let viewport = viewportCharacters(ed)
            let versionBefore = session.version, generationBefore = ed.backend.editGeneration
            var samples: [Double] = []
            tally.calls = 0; tally.spans = 0; tally.validatorMs = 0
            for _ in 0..<3 {
                samples.append(milliseconds {
                    storage.beginEditing()
                    storage.edited(.editedAttributes, range: viewport, changeInLength: 0)
                    storage.endEditing()
                    Presenter.present(host)
                })
            }
            renderingUnchanged = renderingUnchanged && session.version == versionBefore
                && ed.backend.editGeneration == generationBefore
            out["rendering_refresh_\(name)_ms"] = round3(Stats(samples).p50)
            out["rendering_\(name)_fragments"] = tally.calls / 3
            out["rendering_\(name)_spans"] = tally.spans / 3
            out["rendering_\(name)_validator_ms"] = round3(tally.validatorMs / 3)
        }
        out["rendering_text_untouched"] = renderingUnchanged
        typing("middle, rendering attributes", at: total / 2, editor: ed, host: host, window: host.window!, session: session)
        tlm.renderingAttributesValidator = nil
        tlm.setRenderingAttributes([:], for: tlm.documentRange)

        // B. The same colours written into the storage.
        let palette = NSColor.textColor
        var storageUnchanged = true
        var painted: [NSRange] = []
        let total2 = ed.textView.string.utf16.count
        for (name, location) in [("start", 0), ("middle", total2 / 2), ("end", total2)] {
            go(location)
            let viewport = viewportCharacters(ed)
            let versionBefore = session.version, generationBefore = ed.backend.editGeneration
            painted.append(viewport)
            let text = (ed.textView.string as NSString).substring(with: viewport) as NSString
            let ms = milliseconds {
                let found = Self.spans(in: text)
                storage.beginEditing()
                storage.addAttribute(.foregroundColor, value: palette, range: viewport)
                for span in found {
                    storage.addAttribute(
                        .foregroundColor, value: span.color,
                        range: NSRange(location: viewport.location + span.location, length: span.length)
                    )
                }
                storage.endEditing()
                Presenter.present(host)
            }
            storageUnchanged = storageUnchanged && session.version == versionBefore
                && ed.backend.editGeneration >= generationBefore
            out["storage_apply_\(name)_ms"] = round3(ms)
        }
        out["storage_published_no_revision"] = storageUnchanged
        typing("middle, storage attributes", at: total2 / 2, editor: ed, host: host, window: host.window!, session: session)
        // Put the text back as it was: the colours written above would otherwise slow every phase
        // that follows, on long lines by a factor of two or more.
        let length = storage.length
        storage.beginEditing()
        for range in painted where range.location < length {
            let clipped = NSRange(location: range.location, length: min(range.length, length - range.location))
            storage.removeAttribute(.foregroundColor, range: clipped)
            storage.addAttribute(.foregroundColor, value: palette, range: clipped)
        }
        storage.endEditing()

        // One notification over the whole document, for small files only: it is not lazy, and it is measured last because it leaves the whole
        // document invalidated, which would distort anything measured after it. Measured
        // once at 1 MB (1.3 s) and 10 MB (59 s, abandoned at 100 MB); refresh must name its range.
        if megabytes <= 1 {
            let whole = milliseconds {
                storage.beginEditing()
                storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
                storage.endEditing()
                Presenter.present(host)
            }
            out["rendering_refresh_whole_ms"] = round3(whole)
        }
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
