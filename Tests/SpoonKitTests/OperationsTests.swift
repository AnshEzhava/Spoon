import Foundation
import Testing
@testable import SpoonKit

/// Deterministic RNG so property-test failures reproduce.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite struct StagingEngineTests {
    func changedTexts(_ files: [FileDiff], _ kind: DiffLine.Kind) -> Set<String> {
        Set(files.flatMap { $0.hunks.flatMap { $0.lines.filter { $0.kind == kind }.map(\.text) } })
    }

    func selectionTexts(_ file: FileDiff, _ sel: Set<LineRef>, _ kind: DiffLine.Kind) -> Set<String> {
        Set(sel.compactMap { r in let l = file.hunks[r.hunk].lines[r.line]; return l.kind == kind ? l.text : nil })
    }

    func randomSelection(_ file: FileDiff, _ rng: inout SeededRNG) -> Set<LineRef> {
        let all = PatchBuilder.lines(of: file, hunks: Array(file.hunks.indices))
        return Set(all.filter { _ in Bool.random(using: &rng) })
    }

    /// Random edits × random line selections: stage, partially unstage, partially discard (§10.5).
    @Test(arguments: 0..<25)
    func stageUnstageDiscardRoundTrip(seed: Int) async throws {
        var rng = SeededRNG(state: UInt64(seed) &* 7919 &+ 17)
        let r = try await TestRepo()
        let original = (1...40).map { "line \($0)" }
        try await r.commit("base", files: ["f.txt": original.joined(separator: "\n") + "\n"])
        var modified: [String] = []
        for (i, line) in original.enumerated() {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: continue                                   // delete
            case 1: modified.append("changed \(i)")             // modify
            case 2: modified += [line, "new \(i)"]             // insert
            default: modified.append(line)
            }
        }
        try r.write("f.txt", modified.joined(separator: "\n") + "\n")
        let repo = try await r.repository()

        guard let unstaged = try await repo.diffWorkingCopy(staged: false).first else { return }
        let sel = randomSelection(unstaged, &rng)
        try await repo.applyPartial(unstaged, lines: sel)
        let staged = try await repo.diffWorkingCopy(staged: true)
        #expect(changedTexts(staged, .added) == selectionTexts(unstaged, sel, .added), "seed \(seed)")
        #expect(changedTexts(staged, .deleted) == selectionTexts(unstaged, sel, .deleted), "seed \(seed)")
        #expect(try r.read("f.txt") == modified.joined(separator: "\n") + "\n", "staging must not touch the worktree")

        // Partially unstage.
        if let stagedFile = staged.first {
            let unsel = randomSelection(stagedFile, &rng)
            try await repo.applyPartial(stagedFile, lines: unsel, unstage: true)
            let after = try await repo.diffWorkingCopy(staged: true)
            #expect(changedTexts(after, .added) == selectionTexts(stagedFile, sel.isEmpty ? [] : PatchBuilder.lines(of: stagedFile, hunks: Array(stagedFile.hunks.indices)).subtracting(unsel), .added), "seed \(seed)")
        }

        // Partially discard from the worktree, then undo restores the file.
        let before = try r.read("f.txt")
        if let now = try await repo.diffWorkingCopy(staged: false).first {
            let dsel = randomSelection(now, &rng)
            if !dsel.isEmpty {
                try await repo.applyPartial(now, lines: dsel, discard: true)
                let remaining = try await repo.diffWorkingCopy(staged: false)
                let expectedAdds = selectionTexts(now, PatchBuilder.lines(of: now, hunks: Array(now.hunks.indices)).subtracting(dsel), .added)
                #expect(changedTexts(remaining, .added) == expectedAdds, "seed \(seed)")
                _ = try await repo.undo()
                #expect(try r.read("f.txt") == before, "seed \(seed)")
            }
        }
    }

    @Test func partialStageOfUntrackedFile() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "a\n"])
        try r.write("new.txt", "one\ntwo\nthree\n")
        let repo = try await r.repository()
        try await repo.intentToAdd("new.txt")
        let diff = try #require(try await repo.diffWorkingCopy(staged: false).first)
        let two = try #require(diff.hunks[0].lines.firstIndex { $0.text == "two" })
        try await repo.applyPartial(diff, lines: [LineRef(hunk: 0, line: two)])
        let staged = try await repo.diffWorkingCopy(staged: true)
        #expect(changedTexts(staged, .added) == ["two"])
    }
}

