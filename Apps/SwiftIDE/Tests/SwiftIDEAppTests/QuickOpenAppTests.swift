import AppKit
import IDEApplication
import Testing
import WorkspaceUI
@testable import SwiftIDE

private struct ListedFiles: ProjectFileLister {
    let paths: [String]

    func listFiles(under root: String) async -> ProjectFileList { ProjectFileList(paths: paths) }
}

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct QuickOpenAppTests {
        private func wait(until condition: () -> Bool) async throws {
            for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        }

        @Test func theWindowListsFilesFromTheModelFiltersWhileTypingAndOpensTheChosenOne() async throws {
            _ = NSApplication.shared
            let model = QuickOpen(
                root: "/w",
                lister: ListedFiles(paths: [
                    "Package.swift",
                    "Sources/App/MainMenu.swift",
                    "Sources/App/AppDelegate.swift"
                ])
            )
            var opened: [String] = []
            let controller = QuickOpenController(model: model) { opened.append($0) }
            controller.toggle(over: nil)
            #expect(controller.isShown)
            try await wait { controller.content.results.count == 3 }
            #expect(controller.content.results.map(\.title) == ["Package.swift", "MainMenu.swift", "AppDelegate.swift"])
            controller.content.query = "menu"
            #expect(controller.content.results.map(\.id) == ["Sources/App/MainMenu.swift"])
            #expect(controller.content.results.first?.group == "Sources/App")
            controller.content.run?(try #require(controller.content.selectedCommand))
            #expect(!controller.isShown)
            try await wait { !opened.isEmpty }
            #expect(opened == ["/w/Sources/App/MainMenu.swift"])
            controller.stop()
        }

        @Test func stoppingClosesTheWindowAndNothingIsListedAfterwards() async throws {
            _ = NSApplication.shared
            let model = QuickOpen(root: "/w", lister: ListedFiles(paths: ["a.swift"]))
            let controller = QuickOpenController(model: model) { _ in }
            controller.toggle(over: nil)
            controller.stop()
            #expect(!controller.isShown && model.state == .idle)
            try await Task.sleep(for: .milliseconds(50))
            #expect(model.fileCount == 0, "a listing that finishes after stop is dropped")
        }
    }
}
