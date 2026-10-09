import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private struct Setup {
    let session: DocumentSession
    let monitor: LongLineMonitor
    let states: States

    @MainActor final class States { var seen: [LongLineMonitor.State] = [] }

    init(_ text: String, threshold: Int = 100) {
        let backend = StringDocumentBackend(loadedText: text)
        session = DocumentSession(path: "Main.swift", backend: backend)
        let index = DocumentLineIndex(session: session, source: backend)
        monitor = LongLineMonitor(lineIndex: index, policy: LongLinePolicy(threshold: threshold))
        let states = States()
        self.states = states
        monitor.onChange = { states.seen.append($0) }
    }

    func replace(_ range: Range<Int>, with text: String) throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: range.lowerBound, length: range.count), replacement: text)],
            expectedVersion: session.version
        )
    }
}

@Test @MainActor
func aFileOpensWithAWarningOnlyIfItHasALongLine() {
    #expect(Setup("short\nlines\n").monitor.state == .normal)
    let long = Setup("short\n" + String(repeating: "x", count: 150) + "\n")
    #expect(long.monitor.state == .warning)
    #expect(long.monitor.longestLength == 150)
}

@Test @MainActor
func theLimitItselfIsStillFine() {
    #expect(Setup(String(repeating: "x", count: 100)).monitor.state == .normal)
    #expect(Setup(String(repeating: "x", count: 101)).monitor.state == .warning)
}

@Test @MainActor
func aLongLineAppearingWhileEditingRaisesTheWarningOnceAndShorteningItLowersIt() throws {
    let s = Setup("a\nb\n")
    try s.replace(2..<2, with: String(repeating: "y", count: 200))
    #expect(s.monitor.state == .warning)
    try s.replace(5..<8, with: "z")           // still long
    #expect(s.states.seen == [.warning], "no repeat while it stays long")
    try s.replace(2..<202, with: "")          // gone
    #expect(s.monitor.state == .normal)
    #expect(s.states.seen == [.warning, .normal])
}

@Test @MainActor
func aDismissedWarningStaysDismissedForTheDocument() throws {
    let s = Setup(String(repeating: "x", count: 300))
    s.monitor.dismiss()
    #expect(s.monitor.state == .dismissed)
    try s.replace(0..<300, with: "short")
    try s.replace(0..<0, with: String(repeating: "w", count: 500))
    #expect(s.monitor.state == .dismissed, "it does not come back")
    #expect(s.states.seen == [.dismissed])
}

@Test @MainActor
func theWarningCountsContentNotTheLineBreak() {
    let s = Setup(String(repeating: "x", count: 100) + "\r\n" + String(repeating: "y", count: 100) + "\n")
    #expect(s.monitor.state == .normal)
}
