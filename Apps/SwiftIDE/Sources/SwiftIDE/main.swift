import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // A bare SwiftPM executable has no Info.plist; make it a regular foreground app.
    app.setActivationPolicy(.regular)
    app.run()
}
