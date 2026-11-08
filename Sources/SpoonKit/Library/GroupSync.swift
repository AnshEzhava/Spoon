import Foundation
import Synchronization

// Group Sync engine (§3.4): preflight → fetch → integrate, one result per repo.

public enum SkipReason: Sendable, Equatable {
    case missing, notRepo, excluded, locked, inProgress(RepoOperation), dirty, diverged(ahead: Int, behind: Int), noUpstream, noRemote, detached

    public var description: String {
        switch self {
        case .missing: "Missing"
        case .notRepo: "Not a repository"
        case .excluded: "Excluded"
        case .locked: "Locked by another git process"
        case .inProgress(let op): "\(op.title) in progress"
        case .dirty: "Uncommitted changes"
        case .diverged(let a, let b): "Diverged (↑\(a) ↓\(b))"
        case .noUpstream: "No upstream"
        case .noRemote: "No remote"
        case .detached: "Detached HEAD"
        }
    }
}

public enum SyncError: Sendable, Equatable {
    case conflicts, autostashConflict, network, auth, stalled, other(String)

    public var description: String {
        switch self {
        case .conflicts: "Conflicts — repo restored"
        case .autostashConflict: "Updated, but reapplying local changes conflicted — they're kept in the stash"
        case .network: "Couldn't reach the remote"
        case .auth: "Authentication failed"
        case .stalled: "No progress — timed out"
        case .other(let s): s
        }
    }
}

public enum RepoSyncResult: Sendable, Equatable {
    case updated(branch: String, from: String, to: String, commits: Int)
    case upToDate(ahead: Int)
    case fetched(newCommits: Int)
    case skipped(SkipReason)
    case failed(SyncError, log: String)
    case cancelled

    public var isFailure: Bool { if case .failed = self { true } else { false } }
    public var isSkip: Bool { if case .skipped = self { true } else { false } }
    public var needsRetry: Bool { isFailure || isSkip || self == .cancelled }

