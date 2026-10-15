import AppKit

@MainActor
func workspaceLabel(_ text: String, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 12, weight: weight)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor

    return field
}

@MainActor
func workspaceStack(
    _ views: [NSView],
    vertical: Bool,
    spacing: CGFloat = 0,
    insets: NSEdgeInsets = NSEdgeInsets()
) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = vertical ? .vertical : .horizontal
    view.alignment = vertical ? .leading : .top
    view.edgeInsets = insets
    view.distribution = .fill
    view.spacing = spacing
    views.forEach {
        $0.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            $0.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -insets.left - insets.right).isActive = true
        } else {
            $0.heightAnchor.constraint(equalTo: view.heightAnchor, constant: -insets.top - insets.bottom)
                .isActive = true
        }
    }

    return view
}

@MainActor
func workspacePadded(_ content: NSView, height: CGFloat) -> NSView {
    let view = NSView()
    view.heightAnchor.constraint(equalToConstant: height).isActive = true
    view.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
        content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        content.centerYAnchor.constraint(equalTo: view.centerYAnchor)
    ])

    return view
}

@MainActor
@discardableResult
func workspacePin(_ view: NSView, to parent: NSView) -> NSLayoutConstraint {
    parent.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    let top = view.topAnchor.constraint(equalTo: parent.topAnchor)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        top,
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
    ])

    return top
}

@MainActor
func workspaceSurface(_ content: NSView, role: WorkspaceBackgroundView.Role = .panel) -> NSView {
    let outer = NSView()
    let card = WorkspaceBackgroundView(role: role)
    workspacePin(content, to: card)
    outer.addSubview(card)
    card.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        card.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 1),
        card.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -1),
        card.topAnchor.constraint(equalTo: outer.topAnchor, constant: 1),
        card.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -1)
    ])

    return outer
}
