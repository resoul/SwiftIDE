import Foundation
import Testing
@testable import IDEApplication

struct GitHistoryGraphTests {
    private func commit(_ id: String, _ parents: [String]) -> GitCommit {
        .init(oid: id, parents: parents, author: "author", date: .now, subject: id)
    }

    @Test func mergeLanesJoinAtTheSharedAncestorAndRemainStableAcrossPages() throws {
        let values = [
            commit("merge", ["left", "right"]),
            commit("left", ["base"]),
            commit("right", ["base"]),
            commit("base", [])
        ]
        let first = GitHistoryGraph.layout(Array(values.prefix(2))), full = GitHistoryGraph.layout(values)
        #expect(first["merge"] == full["merge"] && first["left"] == full["left"])
        #expect(full["merge"]?.edges.filter { !$0.incoming }.count == 2)
        #expect(full["left"]?.lanes == 2 && full["right"]?.lanes == 2)
        #expect(full["base"]?.edges.filter { !$0.incoming }.isEmpty == true)
        #expect(full["right"]?.edges.contains { !$0.incoming && $0.from != $0.to } == true)
    }

    @Test func unrelatedRootsHaveNoInventedIncomingConnection() {
        let values = [commit("one", ["base"]), commit("two", []), commit("base", [])]
        let layout = GitHistoryGraph.layout(values)
        #expect(layout["two"]?.lane == 1)
        #expect(layout["two"]?.edges.contains { $0.incoming && $0.to == 1 } == false)
        #expect(layout["base"]?.lane == 0)
    }
}
