import Foundation

public enum LocalChangesMode: String, Sendable, CaseIterable, Codable {
    case keep, stash, discard
    public var title: String {
        switch self {
        case .keep: "Keep (fail if there is a conflict)"
        case .stash: "Stash and reapply"
        case .discard: "Discard ⚠"
        }
    }
}

public enum PullStrategy: String, Sendable, CaseIterable, Codable {
    case ffOnly = "ff-only", merge, rebase
    public var flag: String {
        switch self {
        case .ffOnly: "--ff-only"
        case .merge: "--no-rebase"
        case .rebase: "--rebase"
        }
    }
    public var title: String {
        switch self {
        case .ffOnly: "Fast-forward only"
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }
}

public struct CommitOptions: Sendable {
    public var amend = false
    public var signOff = false
    public var noVerify = false
    public init(amend: Bool = false, signOff: Bool = false, noVerify: Bool = false) {
        self.amend = amend
        self.signOff = signOff
        self.noVerify = noVerify
    }
}

public struct PushSpec: Sendable, Hashable {
    public var local: String
    public var remote: String
    public var remoteBranch: String
    public init(local: String, remote: String, remoteBranch: String) {
        self.local = local
        self.remote = remote
        self.remoteBranch = remoteBranch
    }
}

public struct PushOptions: Sendable {
    public var setUpstream = false
    public var forceWithLease = false
    public var tags = false
    public var noVerify = false
    public init(setUpstream: Bool = false, forceWithLease: Bool = false, tags: Bool = false, noVerify: Bool = false) {
        self.setUpstream = setUpstream
        self.forceWithLease = forceWithLease
        self.tags = tags
        self.noVerify = noVerify
    }
}

/// Every mutation runs real git (§1 principle 2), serialized per repo, and ref changes are journaled for undo.
extension Repository {
    public typealias Output = @Sendable (String) -> Void

    static func textForwarder(_ o: @escaping Output) -> @Sendable (Data) -> Void {
        { data in o(String(decoding: data, as: UTF8.self)) }
    }

    @discardableResult
    public func write(_ args: [String], input: Data? = nil, env: [String: String] = [:], output: Output? = nil) async throws -> GitResult {
        let forward: (@Sendable (Data) -> Void)? = output.map(Self.textForwarder)
        return try await mutate { [git, workTree] in
            try await git.stream(args, in: workTree, input: input, env: env, onStderr: forward, onStdout: forward)
        }
    }

    // MARK: Staging (§5.9)

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await write(["add", "-A", "--"] + paths)
    }

    public func stageAll() async throws { try await write(["add", "-A"]) }

    public var hasHead: Bool {
        get async { (try? await git.run(["rev-parse", "-q", "--verify", "HEAD"], in: workTree, background: true, check: false))?.status == 0 }
    }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        if await hasHead {
            try await write(["reset", "-q", "HEAD", "--"] + paths)
        } else {
            try await write(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--"] + paths)
        }
    }

    public func unstageAll() async throws {
        if await hasHead { try await write(["reset", "-q"]) } else { try await write(["rm", "--cached", "-r", "-q", "."]) }
    }

    /// Discards unstaged changes; untracked files are deleted. Snapshotted first, so it's undoable (STG-07).
    public func discard(_ entries: [StatusEntry]) async throws {
        let paths = entries.map(\.path)
        guard !paths.isEmpty else { return }
        let snap = try await snapshotFiles(paths)
        let untracked = entries.filter { $0.kind == .untracked }.map(\.path)
        let tracked = entries.filter { $0.kind != .untracked }.map(\.path)
        if !tracked.isEmpty { try await write(["restore", "--worktree", "--"] + tracked) }
        for p in untracked { try FileManager.default.removeItem(at: workTree.appendingPathComponent(p)) }
        var e = OpLogEntry(kind: .workingCopy, title: "Discard \(paths.count == 1 ? paths[0] : "\(paths.count) files")")
        e.snapshot = snap.commit
        e.paths = paths.filter { !snap.absent.contains($0) }
        e.absentPaths = snap.absent
        appendOpLog(e)
    }

