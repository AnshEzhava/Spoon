import Foundation
import Synchronization
import Testing
@testable import SpoonKit

/// §3.8 acceptance scenarios against real git and local "remotes".
@Suite struct GroupSyncTests {
    /// A clone that is `behind` commits behind its origin.
    func behindClone(_ behind: Int = 1) async throws -> (origin: TestRepo, clone: TestRepo) {
        let origin = try await TestRepo("origin")
        try await origin.commit("base", files: ["a": "a\n"])
        let clone = try await TestRepo(cloning: origin.url)
        for i in 0..<behind { try await origin.commit("remote \(i)", files: ["r\(i)": "\(i)\n"]) }
        return (origin, clone)
    }

    func target(_ r: TestRepo, excluded: Bool = false) -> SyncTarget {
        var m = GroupMember(repo: UUID())
        m.excluded = excluded
        return SyncTarget(id: m.repo, path: r.url, member: m)
    }

    func engine(_ configure: (inout SyncOptions) -> Void = { _ in }) -> GroupSync {
        var o = SyncOptions()
        configure(&o)
        return GroupSync(git: TestRepo.runner, options: o)
    }

    /// HEAD, local refs, index and worktree, for byte-identical comparisons. Remote-tracking refs may move: every run fetches.
    func fingerprint(_ r: TestRepo) async throws -> String {
        try await [r.run("rev-parse", "HEAD"), r.run("for-each-ref", "refs/heads", "refs/tags"), r.run("status", "--porcelain=v2", "-uall", "--no-ahead-behind"),
                   r.run("diff"), r.run("diff", "--cached"), r.run("stash", "list")].joined(separator: "\n--\n")
    }

    @Test func scenario1And9_sequentialPullUpdatesAllThenUndo() async throws {
        var pairs: [(TestRepo, TestRepo)] = []
        for _ in 0..<20 { pairs.append(try await behindClone(2)) }
        let targets = pairs.map { target($0.1) }
        let before = try await pairs.asyncMap { try await $0.1.run("rev-parse", "HEAD") }
        let results = await engine().run(.pull, targets)
        for ((_, r), (origin, clone)) in zip(results, pairs) {
            guard case .updated(_, _, _, let n) = r else { Issue.record("expected updated, got \(r)"); continue }
            #expect(n == 2)
            #expect(try await clone.run("rev-parse", "HEAD") == origin.run("rev-parse", "HEAD"))
        }
        let leftAlone = await GroupSync.undo(zip(pairs, results).map { ($0.0.1.url, $0.1.1) }, git: TestRepo.runner)
        #expect(leftAlone.isEmpty)
        #expect(try await pairs.asyncMap { try await $0.1.run("rev-parse", "HEAD") } == before)
    }

    @Test func scenario2_dirtyRepoSkippedUntouched() async throws {
        let (_, clone) = try await behindClone()
        try clone.write("a", "local edit\n")
        try clone.write("b", "staged\n")
        try await clone.run("add", "b")
        let before = try await fingerprint(clone)
        let results = await engine().run(.pull, [target(clone)])
        #expect(results[0].1 == .skipped(.dirty))
        #expect(try await fingerprint(clone) == before)
        #expect(try clone.read("a") == "local edit\n")
    }

    @Test func scenario3_divergedFFOnlySkipped() async throws {
        let (_, clone) = try await behindClone(2)
        try await clone.commit("local", files: ["l": "l\n"])
        let before = try await fingerprint(clone)
        let results = await engine().run(.pull, [target(clone)])
        #expect(results[0].1 == .skipped(.diverged(ahead: 1, behind: 2)))
        #expect(try await fingerprint(clone) == before)
    }

    @Test func scenario4_conflictingRebaseRestoresRepo() async throws {
        let origin = try await TestRepo("origin")
        try await origin.commit("base", files: ["a": "base\n"])
        let clone = try await TestRepo(cloning: origin.url)
        try await origin.commit("remote", files: ["a": "remote\n"])
        try await clone.commit("local", files: ["a": "local\n"])
        let before = try await fingerprint(clone)
        let results = await engine { $0.strategy = .rebase }.run(.pull, [target(clone)])
        guard case .failed(.conflicts, _) = results[0].1 else { Issue.record("expected conflicts, got \(results[0].1)"); return }
        let gitDir = clone.url.appendingPathComponent(".git")
        #expect(!FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path))
        #expect(!FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path))
        #expect(try await fingerprint(clone) == before)
        #expect(try clone.read("a") == "local\n")
    }

