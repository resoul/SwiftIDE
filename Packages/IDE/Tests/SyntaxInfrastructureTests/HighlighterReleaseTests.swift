import Foundation
import IDEApplication
import IDEDomain
import Testing
@testable import SyntaxInfrastructure

/// Stopping a highlighter must give back what it holds: the copy of the text and the syntax tree.
/// That is the point of switching colours off for a file that grew too large.
@Test
func stoppingAHighlighterLetsGoOfItsTextAndItsTree() async throws {
    let highlighter = try TreeSitterHighlighter()
    let received = Received()
    highlighter.connect { received.add($0) }
    let units = Array(String(repeating: "struct A { var b = 1 }\n", count: 2_000).utf16)
    highlighter.reset(text: [units], version: 0)
    highlighter.requestHighlights(in: 0..<2_000, version: 0)
    await received.waitForFirst()

    let before = await highlighter.retainedState()
    #expect(before.units == units.count && before.hasTree)

    highlighter.stop()
    let after = await highlighter.retainedStateOnceEmpty()
    #expect(after.units == 0 && !after.hasTree)
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HighlightResult] = []
    func add(_ result: HighlightResult) { lock.withLock { results.append(result) } }
    var versions: [UInt64] { lock.withLock { results.map(\.version) } }
    func waitForFirst() async {
        for _ in 0..<4_000 {
            if lock.withLock({ !results.isEmpty }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

extension TreeSitterHighlighter {
    /// Polls: the stop message is handled on the highlighter's own thread.
    fileprivate func retainedStateOnceEmpty() async -> (units: Int, hasTree: Bool) {
        var state = await retainedState()
        for _ in 0..<1_000 where state.units != 0 || state.hasTree {
            try? await Task.sleep(for: .milliseconds(5))
            state = await retainedState()
        }
        return state
    }
}

// MARK: A burst of edits is not parsed once per edit

/// Typing fast while the highlighter is busy queues a request for every keystroke. Each answer for
/// an older version is thrown away by the editor, so parsing for it is wasted: at 10 MB sixty
/// keystrokes left the colours 2.2 seconds behind. Only the newest queued request needs an answer.
@Test
func aBurstOfRequestsQueuedBehindBusyWorkIsAnsweredOnceForTheNewest() async throws {
    let highlighter = try TreeSitterHighlighter()
    let received = Received()
    highlighter.connect { received.add($0) }
    // Busy first: a large text to parse keeps the worker occupied while the burst is queued.
    let big = Array(String(repeating: "struct A { var b = 1; func c() -> Int { b * 2 } }\n", count: 60_000).utf16)
    highlighter.reset(text: [big], version: 0)
    highlighter.requestHighlights(in: 0..<2_000, version: 0)

    var length = big.count
    for version in 1...50 {
        highlighter.edit(DocumentChangeSet(
            documentID: DocumentID(), oldVersion: UInt64(version - 1), newVersion: UInt64(version),
            edits: [DocumentEdit(range: UTF16TextRange(location: 10, length: 0), replacement: "x")], origin: .typing
        ))
        length += 1
        highlighter.requestHighlights(in: 0..<2_000, version: UInt64(version))
    }
    await received.waitFor(version: 50)

    let statistics = await highlighter.statistics()
    #expect(received.versions.last == 50, "the newest request is always answered")
    #expect(statistics.parses <= 3, "parsed \(statistics.parses) times for 51 requests")
    #expect(statistics.skipped >= 48)
    #expect(received.versions.allSatisfy { $0 == 0 || $0 >= 40 || $0 == received.versions.first }, "answers are for the first request or the newest ones")
}

extension Received {
    func waitFor(version: UInt64) async {
        for _ in 0..<6_000 {
            if versions.contains(version) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
