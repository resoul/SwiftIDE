import AppKit
import IDEApplication
import IDEDomain
import EditorUI
import SyntaxInfrastructure
import WorkspaceUI

/// Embeds the original document controller. Its storage, Undo, caret and save ownership stay intact.
@MainActor
final class GitConflictEditorController: NSViewController {
    let context: GitConflictViewController
    let document: DocumentEditorController?
    private var task: Task<Void, Never>?
    private var regionTask: Task<Void, Never>?
    private var documentSubscription: UUID?
    private var compositionSubscription: UUID?
    private var highlighters: [TreeSitterHighlighter] = []
    private var stopped = false
    var reportError: ((String) -> Void)?

    init(workspace: GitWorkspace, conflict: GitConflict, document: DocumentEditorController?) {
        self.document = document
        context = GitConflictViewController(workspace: workspace, conflict: conflict)
        super.init(nibName: nil, bundle: nil)
        context.canEditResult = { [weak document] in
            (document?.focusTarget as? NSTextView)?.isEditable == true && document?.session.isComposing == false
        }
        context.takeTextSide = { [weak self] in self?.take($0) }
        context.takeRegion = { [weak self] in self?.takeRegion($0, choice: $1) }
        context.selectRegion = { [weak document] region in
            guard let text = document?.focusTarget as? NSTextView else { return }

            text.setSelectedRange(NSRange(location: region.range.location, length: region.range.length))
            text.scrollRangeToVisible(text.selectedRange())
        }
        context.resolveWorking = { [weak workspace] in workspace?.perform(.resolveConflict(conflict, .workingFile)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        addChild(context)
        view = context.view
    }

    func attachEditor() {
        _ = view
        if let document {
            document.removeFromParent()
            addChild(document)
            context.installEditor(document.view)
            documentSubscription = document.session.subscribeToChanges { [weak self] _ in self?.refreshRegions() }
            compositionSubscription = document.session.subscribeToComposition { [weak self] _ in
                self?.refreshRegions()
            }
            context.linkResultScroll((document.focusTarget as? NSTextView)?.enclosingScrollView)
            highlightSources(language: document.resolvedDocumentLanguage)
            refreshRegions()
        }
    }

    func detachEditor() {
        regionTask?.cancel()
        if let documentSubscription { document?.session.unsubscribeFromChanges(documentSubscription) }
        documentSubscription = nil
        if let compositionSubscription { document?.session.unsubscribeFromComposition(compositionSubscription) }
        compositionSubscription = nil
        context.linkResultScroll(nil)
        context.installEditor(nil)
        document?.removeFromParent()
    }

    func stop() {
        stopped = true
        for highlighter in highlighters { highlighter.stop() }
        highlighters = []
        task?.cancel()
        detachEditor()
        context.disconnect()
    }

    private func take(_ side: GitConflictSide) {
        guard context.workspace.canMutate, let document, let text = side.text,
              let snapshot = context.workspace.snapshot,
              let reader = context.workspace.conflictReader else {
            return
        }

        task?.cancel()
        let version = document.session.version, path = document.session.path
        task = Task { [weak self, weak document] in
            do {
                let fresh = try await reader.conflict(in: snapshot, path: self?.context.conflict.path ?? "")
                try Task.checkCancellation()
                guard let self, let document, !document.isClosed, document.session.path == path,
                      context.workspace.canMutate, fresh.indexToken == context.conflict.indexToken,
                      fresh.integration == context.conflict.integration,
                      (document.focusTarget as? NSTextView)?.isEditable == true else {
                    throw GitInspectionError.failed("Conflict or editor changed; reopen its preview")
                }

                try document.session.replaceText(text, expectedVersion: version)
            } catch { if !Task.isCancelled { self?.reportError?(error.localizedDescription) } }
        }
    }

    private func refreshRegions() {
        regionTask?.cancel()
        guard document?.session.isComposing == false else {
            context.presentRegions([])

            return
        }

        regionTask = Task { [weak self, weak document] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, !stopped, let document, !document.session.isComposing else { return }

            let snapshot = document.session.snapshot(), size = context.conflict.markerSize
            let reference = context.conflict.diff3Reference
            let values = await Task.detached {
                let sources = reference.map { GitConflictRegion.parse($0, version: 0, markerSize: size) } ?? []

                return GitConflictRegion.parse(snapshot.text, version: snapshot.version, markerSize: size).map {
                    $0.addingBase(from: sources)
                }
            }.value
            guard !Task.isCancelled, document.session.version == snapshot.version, !document.isClosed else { return }

            context.presentRegions(values)
        }
    }

    private func highlightSources(language: DocumentLanguage) {
        for side in context.conflict.sides {
            guard let value = side.previewText, let worker = try? TreeSitterHighlighter(language: language) else {
                continue
            }

            highlighters.append(worker)
            worker.connect { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, !stopped, let preview = context.sourcePreviews[side.stage] else { return }

                    for span in result.spans
                        where span.location >= 0 && span.end <= (preview.string as NSString).length {
                        if let colour = SyntaxTheme.standard.colour(for: span.kind) {
                            preview.textStorage?.addAttribute(
                                .foregroundColor,
                                value: colour,
                                range: NSRange(
                                    location: span.location,
                                    length: span.length
                                )
                            )
                        }
                    }
                }
            }
            worker.reset(text: [Array(value.utf16)], version: 0)
            worker.requestHighlights(in: 0..<value.utf16.count, version: 0)
        }
    }

    private func takeRegion(_ region: GitConflictRegion, choice: GitConflictRegionChoice) {
        guard context.workspace.canMutate, let document, let text = region.text(choice),
              let snapshot = context.workspace.snapshot,
              let reader = context.workspace.conflictReader else { return }

        task?.cancel()
        task = Task { [weak self, weak document] in
            do {
                let fresh = try await reader.conflict(in: snapshot, path: self?.context.conflict.path ?? "")
                try Task.checkCancellation()
                guard let self, let document, !document.isClosed, fresh.indexToken == context.conflict.indexToken,
                      fresh.integration == context.conflict.integration, context.canEditResult?() == true else {
                    throw GitInspectionError.failed("Conflict/editor changed; reload the preview.")
                }

                try document.session.apply(
                    [DocumentEdit(range: region.range, replacement: text)],
                    expectedVersion: region.version
                )
            } catch { if !Task.isCancelled { self?.reportError?(error.localizedDescription) } }
        }
    }
}
