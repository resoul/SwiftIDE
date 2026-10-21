import AppKit

/// Reusable settings form. Where a choice is stored and what it changes belong to the host.
@MainActor
public final class SettingsViewController: NSViewController {
    public var onAppearanceChange: ((AppearancePreference) -> Void)?
    public var appearancePreference: AppearancePreference {
        didSet { if isViewLoaded { render() } }
    }

    /// The user ticked or cleared "Show tabs" or "Show spaces": the two choices as they are now.
    public var onEditorDisplayChange: ((_ tabs: Bool, _ spaces: Bool) -> Void)?
    public var showsTabs: Bool {
        didSet { if isViewLoaded { tabsBox.state = showsTabs ? .on : .off } }
    }

    public var showsSpaces: Bool {
        didSet { if isViewLoaded { spacesBox.state = showsSpaces ? .on : .off } }
    }

    public let tabsBox = NSButton(checkboxWithTitle: "Show tabs", target: nil, action: nil)
    public let spacesBox = NSButton(checkboxWithTitle: "Show spaces", target: nil, action: nil)
    public let appearanceControl = NSSegmentedControl()
    private let appearanceNote = NSTextField(wrappingLabelWithString: "")

    public init(appearance: AppearancePreference, showsTabs: Bool = false, showsSpaces: Bool = false) {
        appearancePreference = appearance
        self.showsTabs = showsTabs
        self.showsSpaces = showsSpaces
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = SettingsBackground(frame: NSRect(x: 0, y: 0, width: 460, height: 280))
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
        let editorHeading = NSTextField(labelWithString: "Editor")
        editorHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        tabsBox.target = self
        tabsBox.action = #selector(displayChosen(_:))
        tabsBox.setAccessibilityLabel("Show tabs")
        tabsBox.toolTip = "Marks every tab character with an arrow across its width"
        spacesBox.target = self
        spacesBox.action = #selector(displayChosen(_:))
        spacesBox.setAccessibilityLabel("Show spaces")
        spacesBox.toolTip = "Marks every space with a small dot"
        let displayNote = NSTextField(
            wrappingLabelWithString: "Only how the text is drawn; the text itself is not changed."
        )
        displayNote.font = .systemFont(ofSize: 11)
        displayNote.textColor = .secondaryLabelColor
        let content = gitStack([heading, row, appearanceNote, editorHeading, tabsBox, spacesBox, displayNote])
        content.spacing = 12
        content.setCustomSpacing(24, after: appearanceNote)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24)
        ])
        render()
    }

    @objc public func displayChosen(_ sender: Any?) {
        showsTabs = tabsBox.state == .on
        showsSpaces = spacesBox.state == .on
        onEditorDisplayChange?(showsTabs, showsSpaces)
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
        tabsBox.state = showsTabs ? .on : .off
        spacesBox.state = showsSpaces ? .on : .off
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