    public var kind: String {
        switch self {
        case .updated: "updated"
        case .upToDate: "upToDate"
        case .fetched: "fetched"
        case .skipped: "skipped"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    public var summary: String {
        switch self {
        case .updated(_, _, _, let n): "+\(n) commit\(n == 1 ? "" : "s")"
        case .upToDate(let a): a > 0 ? "Up to date · \(a) to push" : "Up to date"
        case .fetched(let n): n > 0 ? "\(n) new commit\(n == 1 ? "" : "s")" : "Fetched"
        case .skipped(let r): r.description
        case .failed(let e, _): e.description
        case .cancelled: "Cancelled"
        }
    }
}

public enum SyncStep: Sendable, Equatable {
    case queued, preflight, fetching(String), waitingForAuth, integrating, done(RepoSyncResult)
}

public enum SyncAction: String, Sendable { case fetch, pull }

public struct SyncTarget: Sendable {
    public var id: UUID
    public var path: URL
    public var member: GroupMember
    public init(id: UUID, path: URL, member: GroupMember) { self.id = id; self.path = path; self.member = member }
}

public struct GroupSync: Sendable {
    public var git: GitRunner
    public var options: SyncOptions
    /// OpLog title for each repo's integrate step.
    public var title: String
    /// True while an askpass prompt for this repo path is waiting on the user; pauses the stall timer.
    public var authPending: (@Sendable (String) -> Bool)?

    public init(git: GitRunner, options: SyncOptions, title: String = "Group sync") {
        self.git = git
        self.options = options
        self.title = title
    }

    struct Stalled: Error {}

    /// Runs `action` over `targets` in order with up to `options.concurrency` at a time.
    /// Cancelling the calling task kills in-flight fetches; integrate steps always finish (§3.4 invariant 2).
    public func run(_ action: SyncAction, _ targets: [SyncTarget],
                    onStep: @escaping @Sendable (UUID, SyncStep) -> Void = { _, _ in }) async -> [(UUID, RepoSyncResult)] {
        var results: [UUID: RepoSyncResult] = [:]
        for t in targets { onStep(t.id, .queued) }
        await withTaskGroup(of: (UUID, RepoSyncResult).self) { group in
            var queue = targets.enumerated().makeIterator()
            var stop = false
            func launch() {
                guard !stop, !Task.isCancelled, let (i, t) = queue.next() else { return }
                group.addTask {
                    if i > 0, options.delaySeconds > 0 { try? await Task.sleep(for: .seconds(options.delaySeconds)) }
                    let r = Task.isCancelled ? .cancelled : await sync(action, t, onStep)
                    onStep(t.id, .done(r))
                    return (t.id, r)
                }
            }
            for _ in 0..<min(max(options.concurrency, 1), 8) { launch() }
            for await (id, r) in group {
                results[id] = r
                if r.isFailure && options.stopOnFailure { stop = true }
                launch()
            }
        }
        return targets.map { t in
            if let r = results[t.id] { return (t.id, r) }
            onStep(t.id, .done(.cancelled))
            return (t.id, .cancelled)
        }
    }

    func sync(_ action: SyncAction, _ t: SyncTarget, _ onStep: @escaping @Sendable (UUID, SyncStep) -> Void) async -> RepoSyncResult {
        // PREFLIGHT: no network, no mutation.
        onStep(t.id, .preflight)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: t.path.path, isDirectory: &isDir), isDir.boolValue else { return .skipped(.missing) }
        guard let repo = try? await Repository.open(t.path, git: git) else { return .skipped(.notRepo) }
        if t.member.excluded { return .skipped(.excluded) }
        if repo.isLocked { return .skipped(.locked) }
        if let op = repo.operationInProgress { return .skipped(.inProgress(op)) }
        guard let status = try? await repo.status() else { return .skipped(.notRepo) }
        let branch = status.branch.head
        let fetchOnly: SkipReason? = branch == nil ? .detached : status.branch.upstream == nil ? .noUpstream : nil

        // FETCH
        var remote = t.member.remote
        if remote == nil, !options.fetchAllRemotes, let branch { remote = await repo.config("branch.\(branch).remote") }
        if remote == ".", !options.fetchAllRemotes { remote = nil }
        let remotes = (try? await repo.remotes())?.map(\.name) ?? []
        if remote == nil, !options.fetchAllRemotes { remote = remotes.first }
        if remotes.isEmpty { return .skipped(fetchOnly ?? .noRemote) }

        let before = await revParse(repo, "@{u}")
        onStep(t.id, .fetching(""))
        do {
            try await fetch(repo, remote: remote, id: t.id, onStep)
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            if error is Stalled { return .failed(.stalled, log: "No output for \(Int(options.stallTimeout)) s") }
            let stderr = (error as? GitError)?.stderr ?? "\(error)"
            return .failed(Self.classify(stderr), log: stderr)
        }

        if action == .fetch {
            guard let before, let after = await revParse(repo, "@{u}"), before != after else { return .fetched(newCommits: 0) }
            return .fetched(newCommits: await count(repo, "\(before)..\(after)"))
        }
        if options.fastForwardOtherBranches { await fastForwardOthers(repo) }
        if let fetchOnly { return .skipped(fetchOnly) }

        // INTEGRATE
        guard let branch, let from = status.branch.oid,
              let lr = try? await git.run(["rev-list", "--left-right", "--count", "HEAD...@{u}"], in: repo.workTree, background: true) else {
            return .skipped(.noUpstream)
        }
        let counts = lr.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { return .skipped(.noUpstream) }
        let (ahead, behind) = (counts[0], counts[1])
        if behind == 0 { return .upToDate(ahead: ahead) }
        let dirty = status.hasTrackedChanges
        if dirty && options.localChanges == .skip { return .skipped(.dirty) }
        let strategy = t.member.strategy ?? options.strategy
        if ahead > 0 && strategy == .ffOnly { return .skipped(.diverged(ahead: ahead, behind: behind)) }

        onStep(t.id, .integrating)
        let autostash = dirty ? ["--autostash"] : []
        let args = ahead == 0 ? ["merge", "--ff-only"] + autostash + ["@{u}"]
            : strategy == .rebase ? ["rebase"] + autostash + ["@{u}"]
            : ["merge", "--no-edit"] + autostash + ["@{u}"]
        let title = self.title
        // Unstructured task: cancelling the run never interrupts an integrate step.
        return await Task {
            do {
                let r = try await repo.journaled(title) { try await repo.write(args, env: ["GIT_EDITOR": "true"]) }
                let to = await revParse(repo, "HEAD") ?? from
                if r.errorOutput.contains("autostash resulted in conflicts") { return .failed(.autostashConflict, log: r.errorOutput) }
                return .updated(branch: branch, from: from, to: to, commits: await count(repo, "\(from)..\(to)"))
            } catch {
                let stderr = (error as? GitError)?.stderr ?? "\(error)"
                switch repo.operationInProgress {
                case .rebase: _ = try? await git.run(["rebase", "--abort"], in: repo.workTree)
                case .merge: _ = try? await git.run(["merge", "--abort"], in: repo.workTree)
                default: return .failed(Self.classify(stderr), log: stderr)
                }
                return .failed(.conflicts, log: stderr)
            }
        }.value
    }

    /// Fetch with a stall watchdog: no output for `stallTimeout` kills git, except while an auth prompt is pending.
    func fetch(_ repo: Repository, remote: String?, id: UUID, _ onStep: @escaping @Sendable (UUID, SyncStep) -> Void) async throws {
        let last = LastOutput()
        let prune = await repo.config("fetch.prune") != "false"
        let path = repo.workTree.path
        let timeout = options.stallTimeout, authPending = authPending
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await repo.fetch(remote: remote, prune: prune) { text in
                    last.touch()
                    if let p = GitProgress.parse(text) { onStep(id, .fetching(p)) }
                }
            }
            group.addTask {
                var waiting = false
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    if authPending?(path) == true {
                        if !waiting { onStep(id, .waitingForAuth) }
                        waiting = true
                        last.touch()
                    } else {
                        if waiting { onStep(id, .fetching("")) }
                        waiting = false
                        if last.age > timeout { throw Stalled() }
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func fastForwardOthers(_ repo: Repository) async {
        guard let refs = try? await repo.refs() else { return }
        for r in refs where r.kind == .localBranch && !r.isHead && r.worktreePath == nil && r.ahead == 0 && r.behind > 0 {
            guard let up = r.upstream, let target = refs.first(where: { $0.name == up })?.target else { continue }
            // Compare-and-swap: only moves if the branch is still at the commit we saw.
            _ = try? await repo.write(["update-ref", "-m", "spoon: group sync fast-forward", r.name, target, r.target])
        }
    }

    func revParse(_ repo: Repository, _ rev: String) async -> String? {
        let r = try? await git.run(["rev-parse", "--verify", "-q", rev], in: repo.workTree, background: true, check: false)
        guard let r, r.status == 0 else { return nil }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func count(_ repo: Repository, _ range: String) async -> Int {
        let r = try? await git.run(["rev-list", "--count", range], in: repo.workTree, background: true, check: false)
        return Int(r?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    static func classify(_ stderr: String) -> SyncError {
        switch GitFailure.classify(stderr).kind {
        case .network: .network
        case .auth: .auth
        case .conflicts: .conflicts
        default: .other(stderr.split(separator: "\n").last.map(String.init) ?? "git failed")
        }
    }

    /// "Undo this sync": moves each updated repo back, but only where HEAD is still the post-sync commit
    /// on the same branch and tracked files are clean. Returns the repos left alone.
    public static func undo(_ entries: [(path: URL, result: RepoSyncResult)], git: GitRunner) async -> [URL] {
        var leftAlone: [URL] = []
        for (path, result) in entries {
            guard case .updated(let branch, let from, let to, _) = result else { continue }
            guard let repo = try? await Repository.open(path, git: git), let s = try? await repo.status(background: false),
                  s.branch.oid == to, s.branch.head == branch, !s.hasTrackedChanges else { leftAlone.append(path); continue }
            do {
                try await repo.journaled("Undo group sync") { try await repo.write(["reset", "--keep", "-q", from]) }
            } catch {
                leftAlone.append(path)
            }
        }
        return leftAlone
    }
}

final class LastOutput: Sendable {
    private let date = Mutex(Date())
    func touch() { date.withLock { $0 = Date() } }
    var age: TimeInterval { date.withLock { Date().timeIntervalSince($0) } }
}
