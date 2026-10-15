import AppKit
import IDEApplication

/// The production providers for the common workspace; no text/document ownership.
@MainActor
public final class ProjectFilesContainer: NSViewController {
    public let files: ProjectFilesViewController
    public let workspace: WorkspaceViewController

    public init(
        model: ProjectFiles,
        editor: NSView,
        editorFocus: NSView? = nil,
        layout: WorkspaceLayoutState = .init(),
        panels: [WorkspaceTool: WorkspacePanel] = [:]
    ) {
        files = ProjectFilesViewController(model: model)
        var providers = panels
        providers[.files] = WorkspacePanel(view: files.view, focusTarget: files.outline)
        workspace = WorkspaceViewController(
            state: layout,
            editor: editor,
            editorFocus: editorFocus,
            panels: providers,
            project: (model.root as NSString).lastPathComponent,
            path: model.root
        )
        super.init(nibName: nil, bundle: nil)
        addChild(files)
        addChild(workspace)
        workspace.present(detail: nil, status: "Open a file to begin editing")
    }

    public override func loadView() { view = workspace.view }

    public func disconnect() {
        files.disconnect()
        workspace.disconnect()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
