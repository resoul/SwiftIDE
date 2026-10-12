import AppKit
import IDEApplication

/// Reusable clone form. Folder panels, process lifetime and opening a project belong to the host.
@MainActor
public final class GitCloneViewController: NSViewController, NSTextFieldDelegate {
    public let model: GitClone
    public var chooseParent: (() -> Void)?
    public var close: (() -> Void)?
    public var parentDirectory: String = "" {
        didSet {
            if isViewLoaded {
                parentLabel.stringValue = parentDirectory
                render()
            }
        }
    }
    let source = NSTextField(string: "")
    let name = NSTextField(string: "")
    let start = NSButton(title: "Clone", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let choose = NSButton(title: "Choose Parent Folder…", target: nil, action: nil)
    private let parentLabel = NSTextField(labelWithString: "Choose where the new folder will be created")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextView()
    private var subscription: UUID?

    public init(model: GitClone) { self.model = model; super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitCloneBackground(frame: NSRect(x: 0, y: 0, width: 620, height: 440))
        let title = NSTextField(labelWithString: "Clone Repository")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        source.placeholderString = "https://host/repository.git or git@host:repository.git"
        name.placeholderString = "New folder name"
        source.setAccessibilityLabel("Repository URL or absolute local path")
        name.setAccessibilityLabel("New destination folder name")
        source.delegate = self; name.delegate = self
        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.setAccessibilityLabel("Parent folder")
        choose.target = self; choose.action = #selector(chooseFolder(_:))
        start.target = self; start.action = #selector(startClone(_:)); start.keyEquivalent = "\r"
        cancel.target = self; cancel.action = #selector(cancelClone(_:)); cancel.keyEquivalent = "\u{1b}"
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.setAccessibilityLabel("Clone output")
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let note =
            NSTextField(
                wrappingLabelWithString: """
                Uses configured Git credentials and SSH keys. Existing folders are never overwritten. On failure or \
                cancellation, a partial folder may remain; inspect or remove it before retrying.
                """
            )
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        gitPin(
            gitStack([
                title,
                source,
                gitStack([parentLabel, choose], vertical: false),
                name,
                note,
                status,
                scroll,
                gitStack([cancel, start], vertical: false)
            ]),
            to: view,
            inset: 20
        )
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }
    public func focusSource() { view.window?.makeFirstResponder(source) }
    public func controlTextDidChange(_ notification: Notification) { render() }
    @objc private func chooseFolder(_ sender: Any?) { chooseParent?() }
    @objc func startClone(_ sender: Any?) {
        guard start.isEnabled else { return }

        model.start(.init(source: source.stringValue, parent: parentDirectory, name: name.stringValue))
    }
    @objc func cancelClone(_ sender: Any?) {
        if model.state.isBusy { model.cancel() } else { close?() }
    }
    private func render() {
        let busy = model.state.isBusy
        source.isEnabled = !busy; name.isEnabled = !busy; choose.isEnabled = !busy
        let request = GitCloneRequest(source: source.stringValue, parent: parentDirectory, name: name.stringValue)
        start.isEnabled = !busy && model.state != .succeeded && (try? request.validate()) != nil
        cancel.title = busy ? "Cancel Clone" : "Close"
        cancel.isEnabled = model.state != .cancelling
        status.stringValue = model.state.explanation + (model.destination.map { "\nDestination: " + $0 } ?? "")
        parentLabel.stringValue = parentDirectory.isEmpty ? "Choose a parent folder" : parentDirectory
        parentLabel.toolTip = parentDirectory
        if output.string != model.output {
            output.string = model.output
            output.scrollRangeToVisible(NSRange(location: (output.string as NSString).length, length: 0))
        }
    }
    public func disconnect() { if let subscription { model.unsubscribe(subscription) }; subscription = nil }
}

@MainActor
private final class GitCloneBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
        }
    }
}