    /// Hunk/line stage, unstage or discard through a generated patch (§4.4.1).
    public func applyPartial(_ file: FileDiff, lines: Set<LineRef>, unstage: Bool = false, discard: Bool = false) async throws {
        guard let patch = PatchBuilder.patch(for: file, selection: lines, reverse: unstage || discard) else { return }
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if unstage || discard { args.append("-R") }
        if !discard { args.append("--cached") }
        if discard {
            let snap = try await snapshotFiles([file.path])
            try await write(args, input: Data(patch.utf8))
            var e = OpLogEntry(kind: .workingCopy, title: "Discard lines in \(file.path)")
            e.snapshot = snap.commit
            e.paths = [file.path]
            appendOpLog(e)
        } else {
            try await write(args, input: Data(patch.utf8))
        }
    }

    /// Records intent-to-add so an untracked file's lines can be staged partially (STG-05).
    public func intentToAdd(_ path: String) async throws { try await write(["add", "-N", "--", path]) }

    // MARK: Commit (§5.9)

    @discardableResult
    public func commit(message: String, options: CommitOptions = .init(), output: Output? = nil) async throws -> String {
        var args = ["commit", "-F", "-", "--cleanup=strip"]
        if options.amend { args.append("--amend") }
        if options.signOff { args.append("--signoff") }
        if options.noVerify { args.append("--no-verify") }
        let title = options.amend ? "Amend" : "Commit"
        let commitArgs = args
        try await journaled(title, keepIndex: true) {
            try await self.write(commitArgs, input: Data(message.utf8), env: ["GIT_EDITOR": "true"], output: output)
        }
        return try await git.run(["rev-parse", "HEAD"], in: workTree).output.trimmingCharacters(in: .newlines)
    }

    /// Commit with no staging step: the index is rebuilt as every change minus `excluding`, `partial` files add only
    /// their listed lines, then it commits. The working tree is never touched. `partial` diffs come from
    /// `diffAgainstHead`/`diffUntracked` with `diffOptions`; if a file has changed since, nothing is committed.
    @discardableResult
    public func commitSelected(excluding: [String], partial: [(FileDiff, Set<LineRef>)], message: String,
                               options: CommitOptions = .init(), diffOptions: DiffOptions = .init(),
                               output: Output? = nil) async throws -> String {
        for (file, _) in partial {
            var fresh = try await diffAgainstHead(paths: [file.path], options: diffOptions).first
            if fresh == nil { fresh = try await diffUntracked(file.path, options: diffOptions) }
            guard fresh?.hunks == file.hunks else {
                throw GitError(args: ["apply"], status: 1, stderr: "error: \(file.path) changed after its lines were picked. Review it and commit again.")
            }
        }
        try await stageAll()
        try await unstage(excluding + partial.map(\.0.path))
        for (file, lines) in partial { try await applyPartial(file, lines: lines) }
        return try await commit(message: message, options: options, output: output)
    }

