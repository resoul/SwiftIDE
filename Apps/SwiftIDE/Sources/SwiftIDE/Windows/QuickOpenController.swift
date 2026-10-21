import AppKit
import IDEApplication
import WorkspaceUI

/// Quick Open: the files of one project found by typing part of their names. It shows what the
/// model has at once, lists the folder again in the background, and hands a chosen file to `open`.
@MainActor
final class QuickOpenController {
    private let model: QuickOpen
    private let open: (String) -> Void
    private let host = PaletteHost(label: "Quick Open")

    init(model: QuickOpen, open: @escaping (String) -> Void) {
        self.model = model
        self.open = open
        let content = host.content
        content.placeholder = "Go to file"
        content.emptyMessage = "No matching files"
        content.listing = { [weak model] query in
            (model?.results(for: query) ?? []).map {
                PaletteCommand(id: $0.path, title: $0.name, group: $0.directory)
            }
        }
        content.run = { [weak self] command in self?.choose(command.id) }
    }

    var isShown: Bool { host.isShown }

    var window: NSWindow? { host.window }

    var content: CommandPaletteViewController { host.content }

    func toggle(over window: NSWindow?) {
        guard !isShown else { return host.dismiss() }

        model.onChange = { [weak self] in self?.host.content.refreshResults() }
        host.show([], over: window)
        model.reload()
    }

    /// The project closed: nothing is listed or shown for it any more.
    func stop() {
        model.stop()
        host.dismiss()
    }

    private func choose(_ relativePath: String) {
        host.dismiss()
        let path = model.root + "/" + relativePath
        Task { @MainActor [open] in
            await Task.yield()
            open(path)
        }
    }
}
