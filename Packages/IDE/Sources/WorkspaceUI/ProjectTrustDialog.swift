import AppKit
import IDEApplication

/// Presentation only: the caller decides where an answer is stored and how it affects services.
public enum ProjectTrustDialog {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let detail: String
        /// The first button is refusal and is the default.
        public let buttons: [String]
    }

    public static func content(projectName: String) -> Content {
        Content(
            title: "Allow the project configuration?",
            detail: "“\(projectName)” has configuration that may launch external processes and change the parameters of their execution. Declining disables this configuration but does not stop the processing of the manifest and the SwiftPM preparation.",
            buttons: ["Don't allow", "Allow configuration"]
        )
    }

    /// Dismissal is not a user decision.
    public static func decision(forButton response: NSApplication.ModalResponse) -> TrustDecision? {
        switch response {
        case .alertFirstButtonReturn: .refused
        case .alertSecondButtonReturn: .granted
        default: nil
        }
    }

    @MainActor
    static func makeAlert(projectName: String) -> NSAlert {
        let content = content(projectName: projectName)
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.detail
        alert.alertStyle = .warning
        for title in content.buttons { alert.addButton(withTitle: title) }
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""

        return alert
    }
}

/// Each question belongs to the supplied window. Closing the owner or cancelling the task returns
/// nil, without converting dismissal into a stored refusal. Other windows remain usable.
@MainActor
public final class ProjectTrustPresenter {
    private var pending: [ObjectIdentifier: Presentation] = [:]

    public init() {}

    public func ask(projectName: String, parent: NSWindow) async -> TrustDecision? {
        let key = ObjectIdentifier(parent)
        let id = UUID()
        guard !Task.isCancelled, pending[key] == nil, parent.attachedSheet == nil else { return nil }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)

                    return
                }

                let alert = ProjectTrustDialog.makeAlert(projectName: projectName)
                let presentation = Presentation(id: id, parent: parent, alert: alert, continuation: continuation) { [weak self] in
                    self?.finish(key: key, id: id, decision: nil)
                }
                pending[key] = presentation
                alert.beginSheetModal(for: parent) { [weak self] response in
                    self?.finish(key: key, id: id, decision: ProjectTrustDialog.decision(forButton: response))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(key: key, id: id, decision: nil) }
        }
    }

    /// The application has removed this window from its project ownership registry.
    public func cancel(for parent: NSWindow) {
        let key = ObjectIdentifier(parent)
        guard let presentation = pending[key] else { return }

        finish(key: key, id: presentation.id, decision: nil)
    }

    private func finish(key: ObjectIdentifier, id: UUID, decision: TrustDecision?) {
        guard let presentation = pending[key], presentation.id == id else { return }

        pending.removeValue(forKey: key)
        NotificationCenter.default.removeObserver(presentation)
        if let parent = presentation.parent, parent.attachedSheet === presentation.alert.window {
            parent.endSheet(presentation.alert.window, returnCode: .abort)
        }

        presentation.alert.window.orderOut(nil)
        presentation.continuation.resume(returning: decision)
    }

    @MainActor
    private final class Presentation: NSObject {
        let id: UUID
        weak var parent: NSWindow?
        let alert: NSAlert
        let continuation: CheckedContinuation<TrustDecision?, Never>
        private let onClose: @MainActor () -> Void

        init(
            id: UUID,
            parent: NSWindow,
            alert: NSAlert,
            continuation: CheckedContinuation<TrustDecision?, Never>,
            onClose: @escaping @MainActor () -> Void
        ) {
            self.id = id
            self.parent = parent
            self.alert = alert
            self.continuation = continuation
            self.onClose = onClose
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(ownerWillClose), name: NSWindow.willCloseNotification, object: parent)
        }

        @objc private func ownerWillClose(_ notification: Notification) {
            onClose()
        }
    }
}