    public func headMessage() async -> String {
        (try? await git.run(["log", "-1", "--format=%B"], in: workTree, background: true).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    // MARK: Branches (§5.13)

    public func validateBranchName(_ name: String) async -> Bool {
        guard !name.isEmpty else { return false }
        return (try? await git.run(["check-ref-format", "--branch", name], in: workTree, background: true, check: false))?.status == 0
    }

    /// Wraps an operation that needs a clean worktree with the chosen local-changes policy (§5.13).
    func withLocalChanges<T: Sendable>(_ mode: LocalChangesMode, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        switch mode {
        case .keep:
            return try await body()
        case .discard:
            let s = try await status(background: false)
            let paths = s.entries.filter { $0.kind != .ignored && $0.kind != .untracked }.map(\.path)
            if !paths.isEmpty {
                let snap = try await snapshotFiles(paths)
                try await write(["reset", "--hard", "-q"])
                var e = OpLogEntry(kind: .workingCopy, title: "Discard local changes")
                e.snapshot = snap.commit
                e.paths = paths.filter { !snap.absent.contains($0) }
                appendOpLog(e)
            }
            return try await body()
        case .stash:
            let dirty = try await status(background: false).hasTrackedChanges
            if dirty { try await write(["stash", "push", "-m", "Spoon: autostash"]) }
            let value = try await body()
            if dirty { try await write(["stash", "pop", "--index"]) }
            return value
        }
    }

    public func createBranch(_ name: String, at start: String?, checkout: Bool, track: Bool = false, localChanges: LocalChangesMode = .keep) async throws {
        try await journaled("Create branch \(name)") {
            if checkout {
                try await self.withLocalChanges(localChanges) {
                    try await self.write(["switch", "-c", name] + (track ? ["--track"] : ["--no-track"]) + (start.map { [$0] } ?? []))
                }
            } else {
                try await self.write(["branch"] + (track ? ["--track"] : ["--no-track"]) + [name] + (start.map { [$0] } ?? []))
            }
        }
    }

    /// Checks out a local branch; a remote branch checks out (or creates) its tracking branch (BR-02).
    public func checkout(_ ref: Ref, localChanges: LocalChangesMode = .keep, allRefs: [Ref] = []) async throws {
        try await journaled("Checkout \(ref.shortName)") {
            try await self.withLocalChanges(localChanges) {
                switch ref.kind {
                case .localBranch:
                    try await self.write(["switch", ref.shortName])
                case .remoteBranch:
                    let local = String(ref.shortName.split(separator: "/", maxSplits: 1).last ?? Substring(ref.shortName))
                    if allRefs.contains(where: { $0.kind == .localBranch && $0.shortName == local }) {
                        try await self.write(["switch", local])
                    } else {
                        try await self.write(["switch", "-c", local, "--track", ref.shortName])
                    }
                default:
                    try await self.write(["switch", "--detach", ref.target])
                }
            }
        }
    }

    public func checkoutDetached(_ sha: String, localChanges: LocalChangesMode = .keep) async throws {
        try await journaled("Checkout \(sha.prefix(7))") {
            try await self.withLocalChanges(localChanges) { try await self.write(["switch", "--detach", sha]) }
        }
    }

    public func renameBranch(_ old: String, to new: String) async throws {
        try await journaled("Rename \(old) to \(new)") { try await self.write(["branch", "-m", old, new]) }
    }

    public func deleteBranches(_ names: [String], force: Bool) async throws {
        try await journaled("Delete \(names.joined(separator: ", "))") {
            try await self.write(["branch", force ? "-D" : "-d"] + names)
        }
    }

    /// Commits on `branch` not reachable from its upstream or from `main` (warning before delete).
    public func unmergedCount(_ branch: String, upstream: String?, main: String?) async -> Int {
        var args = ["rev-list", "--count", "refs/heads/\(branch)"]
        for other in [upstream, main].compactMap({ $0 }) where other != "refs/heads/\(branch)" { args.append("^\(other)") }
        guard args.count > 3 else { return 0 }
        let r = try? await git.run(args, in: workTree, background: true, check: false)
        return Int(r?.output.trimmingCharacters(in: .newlines) ?? "") ?? 0
    }

    public func setUpstream(_ branch: String, to upstream: String?) async throws {
        if let upstream {
            try await write(["branch", "--set-upstream-to=\(upstream)", branch])
        } else {
            try await write(["branch", "--unset-upstream", branch])
        }
    }

    /// Fast-forwards a branch that isn't checked out (BR-07). Fails if it's not a fast-forward.
    public func fastForward(_ branch: String, to target: String) async throws {
        try await journaled("Fast-forward \(branch)") {
            let base = try await self.git.run(["merge-base", "--is-ancestor", "refs/heads/\(branch)", target], in: self.workTree, check: false)
            guard base.status == 0 else { throw GitError(args: ["merge-base"], status: 1, stderr: "\(branch) can't be fast-forwarded to \(target)") }
            let old = try await self.git.run(["rev-parse", "refs/heads/\(branch)"], in: self.workTree).output.trimmingCharacters(in: .newlines)
            try await self.write(["update-ref", "refs/heads/\(branch)", target, old])
        }
    }

    // MARK: Network (§5.13)

    public func fetch(remote: String?, prune: Bool = true, tags: Bool = false, env: [String: String] = [:], output: Output? = nil) async throws {
        var args = ["fetch", "--progress"]
        if prune { args.append("--prune") }
        if tags { args.append("--tags") }
        args.append(remote ?? "--all")
        try await write(args, env: env, output: output)
    }

    public func pull(remote: String, branch: String, strategy: PullStrategy, localChanges: LocalChangesMode = .keep, output: Output? = nil) async throws {
        var args = ["pull", "--progress", strategy.flag]
        if localChanges == .stash { args.append("--autostash") }
        args += [remote, branch]
        let pullArgs = args
        try await withLocalChanges(localChanges == .discard ? .discard : .keep) {
            try await self.journaled("Pull \(remote)/\(branch)") {
                try await self.write(pullArgs, env: ["GIT_EDITOR": "true"], output: output)
            }
        }
    }

    public func push(_ specs: [PushSpec], options: PushOptions = .init(), output: Output? = nil) async throws {
        guard let remote = specs.first?.remote else { return }
        var args = ["push", "--progress"]
        if options.setUpstream { args.append("-u") }
        if options.forceWithLease { args.append("--force-with-lease") }
        if options.noVerify { args.append("--no-verify") }
        if options.tags { args.append("--follow-tags") }
        args.append(remote)
        args += specs.map { "refs/heads/\($0.local):refs/heads/\($0.remoteBranch)" }
        try await write(args, output: output)
        var e = OpLogEntry(kind: .remote, title: "Push to \(remote)")
        e.paths = specs.map(\.local)
        appendOpLog(e)
    }

    /// Commits the remote has that would be overwritten by a force push.
    public func commitsOverwritten(remoteRef: String, by local: String) async -> [Commit] {
        let r = try? await git.run(LogParser.arguments(order: .topo, refs: [remoteRef, "^\(local)"]), in: workTree, background: true, check: false)
        return r.map { LogParser.parse($0.stdout) } ?? []
    }

    public func deleteRemoteBranch(remote: String, branch: String) async throws {
        try await write(["push", remote, "--delete", branch])
    }

    // MARK: Stash (§5.13)

    public func stash(message: String?, includeUntracked: Bool = false, keepIndex: Bool = false, stagedOnly: Bool = false, paths: [String] = []) async throws {
        var args = ["stash", "push"]
        if let message, !message.isEmpty { args += ["-m", message] }
        if includeUntracked { args.append("-u") }
        if keepIndex { args.append("--keep-index") }
        if stagedOnly { args.append("--staged") }
        if !paths.isEmpty { args += ["--"] + paths }
        try await write(args)
    }

    public func applyStash(_ stash: Stash, pop: Bool, restoreIndex: Bool = false) async throws {
        var args = ["stash", pop ? "pop" : "apply"]
        if restoreIndex { args.append("--index") }
        args.append(stash.refName)
        try await write(args)
    }

    /// Drop is undoable: the stash commit is journaled and can be re-stored (UNDO-02).
    public func dropStash(_ stash: Stash) async throws {
        try await write(["stash", "drop", stash.refName])
        var e = OpLogEntry(kind: .workingCopy, title: "Drop stash \"\(stash.message)\"")
        e.stash = stash.sha
        e.stashMessage = stash.message
        try await git.run(["update-ref", "refs/spoon/snapshots/\(Int(Date().timeIntervalSince1970 * 1000))", stash.sha], in: workTree)
        appendOpLog(e)
    }

    public func renameStash(_ stash: Stash, to message: String) async throws {
        try await write(["stash", "drop", stash.refName])
        try await write(["stash", "store", "-m", message, stash.sha])
    }

    public func branchFromStash(_ stash: Stash, name: String) async throws {
        try await journaled("Branch from stash") { try await self.write(["stash", "branch", name, stash.refName]) }
    }

    // MARK: Remotes

    public func addRemote(_ name: String, url: String, pushURL: String? = nil) async throws {
        try await write(["remote", "add", name, url])
        if let pushURL, !pushURL.isEmpty { try await write(["remote", "set-url", "--push", name, pushURL]) }
    }

    public func editRemote(_ name: String, newName: String, url: String, pushURL: String?) async throws {
        if newName != name { try await write(["remote", "rename", name, newName]) }
        try await write(["remote", "set-url", newName, url])
        if let pushURL, !pushURL.isEmpty, pushURL != url { try await write(["remote", "set-url", "--push", newName, pushURL]) }
    }

    public func removeRemote(_ name: String) async throws { try await write(["remote", "remove", name]) }

    public func testConnection(_ url: String) async -> (ok: Bool, message: String) {
        let r = try? await git.run(["ls-remote", "--heads", url], in: workTree, background: true, check: false)
        guard let r else { return (false, "Couldn't run git") }
        return r.status == 0 ? (true, "Connected") : (false, GitFailure.classify(r.errorOutput).summary)
    }

    // MARK: Tags (§5.13)

    public func createTag(_ name: String, at target: String, message: String?, sign: Bool = false) async throws {
        var args = ["tag"]
        if let message, !message.isEmpty { args += [sign ? "-s" : "-a", "-m", message] } else if sign { args += ["-s", "-m", name] }
        args += [name, target]
        let tagArgs = args
        try await journaled("Create tag \(name)") { try await self.write(tagArgs) }
    }

    public func deleteTag(_ name: String) async throws {
        try await journaled("Delete tag \(name)") { try await self.write(["tag", "-d", name]) }
    }

    public func pushTags(_ names: [String], remote: String) async throws {
        try await write(["push", remote] + names.map { "refs/tags/\($0)" })
    }

    public func deleteRemoteTag(_ name: String, remote: String) async throws {
        try await write(["push", remote, "--delete", "refs/tags/\(name)"])
    }

    /// Removes `index.lock` only when no git process is running in this repo (MISC-04).
    public func removeStaleLock() async throws -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        ps.arguments = ["-x", "git"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        ps.waitUntilExit()
        let running = !pipe.fileHandleForReading.readDataToEndOfFile().isEmpty
        guard !running else { return false }
        try FileManager.default.removeItem(at: gitDir.appendingPathComponent("index.lock"))
        return true
    }
}

/// Clone and init don't have a repository yet.
public enum RepoCreation {
    public static func clone(url: String, into path: URL, branch: String? = nil, depth: Int? = nil, partial: Bool = false,
                             recurseSubmodules: Bool = false, git: GitRunner, output: (@Sendable (String) -> Void)? = nil) async throws {
        var args = ["clone", "--progress"]
        if let branch, !branch.isEmpty { args += ["-b", branch] }
        if let depth { args += ["--depth", "\(depth)"] }
        if partial { args.append("--filter=blob:none") }
        if recurseSubmodules { args.append("--recurse-submodules") }
        args += [url, path.path]
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git.stream(args, in: path.deletingLastPathComponent(), onStderr: output.map(Repository.textForwarder))
    }

    public static func initialize(at path: URL, branch: String?, readme: Bool, gitignore: String?, initialCommit: Bool, git: GitRunner) async throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try await git.run(["init"] + (branch.map { ["-b", $0] } ?? []), in: path)
        if readme {
            try "# \(path.lastPathComponent)\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }
        if let gitignore, !gitignore.isEmpty {
            try gitignore.write(to: path.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        }
        if initialCommit {
            try await git.run(["add", "-A"], in: path)
            try await git.run(["commit", "--allow-empty", "-m", "Initial commit"], in: path)
        }
    }

    public static let gitignoreTemplates: [String: String] = [
        "macOS": ".DS_Store\n",
        "Swift": ".DS_Store\n.build/\n.swiftpm/\nDerivedData/\n*.xcodeproj/xcuserdata/\n",
        "Node": "node_modules/\ndist/\n.env\nnpm-debug.log*\n",
        "Python": "__pycache__/\n*.pyc\n.venv/\n.env\ndist/\n*.egg-info/\n",
        "Rust": "target/\n",
        "Go": "bin/\n*.test\n",
    ]
}

// MARK: Conflict prediction (§5.13)

extension Repository {
    /// Paths that would conflict merging `theirs` into `ours`, via `merge-tree --write-tree` (no working-copy change).
    /// nil when git can't tell (old git, unrelated histories).
    public func predictConflicts(ours: String, theirs: String) async -> [String]? {
        let r = try? await git.run(["merge-tree", "--write-tree", "--name-only", "--no-messages", ours, theirs],
                                   in: workTree, background: true, check: false)
        guard let r, r.status <= 1 else { return nil }
        return r.status == 0 ? [] : r.output.split(separator: "\n").dropFirst().map(String.init)
    }
}
