import AppKit

/// Close, minimise and zoom drawn as the system's traffic lights but at `scale` times their size
/// (the system buttons are fixed at 12 pt). The owner hides the native buttons.
@MainActor
final class WindowControlsView: NSStackView {
    /// 1 is the system size.
    static let scale: CGFloat = 2
    static let diameter: CGFloat = 12 * scale
    static let gap: CGFloat = 8 * scale
    static let width: CGFloat = 3 * diameter + 2 * gap

    private let lights = TrafficLight.Kind.allCases.map { TrafficLight(kind: $0) }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = Self.gap
        for light in lights {
            light.target = self
            light.action = #selector(press(_:))
            addArrangedSubview(light)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowStateChanged),
                name: name,
                object: window
            )
        }

        windowStateChanged()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { for light in lights { light.showsGlyph = true } }

    override func mouseExited(with event: NSEvent) { for light in lights { light.showsGlyph = false } }

    @objc private func windowStateChanged() {
        let active = window?.isKeyWindow ?? true
        for light in lights { light.isWindowActive = active }
    }

    @objc private func press(_ sender: TrafficLight) {
        guard let window else { return }

        switch sender.kind {
        case .close: window.performClose(sender)
        case .miniaturize: window.miniaturize(sender)
        case .zoom:
            if NSEvent.modifierFlags.contains(.option) { window.zoom(sender) } else { window.toggleFullScreen(sender) }
        }
    }
}

@MainActor
private final class TrafficLight: NSButton {
    enum Kind: CaseIterable {
        case close, miniaturize, zoom

        var label: String {
            switch self {
            case .close: "Close"
            case .miniaturize: "Minimize"
            case .zoom: "Full Screen"
            }
        }

        var colour: NSColor {
            switch self {
            case .close: NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1)
            case .miniaturize: NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)
            case .zoom: NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)
            }
        }
    }

    let kind: Kind
    var isWindowActive = true { didSet { needsDisplay = true } }
    var showsGlyph = false { didSet { needsDisplay = true } }

    init(kind: Kind) {
        self.kind = kind
        let side = WindowControlsView.diameter
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        setAccessibilityLabel(kind.label)
        toolTip = kind.label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        var fill = isWindowActive ? kind.colour : NSColor.tertiaryLabelColor
        if isHighlighted { fill = fill.blended(withFraction: 0.3, of: .black) ?? fill }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        fill.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        if showsGlyph, isWindowActive { drawGlyph() }
    }

    private func drawGlyph() {
        let unit = bounds.width / 12
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: centre.x + x * unit, y: centre.y + y * unit) }

        let ink = NSColor.black.withAlphaComponent(0.6)
        ink.setStroke()
        ink.setFill()
        let path = NSBezierPath()
        path.lineWidth = 1.2 * unit
        path.lineCapStyle = .round
        switch kind {
        case .close:
            path.move(to: point(-2.2, -2.2))
            path.line(to: point(2.2, 2.2))
            path.move(to: point(-2.2, 2.2))
            path.line(to: point(2.2, -2.2))
            path.stroke()
        case .miniaturize:
            path.move(to: point(-2.6, 0))
            path.line(to: point(2.6, 0))
            path.stroke()
        case .zoom:
            for sign in [CGFloat(1), -1] {
                let triangle = NSBezierPath()
                triangle.move(to: point(sign * 2.8, sign * 2.8))
                triangle.line(to: point(sign * -0.3, sign * 2.8))
                triangle.line(to: point(sign * 2.8, sign * -0.3))
                triangle.close()
                triangle.fill()
            }
        }
    }
}
