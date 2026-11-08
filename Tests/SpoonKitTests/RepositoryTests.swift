import Foundation
import Testing
@testable import SpoonKit

@Suite struct RepositoryTests {
    @Test func checksPickedFolders() async throws {
        let repo = try await TestRepo()
        try await repo.commit("one", files: ["src/a.txt": "1\n"])
        let parent = TestRepo.tempDir("parent")
        let nested = parent.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try await TestRepo("inner", at: nested)
        let empty = TestRepo.tempDir("empty")
        let bare = try await TestRepo("bare", bare: true)
        let git = TestRepo.runner
        func real(_ u: URL) -> String { u.resolvingSymlinksInPath().path } // /var vs /private/var

        for picked in [repo.url, repo.url.appendingPathComponent("src")] {
            guard case .repository(let top) = await RepoScanner.check(picked, git: git) else { Issue.record("\(picked.path)"); continue }
            #expect(real(top) == real(repo.url))
        }
        guard case .notRepository(let found) = await RepoScanner.check(parent, git: git) else { Issue.record("parent"); return }
        #expect(found.map(real) == [real(nested)])
        guard case .notRepository(let none) = await RepoScanner.check(empty, git: git) else { Issue.record("empty"); return }
        #expect(none.isEmpty)
        guard case .unsupported(let why) = await RepoScanner.check(bare.url, git: git) else { Issue.record("bare"); return }
        #expect(why.contains("bare"))
    }

    @Test func statusRefsLogAgainstRealGit() async throws {
        let origin = try await TestRepo("origin")
        try await origin.commit("one", files: ["a.txt": "1\n"])
        try await origin.commit("two", files: ["a.txt": "1\n2\n"])
        let clone = try await TestRepo(cloning: origin.url)
        let opened = try await clone.repository()
        #expect(opened.gitDir == opened.commonDir)
        try await origin.commit("three", files: ["b.txt": "b\n"])
        try await clone.run("fetch", "-q")
        try await clone.commit("local", files: ["c.txt": "c\n"])

        // Working-copy changes: modify, stage a rename, untracked file, unicode path.
        try clone.write("a.txt", "1\n2\nchanged\n")
        try await clone.run("mv", "c.txt", "c renamed.txt")
        try clone.write("café/ñ.txt", "x\n")

        let repo = try await clone.repository()
        let status = try await repo.status()
        #expect(status.branch.head == "main" && status.branch.upstream == "origin/main")
        #expect(status.branch.ahead == 1 && status.branch.behind == 1)
        #expect(status.unstaged.map(\.path).sorted() == ["a.txt", "café/ñ.txt"])
        #expect(status.staged.first?.originalPath == "c.txt" && status.staged.first?.path == "c renamed.txt")

        let refs = try await repo.refs()
        let main = try #require(refs.first { $0.name == "refs/heads/main" })
        #expect(main.isHead && main.ahead == 1 && main.behind == 1)
        #expect(refs.contains { $0.name == "refs/remotes/origin/main" })
        #expect(!refs.contains { $0.name == "refs/remotes/origin/HEAD" })

        let pages = PageCollector()
        try await repo.log(pageSize: 2) { pages.add($0) }
        #expect(pages.all.map(\.subject).sorted() == ["local", "one", "three", "two"])

        let unstaged = try await repo.diffWorkingCopy(staged: false)
        #expect(unstaged.first?.path == "a.txt" && unstaged.first?.additions == 1)
        let untracked = try #require(try await repo.diffUntracked("café/ñ.txt"))
        #expect(untracked.status == .added && untracked.additions == 1)

        let head = try await clone.run("rev-parse", "HEAD")
        let details = try #require(try await repo.details(head))
        #expect(details.commit.subject == "local" && details.commit.authorName == "Kim Lee")
        let commitDiff = try await repo.diff(commit: head)
        #expect(commitDiff.map(\.path) == ["c.txt"])
        #expect(repo.headBranch == "main" && repo.operationInProgress == nil && !repo.isLocked)
    }

    @Test func detectsMergeInProgress() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["f": "base\n"])
        try await r.run("checkout", "-q", "-b", "feat")
        try await r.commit("feat", files: ["f": "feat\n"])
        try await r.run("checkout", "-q", "main")
        try await r.commit("main", files: ["f": "main\n"])
        _ = try? await r.run("merge", "feat")
        let repo = try await r.repository()
        #expect(repo.operationInProgress == .merge)
        #expect(try await repo.status().conflicts.map(\.path) == ["f"])
    }

    @Test func emptyRepo() async throws {
        let r = try await TestRepo()
        let repo = try await r.repository()
        let s = try await repo.status()
        #expect(s.branch.oid == nil && s.branch.head == "main" && s.isClean)
        let pages = PageCollector()
        _ = try? await repo.log { pages.add($0) }
        #expect(pages.all.isEmpty)
    }

    @Test func stashesListed() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["f": "1\n"])
        try r.write("f", "2\n")
        try await r.run("stash", "push", "-q", "-m", "first")
        try r.write("f", "3\n")
        try await r.run("stash", "push", "-q", "-m", "second")
        let stashes = try await r.repository().stashes()
        #expect(stashes.map(\.message) == ["On main: second", "On main: first"])
        #expect(stashes.map(\.refName) == ["stash@{0}", "stash@{1}"])
    }

    @Test func mutationsAreSerialized() async throws {
        let r = try await TestRepo()
        let repo = try await r.repository()
        let order = PageCollector()
        async let a: Void = repo.mutate {
            try await Task.sleep(for: .milliseconds(100))
            order.add([Commit.stub("a")])
        }
        try await Task.sleep(for: .milliseconds(10))
        async let b: Void = repo.mutate { order.add([Commit.stub("b")]) }
        _ = try await (a, b)
        #expect(order.all.map(\.sha) == ["a", "b"])
    }
}

final class PageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var commits: [Commit] = []
    func add(_ c: [Commit]) { lock.withLock { commits += c } }
    var all: [Commit] { lock.withLock { commits } }
}

extension Commit {
    static func stub(_ sha: String, parents: [String] = [], subject: String = "") -> Commit {
        Commit(sha: sha, parents: parents, authorName: "", authorEmail: "", authorDate: 0, committerName: "",
               committerEmail: "", commitDate: 0, decorations: [], subject: subject)
    }
}

@Suite struct FileWatcherTests {
    @Test func deliversWorktreeAndStateEvents() async throws {
        let r = try await TestRepo()
        try await r.commit("base", files: ["f": "1\n"])
        let repo = try await r.repository()
        let seen = ChangeBox()
        let watcher = FileWatcher(paths: [repo.workTree.path], queue: .global()) { paths, _ in
            seen.merge(RepoChange.classify(paths, workTree: repo.workTree.path, gitDir: repo.gitDir.path,
                                           commonDir: repo.commonDir.path))
        }
        try await Task.sleep(for: .milliseconds(300))
        try r.write("f", "2\n")
        try await r.run("checkout", "-q", "-b", "other")
        for _ in 0..<40 where !(seen.value.state && seen.value.paths.contains("f")) {
            try await Task.sleep(for: .milliseconds(100))
        }
        watcher.stop()
        #expect(seen.value.state)
        #expect(seen.value.paths.contains("f"))
    }
}

final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var change = RepoChange()
    func merge(_ c: RepoChange) {
        lock.withLock { change.state = change.state || c.state; change.paths.formUnion(c.paths) }
    }
    var value: RepoChange { lock.withLock { change } }
}