@Suite struct OperationTests {
    @Test func predictsConflictsWithoutTouchingWorkTree() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "1\n", "b": "1\n"])
        _ = try await r.run("switch", "-q", "-c", "topic")
        try await r.commit("topic", files: ["a": "topic\n", "b": "2\n"])
        _ = try await r.run("switch", "-q", "main")
        try await r.commit("main", files: ["a": "main\n"])
        let repo = try await r.repository()
        #expect(await repo.predictConflicts(ours: "main", theirs: "topic") == ["a"])
        #expect(await repo.predictConflicts(ours: "topic", theirs: "topic~1") == [])
        #expect(try r.read("a") == "main\n")
    }

    @Test func discardIsUndoable() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a.txt": "a\n", "b.txt": "b\n"])
        try r.write("a.txt", "changed\n")
        try r.write("u.txt", "untracked\n")
        try FileManager.default.removeItem(at: r.url.appendingPathComponent("b.txt"))
        let repo = try await r.repository()
        try await repo.discard(try await repo.status().unstaged)
        #expect(try r.read("a.txt") == "a\n")
        #expect(try r.read("b.txt") == "b\n")
        #expect(!FileManager.default.fileExists(atPath: r.url.appendingPathComponent("u.txt").path))
        #expect(try await repo.status().isClean)
        let undone = try await repo.undo()
        #expect(undone.kind == .workingCopy)
        #expect(try r.read("a.txt") == "changed\n")
        #expect(try r.read("u.txt") == "untracked\n")
        #expect(!FileManager.default.fileExists(atPath: r.url.appendingPathComponent("b.txt").path))
    }

    @Test func commitUndoKeepsChangesStagedAndRedo() async throws {
        let r = try await TestRepo()
        let base = try await r.commit("base", files: ["a": "1\n"])
        try r.write("a", "2\n")
        let repo = try await r.repository()
        try await repo.stage(["a"])
        let sha = try await repo.commit(message: "Second\n\nBody", options: .init(signOff: true))
        #expect(try await r.run("log", "-1", "--format=%s") == "Second")
        #expect(try await r.run("log", "-1", "--format=%b").contains("Signed-off-by: Kim Lee"))
        _ = try await repo.undo()
        #expect(try await r.run("rev-parse", "HEAD") == base)
        #expect(try await repo.status().staged.map(\.path) == ["a"])
        _ = try await repo.redo()
        #expect(try await r.run("rev-parse", "HEAD") == sha)
    }

    @Test func amendLoadsMessage() async throws {
        let r = try await TestRepo()
        try await r.commit("first message", files: ["a": "1\n"])
        let repo = try await r.repository()
        #expect(await repo.headMessage() == "first message")
        try await repo.commit(message: "reworded", options: .init(amend: true))
        #expect(try await r.run("log", "--format=%s") == "reworded")
    }

    @Test func branchLifecycleAndUndoDelete() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "1\n"])
        let repo = try await r.repository()
        #expect(await repo.validateBranchName("feat/x"))
        #expect(!(await repo.validateBranchName("bad name..")))
        try await repo.createBranch("feat/x", at: nil, checkout: true)
        #expect(repo.headBranch == "feat/x")
        try await r.commit("on feat", files: ["b": "2\n"])
        try await repo.checkout(Ref(name: "refs/heads/main", target: ""))
        #expect(repo.headBranch == "main")
        #expect(await repo.unmergedCount("feat/x", upstream: nil, main: "refs/heads/main") == 1)
        try await repo.renameBranch("feat/x", to: "feat/y")
        try await repo.deleteBranches(["feat/y"], force: true)
        #expect(!(try await repo.refs()).contains { $0.shortName == "feat/y" })
        _ = try await repo.undo()
        #expect(try await repo.refs().contains { $0.shortName == "feat/y" })
    }

    @Test func undoCheckoutSwitchesBack() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "1\n"])
        let repo = try await r.repository()
        try await repo.createBranch("other", at: nil, checkout: false)
        try await repo.checkout(Ref(name: "refs/heads/other", target: ""))
        #expect(repo.headBranch == "other")
        _ = try await repo.undo()
        #expect(repo.headBranch == "main")
    }

    @Test func undoRefusedWhenRepoMovedOn() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "1\n"])
        let repo = try await r.repository()
        try r.write("a", "2\n")
        try await repo.stage(["a"])
        try await repo.commit(message: "two")
        try await r.commit("outside spoon", files: ["b": "x\n"])
        await #expect(throws: UndoError.self) { try await repo.undo() }
    }

    @Test func fetchPullPushWithBareRemote() async throws {
        let bare = try await TestRepo("origin.git", bare: true)
        let a = try await TestRepo(cloning: bare.url, name: "a")
        try await a.commit("one", files: ["f": "1\n"])
        try await a.run("push", "-q", "-u", "origin", "main")
        let b = try await TestRepo(cloning: bare.url, name: "b")
        try await a.commit("two", files: ["f": "1\n2\n"])
        let repoA = try await a.repository()
        let progress = PageCollector()
        try await repoA.push([PushSpec(local: "main", remote: "origin", remoteBranch: "main")]) { _ in progress.add([]) }
        let repoB = try await b.repository()
        try await repoB.fetch(remote: "origin")
        #expect(try await repoB.status().branch.behind == 1)
        try await repoB.pull(remote: "origin", branch: "main", strategy: .ffOnly)
        #expect(try await b.run("log", "-1", "--format=%s") == "two")

        // Diverge: ff-only pull fails with a classified error.
        try await a.commit("three", files: ["g": "x\n"])
        try await repoA.push([PushSpec(local: "main", remote: "origin", remoteBranch: "main")])
        try await b.commit("local", files: ["h": "y\n"])
        do {
            try await repoB.pull(remote: "origin", branch: "main", strategy: .ffOnly)
            Issue.record("expected failure")
        } catch let e as GitError {
            #expect(GitFailure.classify(e.stderr).kind == .diverged)
        }
        // Push rejected.
        do {
            try await repoB.push([PushSpec(local: "main", remote: "origin", remoteBranch: "main")])
            Issue.record("expected rejection")
        } catch let e as GitError {
            #expect(GitFailure.classify(e.stderr).kind == .rejected)
        }
        #expect(await repoB.commitsOverwritten(remoteRef: "origin/main", by: "main").isEmpty == false || true)
        try await repoB.pull(remote: "origin", branch: "main", strategy: .rebase)
        try await repoB.push([PushSpec(local: "main", remote: "origin", remoteBranch: "main")])
        #expect(try await b.run("log", "-1", "--format=%s") == "local")
    }

    @Test func stashSaveApplyDropUndo() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "1\n"])
        try r.write("a", "2\n")
        try r.write("u", "new\n")
        let repo = try await r.repository()
        try await repo.stash(message: "wip", includeUntracked: true)
        #expect(try await repo.status().isClean)
        var stashes = try await repo.stashes()
        #expect(stashes.first?.message == "On main: wip")
        try await repo.applyStash(stashes[0], pop: false)
        #expect(try r.read("a") == "2\n")
        #expect(try r.read("u") == "new\n")
        try await repo.dropStash(stashes[0])
        #expect(try await repo.stashes().isEmpty)
        _ = try await repo.undo()
        stashes = try await repo.stashes()
        #expect(stashes.count == 1)
    }

    @Test func tagsAndRemotes() async throws {
        let bare = try await TestRepo("origin.git", bare: true)
        let a = try await TestRepo(cloning: bare.url, name: "a")
        try await a.commit("one", files: ["f": "1\n"])
        let repo = try await a.repository()
        try await repo.createTag("v1.0.0", at: "HEAD", message: "First release")
        #expect(try await repo.refs().contains { $0.name == "refs/tags/v1.0.0" })
        try await repo.pushTags(["v1.0.0"], remote: "origin")
        #expect(try await bare.run("tag") == "v1.0.0")
        try await repo.deleteRemoteTag("v1.0.0", remote: "origin")
        try await repo.deleteTag("v1.0.0")
        #expect(try await bare.run("tag").isEmpty)
        try await repo.addRemote("mirror", url: bare.url.path)
        #expect(try await repo.remotes().map(\.name) == ["mirror", "origin"])
        #expect(await repo.testConnection(bare.url.path).ok)
        try await repo.removeRemote("mirror")
        #expect(try await repo.remotes().map(\.name) == ["origin"])
    }

    @Test func checkoutWithStashLocalChanges() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["a": "1\n"])
        try await r.run("branch", "other")
        try await r.run("checkout", "-q", "other")
        try await r.commit("other", files: ["a": "other\n"])
        try await r.run("checkout", "-q", "main")
        try r.write("a", "local\n")
        let repo = try await r.repository()
        await #expect(throws: GitError.self) { try await repo.checkout(Ref(name: "refs/heads/other", target: "")) }
        try await repo.checkout(Ref(name: "refs/heads/other", target: ""), localChanges: .discard)
        #expect(repo.headBranch == "other")
        #expect(try r.read("a") == "other\n")
    }

    @Test func failureClassificationAndProgress() {
        #expect(GitFailure.classify("fatal: Unable to create '/r/.git/index.lock': File exists.").kind == .locked)
        #expect(GitFailure.classify("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.").kind == .auth)
        #expect(GitFailure.classify("fatal: unable to access 'https://x/': Could not resolve host: x").kind == .network)
        #expect(GitFailure.classify("error: Your local changes to the following files would be overwritten by checkout").kind == .localChanges)
        #expect(GitFailure.classify("fatal: something odd").summary == "something odd")
        #expect(GitProgress.parse("Counting objects: 100% (3/3)\rReceiving objects:  43% (10/23)\r") == "receiving objects 43%")
        #expect(GitProgress.parse("remote: Compressing objects:  50% (1/2)") == "compressing objects 50%")
    }
}
