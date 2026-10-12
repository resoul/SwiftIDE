import AppKit

/// Reusable settings form. Where a choice is stored and what it changes belong to the host.
@MainActor
public final class SettingsViewController: NSViewController {
    public var onAppearanceChange: ((AppearancePreference) -> Void)?
    public var appearancePreference: AppearancePreference {
        didSet { if isViewLoaded { render() } }
    }

    public let appearanceControl = NSSegmentedControl()
    private let appearanceNote = NSTextField(wrappingLabelWithString: "")

    public init(appearance: AppearancePreference) {
        appearancePreference = appearance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = SettingsBackground(frame: NSRect(x: 0, y: 0, width: 460, height: 190))
        let heading = NSTextField(labelWithString: "Appearance")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let theme = NSTextField(labelWithString: "Theme")
        appearanceControl.segmentCount = AppearancePreference.allCases.count
        for (index, preference) in AppearancePreference.allCases.enumerated() {
            appearanceControl.setLabel(preference.title, forSegment: index)
        }
        appearanceControl.segmentStyle = .rounded
        appearanceControl.trackingMode = .selectOne
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChosen(_:))
        appearanceControl.setAccessibilityLabel("Theme")
        appearanceNote.font = .systemFont(ofSize: 11)
        appearanceNote.textColor = .secondaryLabelColor
        let row = gitStack([theme, appearanceControl], vertical: false)
        row.spacing = 16
        let content = gitStack([heading, row, appearanceNote])
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24)
        ])
        render()
    }

    @objc public func appearanceChosen(_ sender: Any?) {
        let index = appearanceControl.selectedSegment
        guard AppearancePreference.allCases.indices.contains(index) else { return }

        let chosen = AppearancePreference.allCases[index]
        guard chosen != appearancePreference else { return }

        appearancePreference = chosen
        onAppearanceChange?(chosen)
    }

    private func render() {
        appearanceControl.selectedSegment = AppearancePreference.allCases.firstIndex(of: appearancePreference) ?? 0
        appearanceNote.stringValue = appearancePreference == .system
            ? "Follows the appearance chosen in macOS."
            : "\(appearancePreference.title) is used in every SwiftIDE window, whatever macOS uses."
    }
}

@MainActor
private final class SettingsBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}
