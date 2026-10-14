import AppKit
import UITheme

extension NSScrollView {
    /// A scroll view that stops at its ends instead of stretching past them and springing back.
    static func nonElastic() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.backgroundColor = WorkspaceTheme.background
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        return scroll
    }
}
