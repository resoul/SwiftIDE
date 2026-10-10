import AppKit
import IDEApplication

/// The production providers for the common shell; no text/document ownership.
@MainActor
public final class ProjectFilesContainer: NSViewController {
    public let files: ProjectFilesViewController
    public let shell: WorkspaceShellViewController

    public init(model: ProjectFiles, editor: NSView, editorFocus: NSView? = nil, layout: WorkspaceLayoutState = .init()) {
        files = ProjectFilesViewController(model: model)
        shell = WorkspaceShellViewController(
            state: layout,
            editor: editor,
            editorFocus: editorFocus,
            panels: [.files: WorkspacePanel(view: files.view, focusTarget: files.outline)],
            project: (model.root as NSString).lastPathComponent,
            path: model.root
        )
        super.init(nibName: nil, bundle: nil)
        addChild(files)
        addChild(shell)
        shell.present(detail: nil, status: "Open a file to begin editing")
    }

    public override func loadView() { view = shell.view }

    public func disconnect() {
        files.disconnect()
        shell.disconnect()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
