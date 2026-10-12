import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitHostingWindowController: NSWindowController, NSWindowDelegate {
    let content: GitHostingViewController
    let accounts: GitHostingAccountsViewController
    var onClosed: (() -> Void)?
    var onChecks: ((String, [GitHostingCheck], Bool, Date, String) -> Void)?
    private var reportSubscription: UUID?
    private var lastReport: UUID?

    init(workspace: GitWorkspace, accounts model: GitHostingAccounts) {
        content = .init(model: .init(workspace: workspace, accounts: model))
        accounts = .init(model: model)
        let tabs = NSTabViewController()
        let repositoryTab = NSTabViewItem(viewController: content)
        repositoryTab.label = "PR/MR and CI"
        let accountTab = NSTabViewItem(viewController: accounts)
        accountTab.label = "Accounts"
        tabs.addTabViewItem(repositoryTab)
        tabs.addTabViewItem(accountTab)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitHub / GitLab"
        window.minSize = NSSize(width: 760, height: 740)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = tabs
        super.init(window: window)
        window.delegate = self
        content.openURL = { url in NSWorkspace.shared.open(url) }
        reportSubscription = content.model.subscribe { [weak self] in
            guard let self, content.model.state == .ready, let received = content.model.reportReceivedAt,
                  let reportID = content.model.reportID, reportID != lastReport,
                  let repository = content.model.reportedRepository else { return }

            lastReport = reportID
            onChecks?(
                content.model.checksSHA,
                content.model.checks,
                content.model.checksLimited,
                received,
                repository.account.webURL.absoluteString + "/" + repository.path
            )
        }
        content.confirmCreate = { [weak self] plan in
            guard let self, let window = self.window else { return }

            let alert = NSAlert()
            alert.messageText = "Publish a " + plan.repository.account.service.rawValue + " request?"
            alert.informativeText = plan.repository.account.webURL.absoluteString + "/" + plan.repository.path
                + "\n" + plan.source.name + " @ " + plan.source.oid + "\n→ " + plan.request.target + " @ " + plan
                .baseSHA
                + "\nTitle: " + plan.request.title + (plan.request.draft ? "\nDraft" : "")
                + "\nDescription: " + String(plan.request.body.prefix(300))
                + "\nThe full reviewed description is in the form. Nothing is pushed."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Create PR/MR")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn, self?.content.model.plan == plan,
                      self?.content.model.canCreate == true else { return }

                self?.content.model.create()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow) {
        if let window { parent.beginSheet(window) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()

        return false
    }

    func dismiss() {
        if let reportSubscription { content.model.unsubscribe(reportSubscription) }
        reportSubscription = nil
        content.disconnect()
        accounts.disconnect()
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }

        let callback = onClosed
        onClosed = nil
        callback?()
    }
}
