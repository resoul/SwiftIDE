import AppKit
import IDEApplication

/// The question whether a project's configuration (SourceKit-LSP's `.sourcekit-lsp/` and `.bsp/`)
/// may be used. It says what declining does and does not do: the manifest is still processed and
/// SwiftPM still prepares the package. Refusal is the default.
enum ProjectTrustDialog {
    struct Content: Equatable {
        let title: String
        let detail: String
        /// The first is the default button.
        let buttons: [String]
    }

    static func content(projectName: String) -> Content {
        Content(
            title: "Allow the project configuration?",
            detail: "“\(projectName)” has configuration that may launch external processes and change the parameters of their execution. Declining disables this configuration but does not stop the processing of the manifest and the SwiftPM preparation.",
            buttons: ["Don't allow", "Allow configuration"]
        )
    }

    static func decision(forButton response: NSApplication.ModalResponse) -> TrustDecision {
        response == .alertSecondButtonReturn ? .granted : .refused
    }

    /// Shows the question as a sheet of the front window, or as a panel when there is none.
    @MainActor
    static func ask(projectName: String) async -> TrustDecision {
        let content = content(projectName: projectName)
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.detail
        alert.alertStyle = .warning
        for title in content.buttons { alert.addButton(withTitle: title) }
        // Return presses the first button (refusal); nothing else answers for the user.
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        return decision(forButton: response)
    }
}
