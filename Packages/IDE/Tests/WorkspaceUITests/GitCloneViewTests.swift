import AppKit
import Testing
import IDEApplication
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct GitCloneViewTests {
    @Test func formValidatesDisablesInputsDuringCloneAndRetainsFailure() async throws {
        _ = NSApplication.shared
        let service = FormClone(), model = GitClone(service: service), controller = GitCloneViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: 0, width: 620, height: 440),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { model.stop(); controller.disconnect(); window.close() }
        _ = controller.view
        #expect(!controller.start.isEnabled)
        controller.parentDirectory = "/projects"
        controller.source.stringValue = "https://host/repo.git"
        controller.name.stringValue = "repo"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(controller.start.isEnabled)
        controller.startClone(nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while await service.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!controller.start.isEnabled && !controller.source.isEnabled && !controller.name.isEnabled)
        await service.fail()
        while model.state.isBusy, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.state == .failed("Denied by test server"))
        #expect(controller.source.stringValue == "https://host/repo.git" && controller.name.stringValue == "repo")
        #expect(controller.start.isEnabled && controller.cancel.title == "Close")
        if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_CLONE"] == "1" {
            window.orderFront(nil)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(40))
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let view = try #require(window.contentView),
                    bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/private/tmp/swiftide-clone-\(appearance.rawValue).png"))
            }
        }
    }
}
private actor FormClone: GitCloning {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<String, any Error>?
    func clone(_ request: GitCloneRequest, output: @escaping @Sendable (String) -> Void) async throws -> String {
        calls += 1

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output("Connecting…\n")
        }
    }
    func fail() {
        continuation?.resume(throwing: GitInspectionError.failed("Denied by test server"))
        continuation = nil
    }
}
