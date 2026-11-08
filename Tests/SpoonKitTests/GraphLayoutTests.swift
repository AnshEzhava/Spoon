import Testing
@testable import SpoonKit

@Suite struct GraphLayoutTests {
    func layout(_ spec: [(String, [String])], main: String? = nil) -> [GraphRow] {
        var g = GraphLayout(mainTip: main)
        g.append(spec.map { Commit.stub($0.0, parents: $0.1) })
        return g.rows
    }

    @Test func linearHistoryStaysInLaneZero() {
        let rows = layout([("c", ["b"]), ("b", ["a"]), ("a", [])], main: "c")
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.allSatisfy { $0.color == 0 })
        #expect(rows[2].outgoing.isEmpty && rows[0].incoming.isEmpty && rows[1].incoming.count == 1)
    }

    @Test func mergeAndBranchUseSecondLaneThenFreeIt() {
        // m = merge(a, f); f on feature from o; a on main from o
        let rows = layout([("m", ["a", "f"]), ("f", ["o"]), ("a", ["o"]), ("o", ["r"]), ("r", [])], main: "m")
        #expect(rows.map(\.lane) == [0, 1, 0, 0, 0])
        #expect(rows[0].outgoing.map(\.to) == [0, 1])
        #expect(rows[1].through.map(\.from) == [0])
        #expect(rows[3].incoming.map(\.from).sorted() == [0, 1])  // both lines converge on the base
        #expect(rows[4].width == 1)  // lane 1 freed
    }

    @Test func mainKeepsLaneZeroEvenWhenAnotherTipIsNewer() {
        let rows = layout([("x", ["m"]), ("m", ["o"]), ("o", [])], main: "m")
        #expect(rows[0].lane == 1)  // feature tip above main
        #expect(rows[1].lane == 0 && rows[1].incoming.map(\.from) == [1])
        #expect(rows[0].through.isEmpty)  // reservation is not drawn
    }

    @Test func freedLanesAreReusedWithoutShifting() {
        // two short-lived side branches; second should reuse lane 1
        let rows = layout([
            ("t1", ["p1"]), ("p1", ["base1"]),
            ("main3", ["main2"]), ("main2", ["base1"]), ("base1", ["t2"]),
            ("t2", ["root"]), ("root", []),
        ], main: "main3")
        #expect(rows[0].lane == 1 && rows[2].lane == 0 && rows[4].lane == 0)
        #expect(rows[4].incoming.map(\.from).sorted() == [0, 1])
    }

    @Test func octopusMerge() {
        let rows = layout([("m", ["a", "b", "c"]), ("c", ["o"]), ("b", ["o"]), ("a", ["o"]), ("o", [])], main: "m")
        #expect(rows[0].outgoing.map(\.to) == [0, 1, 2])
        #expect(rows[4].incoming.count == 3)
    }
}
