import Foundation
import LanguageInfrastructure
import Testing

/// Swift Testing does not run NSApplication's event loop, so its windows do not become key.
/// This isolated application runs that loop and links the built WorkspaceUI plus the production
/// App coordinator source, proving ownership while the other project's window really is active.
@Test
func aProjectQuestionBelongsToItsOwnerWhileAnotherProjectIsActuallyActive() async throws {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let products = app.appendingPathComponent(".build/debug").resolvingSymlinksInPath()
    let modules = FileManager.default.fileExists(atPath: products.appendingPathComponent("Modules").path)
        ? products.appendingPathComponent("Modules") : products
    var objects: [String] = []
    for module in ["IDEDomain", "IDEApplication", "IDETestSupport", "WorkspaceUI"] {
        let merged = products.appendingPathComponent("\(module).o")
        if FileManager.default.fileExists(atPath: merged.path) {
            objects.append(merged.path)
        } else {
            let directory = products.appendingPathComponent("\(module).build")
            objects += try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "o" }.map(\.path).sorted()
        }
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("active-project-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("main.swift")
    try activeProjectProbe.write(to: source, atomically: true, encoding: .utf8)
    let executable = folder.appendingPathComponent("probe")
    let coordinator = app.appendingPathComponent("Sources/SwiftIDE/Composition/ProjectTrustCoordinator.swift")
    _ = try await BoundedProcess.run(
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["swiftc",
                    "-swift-version",
                    "6",
                    "-I",
                    modules.path,
                    "-module-cache-path",
                    folder.appendingPathComponent("modules").path,
                    source.path,
                    coordinator.path] + objects + ["-o", executable.path],
        timeout: .seconds(60),
        outputLimit: 1_000_000
    )
    let output = try await BoundedProcess.run(executable: executable, arguments: [], timeout: .seconds(20), outputLimit: 10_000)
    #expect(String(decoding: output, as: UTF8.self) == "owned-A\n")
}

private let activeProjectProbe = #"""
import AppKit
import Darwin
import IDEApplication
import IDETestSupport

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await check() }
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 400, height: 240), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)

        return window
    }

    private func waitFor(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }

        return predicate()
    }

    private func check() async {
        let a = DocumentSession(path: "/w/A/main.swift", backend: StringDocumentBackend(loadedText: "let a = 1"))
        let b = DocumentSession(path: "/w/B/main.swift", backend: StringDocumentBackend(loadedText: "let b = 1"))
        let first = window(), second = window()
        let coordinator = ProjectTrustCoordinator { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
        coordinator.register(a, window: first)
        coordinator.register(b, window: second)
        NSApp.activate()
        second.makeKeyAndOrderFront(nil)
        guard await waitFor({ NSApp.keyWindow === second }) else {
            fail("project B never became key: running=\(NSApp.isRunning) active=\(NSApp.isActive) visible=\(second.isVisible) canKey=\(second.canBecomeKey) isKey=\(second.isKeyWindow) windows=\(NSApp.windows.count)")
        }

        let request = Task { await coordinator.ask(projectName: "A", root: URL(fileURLWithPath: "/w/A")) }
        guard await waitFor({ first.attachedSheet != nil }), let sheet = first.attachedSheet else { fail("no sheet on project A") }
        guard sheet.sheetParent === first, second.attachedSheet == nil, NSApp.modalWindow == nil else { fail("wrong owner or application modal") }
        first.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        guard await request.value == .granted else { fail("choice was not returned to project A") }
        coordinator.unregister(a)
        coordinator.unregister(b)
        first.close()
        second.close()
        print("owned-A")
        exit(0)
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
"""#
