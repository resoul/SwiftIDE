import AppKit

/// Reports an unexpected fall back to TextKit 1.
/// Never reads `NSTextView.layoutManager`: that access itself triggers the fallback.
@MainActor
public final class TextKitCompatibilityMonitor {
    private weak var textView: NSTextView?
    private var tokens: [NSObjectProtocol] = []
    public private(set) var didFallBackToTextKit1 = false
    public var onFallback: (@MainActor () -> Void)?

    public var isTextKit2: Bool { !didFallBackToTextKit1 && textView?.textLayoutManager != nil }

    init(textView: NSTextView) {
        self.textView = textView
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: NSTextView.didSwitchToNSLayoutManagerNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordFallback() }
        })
    }

    isolated deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    private func recordFallback() {
        didFallBackToTextKit1 = true
        onFallback?()
    }
}
