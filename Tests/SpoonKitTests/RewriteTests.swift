import Foundation
import Testing
@testable import SpoonKit

@Suite struct RewriteTests {
    func subjects(_ r: TestRepo) async throws -> [String] {
        try await r.run("log", "--format=%s").split(separator: "\n").map(String.init)
    }

    /// main: base ← m1; topic (from base): t1 ← t2.
    func branches(conflict: Bool = false) async throws -> TestRepo {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "base\n"])
        try await r.run("switch", "-q", "-c", "topic")
        try await r.commit("t1", files: ["t": "1\n"] .merging(conflict ? ["a": "topic\n"] : [:]) { $1 })
        try await r.commit("t2", files: ["t": "2\n"])
        try await r.run("switch", "-q", "main")
        try await r.commit("m1", files: ["m": "1\n"].merging(conflict ? ["a": "main\n"] : [:]) { $1 })
        return r
    }

    @Test func mergeTypesAndUndo() async throws {
        let r = try await branches()
        let repo = try await r.repository()
        let before = try await r.run("rev-parse", "HEAD")
        #expect(try await repo.merge("topic", type: .noFF, message: "Merge topic") == .completed)
        #expect(try await r.run("log", "-1", "--format=%s %p").hasPrefix("Merge topic"))
        try await repo.undo()
        #expect(try await r.run("rev-parse", "HEAD") == before)
        #expect(try await repo.merge("topic", type: .squash) == .completed)
        #expect(try await r.run("rev-parse", "HEAD") == before)
        #expect(try await r.run("diff", "--cached", "--name-only") == "t")
    }

    @Test func conflictingMergeStopsThenAbort() async throws {
        let r = try await branches(conflict: true)
        let repo = try await r.repository()
        #expect(try await repo.merge("topic") == .stopped)
        #expect(repo.operationInProgress == .merge)
        let sides = await repo.conflictSides()
        #expect(sides == ("main", "topic"))
        let segments = try await repo.conflictSegments("a")
        #expect(segments == [.conflict(ours: ["main\n"], base: ["base\n"], theirs: ["topic\n"])])
        await #expect(throws: RewriteError.self) { try await repo.continueOperation() }
        try await repo.abortOperation()
        #expect(repo.operationInProgress == nil)
        #expect(try r.read("a") == "main\n")
    }

    @Test func resolveInEditorThenContinue() async throws {
        let r = try await branches(conflict: true)
        let repo = try await r.repository()
        _ = try await repo.merge("topic")
        try await repo.resolveConflict("a", content: "both\n")
        #expect(try await repo.continueOperation() == .completed)
        #expect(repo.operationInProgress == nil)
        #expect(try await r.run("log", "-1", "--format=%p").split(separator: " ").count == 2)
        #expect(try r.read("a") == "both\n")
    }

    @Test func revertToConflictedRestoresMarkers() async throws {
        let r = try await branches(conflict: true)
        let repo = try await r.repository()
        _ = try await repo.merge("topic")
        try await repo.resolveConflict("a", content: "x\n")
        try await repo.revertToConflicted("a")
        #expect(try r.read("a").contains("<<<<<<<"))
        #expect(try await repo.status(background: false).conflicts.map(\.path) == ["a"])
    }

    @Test func rebaseOntoWithBackup() async throws {
        let r = try await branches()
        try await r.run("switch", "-q", "topic")
        let repo = try await r.repository()
        #expect(try await repo.rebase(onto: "main") == .completed)
        #expect(try await subjects(r) == ["t2", "t1", "m1", "base"])
        #expect(try await r.run("branch", "--list", "spoon/backup/topic-*").contains("spoon/backup/topic-"))
    }

    @Test func interactiveRebaseAllActions() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "0\n"])
        let base = try await r.run("rev-parse", "HEAD")
        for i in 1...5 { try await r.commit("c\(i)", files: ["f\(i)": "\(i)\n"]) }
        let repo = try await r.repository()
        var items = try await repo.rebaseCandidates(base: base).map { RebaseItem(commit: $0) }
        #expect(items.map(\.commit.subject) == ["c1", "c2", "c3", "c4", "c5"])
        items[1].action = .reword
        items[1].message = "c2 reworded\n\nwith body"
        items[2].action = .fixup
        items[3].action = .drop
        items.swapAt(0, 4) // c5 first, c1 last
        #expect(try await repo.interactiveRebase(base: base, items: items, options: .init(backup: false)) == .completed)
        #expect(try await subjects(r) == ["c1", "c2 reworded", "c5", "base"])
        #expect(try await r.run("log", "-1", "--skip=1", "--format=%b") == "with body")
        // c3's change folded into the reworded c2; c4 is gone.
        #expect(try await r.run("show", "--name-only", "--format=", "HEAD~1").split(separator: "\n").sorted() == ["f2", "f3"])
        #expect(!FileManager.default.fileExists(atPath: r.url.appendingPathComponent("f4").path))
        try await repo.undo()
        #expect(try await subjects(r) == ["c5", "c4", "c3", "c2", "c1", "base"])
    }

    @Test func quickActions() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "0\n"])
        let c1 = try await r.commit("c1", files: ["b": "1\n"])
        try await r.commit("c2", files: ["c": "2\n"])
        let c3 = try await r.commit("c3", files: ["d": "3\n"])
        let repo = try await r.repository()
        _ = try await repo.quickRewrite(c1, .reword("first"), options: .init(backup: false))
        #expect(try await subjects(r) == ["c3", "c2", "first", "base"])
        let c2 = try await r.run("rev-parse", "HEAD~1")
        _ = try await repo.quickRewrite(c2, .moveUp, options: .init(backup: false))
        #expect(try await subjects(r) == ["c2", "c3", "first", "base"])
        let top = try await r.run("rev-parse", "HEAD")
        _ = try await repo.quickRewrite(top, .fixupIntoParent, options: .init(backup: false))
        #expect(try await subjects(r) == ["c3", "first", "base"])
        let newTop = try await r.run("rev-parse", "HEAD")
        _ = try await repo.quickRewrite(newTop, .drop, options: .init(backup: false))
        #expect(try await subjects(r) == ["first", "base"])
        _ = c3
        // Amend staged changes into an older commit (RB-05), leaving an unstaged edit alone.
        try await r.commit("later", files: ["e": "e\n"])
        try r.write("b", "1\namended\n")
        try await r.run("add", "b")
        try r.write("e", "local\n")
        let first = try await r.run("rev-parse", "HEAD~1")
        _ = try await repo.amendStaged(into: first, options: .init(backup: false))
        #expect(try await subjects(r) == ["later", "first", "base"])
        #expect(try await r.run("show", "HEAD~1:b") == "1\namended")
        #expect(try r.read("e") == "local\n")
    }

    @Test func cherryPickRevertReset() async throws {
        let r = try await branches()
        let repo = try await r.repository()
        let t1 = try await r.run("rev-parse", "topic~1")
        #expect(try await repo.cherryPick([t1], recordOrigin: true) == .completed)
        #expect(try await r.run("log", "-1", "--format=%b").contains("cherry picked from commit \(t1)"))
        let picked = try await r.run("rev-parse", "HEAD")
        #expect(try await repo.revert([picked]) == .completed)
        #expect(try await r.run("log", "-1", "--format=%s") == "Revert \"t1\"")
        try r.write("m", "dirty\n")
        try await repo.reset(to: "HEAD~2", mode: .hard)
        #expect(try await subjects(r) == ["m1", "base"])
        #expect(try r.read("m") == "1\n")
        try await repo.undo()
        #expect(try r.read("m") == "dirty\n")
    }

    @Test func conflictingRebaseProgressAndSides() async throws {
        let r = try await branches(conflict: true)
        try await r.run("switch", "-q", "topic")
        let repo = try await r.repository()
        #expect(try await repo.rebase(onto: "main", options: .init(backup: false)) == .stopped)
        #expect(repo.operationInProgress == .rebase)
        #expect(repo.rebaseProgress?.step == 1)
        #expect(repo.rebaseProgress?.total == 2)
        let sides = await repo.conflictSides()
        #expect(sides.ours == "main")
        #expect(sides.theirs == "topic")
        try await repo.resolveConflict("a", content: "merged\n")
        #expect(try await repo.continueOperation() == .completed)
        #expect(try await subjects(r) == ["t2", "t1", "m1", "base"])
    }

    @Test func parsesConflictSegmentsAndWorktrees() {
        let text = "a\n<<<<<<< Yours\nours\n||||||| Base\nbase\n=======\ntheirs\n>>>>>>> Theirs\nz"
        #expect(ConflictSegment.parse(text) == [.common(["a\n"]), .conflict(ours: ["ours\n"], base: ["base\n"], theirs: ["theirs\n"]), .common(["z"])])
        let wt = Worktree.parse("worktree /r\nHEAD abc\nbranch refs/heads/main\n\nworktree /r-wt\nHEAD def\ndetached\nlocked\n")
        #expect(wt.map(\.branch) == ["main", nil])
        #expect(wt[1].locked)
        #expect(Submodule.parse(" abc lib/x (v1)\n-def lib/y\n").map(\.state) == [.clean, .uninitialized])
    }
}