    @Test func scenario5_missingRepoSkippedRunContinues() async throws {
        let (_, gone) = try await behindClone()
        let (_, ok) = try await behindClone()
        try FileManager.default.removeItem(at: gone.url)
        let results = await engine().run(.pull, [target(gone), target(ok)])
        #expect(results[0].1 == .skipped(.missing))
        guard case .updated = results[1].1 else { Issue.record("expected updated, got \(results[1].1)"); return }
    }

    @Test func excludedMemberSkipped() async throws {
        let (_, clone) = try await behindClone()
        let results = await engine().run(.pull, [target(clone, excluded: true)])
        #expect(results[0].1 == .skipped(.excluded))
    }

    @Test func scenario6_networkCutThenRetry() async throws {
        let pairs = [try await behindClone(), try await behindClone(), try await behindClone()]
        // Cut the "network" for repos 2 and 3: their origin disappears.
        let moved = pairs[1...].map { $0.0.url.appendingPathExtension("away") }
        for (p, m) in zip(pairs[1...], moved) { try FileManager.default.moveItem(at: p.0.url, to: m) }
        let targets = pairs.map { target($0.1) }
        let start = Date()
        let results = await engine().run(.pull, targets)
        #expect(Date().timeIntervalSince(start) < 10)
        guard case .updated = results[0].1 else { Issue.record("expected updated, got \(results[0].1)"); return }
        for (_, r) in results.dropFirst() {
            guard case .failed(.network, _) = r else { Issue.record("expected network failure, got \(r)"); continue }
        }
        for (p, m) in zip(pairs[1...], moved) { try FileManager.default.moveItem(at: m, to: p.0.url) }
        let retry = Set(results.filter { $0.1.needsRetry }.map(\.0))
        let again = await engine().run(.pull, targets.filter { retry.contains($0.id) })
        #expect(again.count == 2)
        for (_, r) in again {
            guard case .updated = r else { Issue.record("expected updated on retry, got \(r)"); continue }
        }
    }

    /// Origin whose upload-pack sleeps first: a hung remote.
    func slowRemote(_ clone: TestRepo, seconds: Int) async throws {
        let script = clone.url.deletingLastPathComponent().appendingPathComponent("slow-upload-pack")
        try "#!/bin/sh\nsleep \(seconds)\nexec git-upload-pack \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try await clone.run("config", "remote.origin.uploadpack", script.path)
    }

    @Test func scenario7_cancelDuringFetch() async throws {
        let (_, first) = try await behindClone()
        let (_, second) = try await behindClone()
        try await slowRemote(first, seconds: 30)
        let sync = engine()
        let task = Task { await sync.run(.pull, [target(first), target(second)]) }
        try await Task.sleep(for: .seconds(1))
        let start = Date()
        task.cancel()
        let results = await task.value
        #expect(Date().timeIntervalSince(start) < 6)
        #expect(results.map(\.1) == [.cancelled, .cancelled])
        for r in [first, second] {
            #expect(!FileManager.default.fileExists(atPath: r.url.appendingPathComponent(".git/index.lock").path))
        }
    }

    @Test func scenario8_waitingForAuthPausesStallTimer() async throws {
        let (_, clone) = try await behindClone()
        try await slowRemote(clone, seconds: 3)
        let steps = Mutex<[SyncStep]>([])
        var sync = engine { $0.stallTimeout = 1 }
        sync.authPending = { _ in true }
        let results = await sync.run(.fetch, [target(clone)]) { _, s in steps.withLock { $0.append(s) } }
        #expect(results[0].1 == .fetched(newCommits: 1))
        #expect(steps.withLock { $0.contains(.waitingForAuth) })

        // Same hang without a pending prompt: the stall timer fires.
        let stalled = await engine { $0.stallTimeout = 1 }.run(.fetch, [target(clone)])
        guard case .failed(.stalled, _) = stalled[0].1 else { Issue.record("expected stalled, got \(stalled[0].1)"); return }
    }

    @Test func fetchReportsNewCommitsAndNoUpstreamIsFetchOnly() async throws {
        let (origin, clone) = try await behindClone(3)
        let fetched = await engine().run(.fetch, [target(clone)])
        #expect(fetched[0].1 == .fetched(newCommits: 3))
        try await clone.run("switch", "-q", "-c", "local-only")
        try await origin.commit("more")
        let pulled = await engine().run(.pull, [target(clone)])
        #expect(pulled[0].1 == .skipped(.noUpstream))
    }
}

extension Array {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await f(e)) }
        return out
    }
}
