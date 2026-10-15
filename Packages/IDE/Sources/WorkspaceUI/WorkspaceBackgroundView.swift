import AppKit
import UITheme

@MainActor
final class WorkspaceBackgroundView: NSView {
    enum Role { case chrome, panel, editor }

    private let role: Role
    private let accent: NSColor?
    private let tint: CAGradientLayer?

    init(role: Role, accent: NSColor? = nil) {
        self.role = role
        self.accent = accent
        tint = accent == nil ? nil : CAGradientLayer()
        super.init(frame: .zero)
        wantsLayer = true
        if role != .chrome {
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
        }

        if let tint {
            tint.startPoint = CGPoint(x: 0, y: 1)
            tint.endPoint = CGPoint(x: 0.8, y: 0.2)
            layer?.addSublayer(tint)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint?.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            switch role {
            case .chrome: background = WorkspaceTheme.chromeBackground
            case .panel, .editor: background = WorkspaceTheme.background
            }

            layer?.backgroundColor = background.cgColor

            if let accent, let tint {
                tint.colors = [
                    accent.withAlphaComponent(WorkspaceTheme.chromeTintOpacity).cgColor,
                    accent.withAlphaComponent(0).cgColor
                ]
            }
        }
    }
}
