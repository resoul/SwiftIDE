import AppKit
import IDEApplication

@MainActor
public final class GitHostingAccountsViewController: NSViewController {
    public let model: GitHostingAccounts
    private let service = NSPopUpButton()
    private let host = NSTextField(string: "https://github.com")
    private let token = NSSecureTextField(string: "")
    private let connected = NSPopUpButton()
    private let connect = NSButton(title: "Connect and save token", target: nil, action: nil)
    private let remove = NSButton(title: "Disconnect selected account", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var subscription: UUID?
    private var ownsPending = false
    private var ids: [UUID] = []

    public init(model: GitHostingAccounts) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 800, height: 640))
        service.addItems(withTitles: GitHostingService.allCases.map(\.rawValue))
        service.target = self
        service.action = #selector(serviceChanged(_:))
        service.setAccessibilityLabel("Hosting service")
        host.setAccessibilityLabel("Service HTTPS address")
        token.placeholderString = "Personal access token (saved only in Keychain)"
        token.setAccessibilityLabel("Hosting personal access token")
        connected.setAccessibilityLabel("Connected hosting accounts")
        connect.target = self
        connect.action = #selector(connectAccount(_:))
        remove.target = self
        remove.action = #selector(disconnectAccount(_:))
        let heading = NSTextField(labelWithString: "GitHub and GitLab Accounts")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let note =
            NSTextField(
                wrappingLabelWithString: """
                GitHub: repository Pull requests read/write, Contents, Checks and Commit statuses read. GitLab: API \
                permission for creation. Use only the repositories you need. The service address selects the \
                API host; redirects are refused. Hosting tokens do not configure Git/SSH authentication. \
                Disconnect removes the local token; revoke it at the service if needed.
                """
            )
        note.font = .systemFont(ofSize: 11)
        gitPin(gitStack([heading, service, host, token, connect, note, connected, remove, status]), to: view, inset: 16)
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    @objc private func serviceChanged(_ sender: Any?) {
        host.stringValue = service.indexOfSelectedItem == 0 ? "https://github.com" : "https://gitlab.com"
        token.stringValue = ""
    }

    @objc private func connectAccount(_ sender: Any?) {
        guard connect.isEnabled, let url = URL(string: host.stringValue) else { return }

        let secret = token.stringValue
        token.stringValue = ""
        ownsPending = true
        model.connect(service: GitHostingService.allCases[service.indexOfSelectedItem], webURL: url, token: secret)
    }

    @objc private func disconnectAccount(_ sender: Any?) {
        guard remove.isEnabled, ids.indices.contains(connected.indexOfSelectedItem),
              let account = model.accounts.first(where: { $0.id == ids[connected.indexOfSelectedItem] }) else { return }

        ownsPending = true
        model.disconnect(account)
    }

    private func render() {
        let old = ids.indices.contains(connected.indexOfSelectedItem) ? ids[connected.indexOfSelectedItem] : nil
        ids = model.accounts.map(\.id)
        let names = model.accounts.map { $0.service.rawValue + " · " + $0.login + " · " + $0.webURL.absoluteString }
        if connected.itemTitles != names {
            connected.removeAllItems()
            connected.addItems(withTitles: names)
            if let old, let index = ids.firstIndex(of: old) { connected.selectItem(at: index) }
        }

        let busy = model.state == .loading
        if !busy { ownsPending = false }
        for control in [service, host, token, connected] as [NSControl] { control.isEnabled = !busy }
        connect.isEnabled = !busy && model.accounts.count < 16
        remove.isEnabled = !busy && !ids.isEmpty
        status.stringValue = busy ? "Checking account or updating secure storage…" : model.state.explanation
    }

    public func disconnect() {
        token.stringValue = ""
        if ownsPending { model.cancelPending() }
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
    }
}
