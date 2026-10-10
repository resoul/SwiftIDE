import AppKit
import IDEApplication
import IDEDomain
import IDETestSupport
import LanguageInfrastructure
import Testing
@testable import SwiftIDE

@Suite(.serialized)
@MainActor
struct ProjectTrustCoordinatorTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)

        return window
    }

    private func session(_ path: String) -> DocumentSession {
        DocumentSession(path: path, backend: StringDocumentBackend(loadedText: "let x = 1"))
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }

        return condition()
    }

    @Test func theRequestUsesItsProjectWindowWithAnotherProjectWindowPresent() async throws {
        let a = session("/w/A/main.swift"), b = session("/w/B/main.swift")
        let first = window(), second = window()
        let coordinator = ProjectTrustCoordinator { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
        coordinator.register(a, window: first)
        coordinator.register(b, window: second)
        second.makeKey()
        let task = Task { await coordinator.ask(projectName: "A", root: URL(fileURLWithPath: "/w/A")) }
        defer { coordinator.unregister(a); coordinator.unregister(b); first.close(); second.close() }
        try #require(await waitFor { first.attachedSheet != nil })
        #expect(second.attachedSheet == nil)
        coordinator.unregister(a)
        #expect(await task.value == nil, "removing the owner cancels instead of storing a refusal")
    }

    @Test func withNoOwnerAnUnrelatedWindowDoesNotReceiveTheQuestion() async {
        let b = session("/w/B/main.swift")
        let unrelated = window()
        let coordinator = ProjectTrustCoordinator { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
        coordinator.register(b, window: unrelated)
        defer { coordinator.unregister(b); unrelated.close() }
        #expect(await coordinator.ask(projectName: "A", root: URL(fileURLWithPath: "/w/A")) == nil)
        #expect(unrelated.attachedSheet == nil)
    }

    @Test func anAnswerForAWindowThatMovedToAnotherRootIsNotAppliedToTheOldProject() async throws {
        let a = session("/w/A/main.swift")
        let parent = window()
        var currentRoot = URL(fileURLWithPath: "/w/A")
        let coordinator = ProjectTrustCoordinator { _ in currentRoot }
        coordinator.register(a, window: parent)
        let task = Task { await coordinator.ask(projectName: "A", root: currentRoot) }
        defer { coordinator.unregister(a); parent.close() }
        try #require(await waitFor { parent.attachedSheet != nil })
        currentRoot = URL(fileURLWithPath: "/w/B")
        parent.endSheet(try #require(parent.attachedSheet), returnCode: .alertSecondButtonReturn)
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); coordinator.unregister(a) }
        defer { watchdog.cancel() }
        #expect(await task.value == nil)
    }

    @Test func applicationCompositionRegistersTheDocumentWindowAndRemovesItOnClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "// package marker".write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = directory.appendingPathComponent("main.swift")
        try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
        let composition = AppCompositionRoot()
        let prompt = try #require(composition.languageServices.trustPrompt)
        let services = LanguageServices(scratchRoot: directory.appendingPathComponent("scratch"), makeService: { root, _ in
            SourceKitLanguageService(workspaceRoot: root, channelFactory: { throw LSPError.notRunning })
        })
        services.trustPrompt = prompt
        composition.languageServices = services
        let opened = try await composition.open(path: file.path)
        let controller = composition.makeWindow(for: opened.session)
        controller.onClose = { composition.close($0.session) }
        let parent = try #require(controller.window)
        parent.isReleasedWhenClosed = false
        controller.showWindow(nil)
        let task = Task { await prompt("A", directory) }
        defer { parent.close(); services.terminateAll() }
        try #require(await waitFor { parent.attachedSheet != nil })
        parent.close()
        #expect(await task.value == nil)
        #expect(await prompt("A", directory) == nil, "a closed document is not an owner")
    }
}
