import AppKit
import UITheme
import IDEApplication

/// Shared bounded operation output and cancellation; no process or document ownership here.
@MainActor
final class GitOperationView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let output = NSTextView()
    private let scroll = NSScrollView.nonElastic()
    private let model: GitWorkspace

    init(model: GitWorkspace) {
        self.model = model
        super.init(frame: .zero)
        cancel.target = self
        cancel.action = #selector(stop(_:))
        output.backgroundColor = WorkspaceTheme.background
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        output.setAccessibilityLabel("Git action output")
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
        label.font = .systemFont(ofSize: 11)
        label.maximumNumberOfLines = 3
        gitPin(gitStack([gitStack([label, cancel], vertical: false), scroll]), to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func stop(_ sender: Any?) { model.cancelOperation() }

    func render() {
        isHidden = model.operationTitle.isEmpty
        label.stringValue = model.operationTitle + " · " + model.operationState.explanation
        label.toolTip = label.stringValue
        cancel.isHidden = !model.operationState.isBusy
        cancel.isEnabled = model.operationState != .cancelling
        if output.string != model.operationOutput {
            output.string = model.operationOutput
            output.scrollRangeToVisible(NSRange(location: (output.string as NSString).length, length: 0))
        }

        scroll.isHidden = model.operationOutput.isEmpty
    }
}
