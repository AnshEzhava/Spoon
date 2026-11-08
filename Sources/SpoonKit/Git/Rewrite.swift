import Foundation

// Merge, rebase (plain and interactive), cherry-pick, revert, reset, and conflict state (§5.11, §5.12, §6.12, §6.13).

/// How a sequencer operation ended: done, or stopped for conflicts or an edit stop (the repo is mid-operation).
public enum OperationResult: Sendable, Equatable { case completed, stopped }

public enum MergeType: String, Sendable, CaseIterable, Codable {
    case `default`, noFF = "no-ff", ffOnly = "ff-only", squash, noCommit = "no-commit"
    public var title: String {
        switch self {
        case .default: "Default (fast-forward if possible)"
        case .noFF: "Always create a merge commit"
        case .ffOnly: "Fast-forward only"
        case .squash: "Squash into one change"
        case .noCommit: "Merge without committing"
        }
    }
    var flags: [String] {
        switch self {
        case .default: []
        case .noFF: ["--no-ff"]
        case .ffOnly: ["--ff-only"]
        case .squash: ["--squash"]
        case .noCommit: ["--no-commit", "--no-ff"]
        }
    }
}

public enum ResetMode: String, Sendable, CaseIterable {
    case soft, mixed, keep, hard
    public var title: String {
        switch self {
        case .soft: "Soft — keep all changes staged"
        case .mixed: "Mixed — keep changes, unstaged"
        case .keep: "Keep — keep local changes, fail if they'd be overwritten"
        case .hard: "Hard — discard all changes (undoable)"
        }
    }
}

public enum RebaseAction: String, Sendable, CaseIterable, Codable {
    case pick, reword, edit, squash, fixup, drop
    public var key: Character { self == .fixup ? "f" : rawValue.first! }
}

public struct RebaseItem: Sendable, Hashable, Identifiable {
    public var commit: Commit
    public var action: RebaseAction = .pick
    /// New message for `reword`.
    public var message: String?
    public var id: String { commit.sha }
    public init(commit: Commit, action: RebaseAction = .pick, message: String? = nil) {
        self.commit = commit; self.action = action; self.message = message
    }
}

public struct RebaseOptions: Sendable {
    public var backup = true
    public var updateRefs = false
    public var autostash = false
    public init(backup: Bool = true, updateRefs: Bool = false, autostash: Bool = false) {
        self.backup = backup; self.updateRefs = updateRefs; self.autostash = autostash
    }
}

public struct RewriteError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

extension Repository {
    /// Runs a sequencer command; conflicts or an edit stop return `.stopped` instead of throwing.
    func sequence(_ title: String, _ args: [String], env: [String: String] = [:], input: Data? = nil,
                  output: Output? = nil) async throws -> OperationResult {
        try await journaled(title) {
            do {
                try await self.write(args, input: input, env: ["GIT_EDITOR": "true"].merging(env) { $1 }, output: output)
            } catch let error as GitError {
                if self.operationInProgress != nil { return .stopped }
                // `merge --squash` leaves conflicts without MERGE_HEAD.
                if let s = try? await self.status(background: false), !s.conflicts.isEmpty { return .stopped }
                throw error
            }
            return self.operationInProgress != nil ? .stopped : .completed
        }
    }

    // MARK: Merge (MRG-01)

    public func merge(_ ref: String, type: MergeType = .default, message: String? = nil, output: Output? = nil) async throws -> OperationResult {
        var args = ["merge", "--progress"] + type.flags
        if let message, !message.isEmpty, type != .ffOnly { args += ["-m", message] } else { args.append("--no-edit") }
        return try await sequence("Merge \(ref)", args + [ref], output: output)
    }

    // MARK: Rebase (RB-01, RB-04, RB-08)

    /// `spoon/backup/<branch>-<time>` before a history rewrite.
    func backupBranch() async throws {
        guard let branch = headBranch else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        try await write(["branch", "spoon/backup/\(branch)-\(f.string(from: Date()))", "HEAD"])
    }

    func rebaseFlags(_ o: RebaseOptions) -> [String] {
        (o.updateRefs ? ["--update-refs"] : []) + (o.autostash ? ["--autostash"] : ["--no-autostash"])
    }

    public func rebase(onto: String, options: RebaseOptions = .init(), output: Output? = nil) async throws -> OperationResult {
        if options.backup { try await backupBranch() }
        return try await sequence("Rebase onto \(onto)", ["rebase"] + rebaseFlags(options) + [onto], output: output)
    }

    /// Commits from `base` (exclusive; nil = root) to HEAD, oldest first. Merges can't be rewritten here.
    public func rebaseCandidates(base: String?) async throws -> [Commit] {
        let range = base.map { ["\($0)..HEAD"] } ?? ["HEAD"]
        let r = try await git.run(LogParser.arguments(order: .topo, refs: range, extra: ["--reverse"]), in: workTree, background: true)
        let commits = LogParser.parse(r.stdout)
        if commits.contains(where: { $0.parents.count > 1 }) { throw RewriteError("The range contains merge commits, which interactive rebase can't keep here.") }
        return commits
    }

    /// git todo text for `items`. Rewords become `pick` + an `exec` that amends the message from a file in `dir`.
    // ponytail: rewords skip commit hooks (--no-verify); run them when someone relies on commit-msg hooks during rebase.
    public static func todo(_ items: [RebaseItem], messageDir dir: URL) throws -> String {
        var lines: [String] = []
        for (i, item) in items.enumerated() {
            switch item.action {
            case .reword:
                let file = dir.appendingPathComponent("reword-\(i).txt")
                try (item.message ?? item.commit.subject).write(to: file, atomically: true, encoding: .utf8)
                lines.append("pick \(item.commit.sha)")
                lines.append("exec git commit --amend --only --allow-empty --no-verify --cleanup=strip -q -F \(ActivityRecord.shellQuote(file.path))")
            default:
                lines.append("\(item.action.rawValue) \(item.commit.sha)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Interactive rebase with a todo list Spoon writes (§5.12 "Execution").
    public func interactiveRebase(base: String?, items: [RebaseItem], options: RebaseOptions = .init(),
                                  title: String = "Interactive rebase", output: Output? = nil) async throws -> OperationResult {
        guard items.contains(where: { $0.action != .drop }) || base != nil else { throw RewriteError("Can't drop every commit") }
        if let first = items.first(where: { $0.action != .drop }), first.action == .squash || first.action == .fixup {
            throw RewriteError("The first commit can't be squashed: there's nothing before it to squash into.")
        }
        let dir = gitDir.appendingPathComponent("spoon/rebase")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let todoFile = dir.appendingPathComponent("todo")
        try Self.todo(items, messageDir: dir).write(to: todoFile, atomically: true, encoding: .utf8)
        if options.backup { try await backupBranch() }
        let args = ["rebase", "-i"] + rebaseFlags(options) + (base.map { [$0] } ?? ["--root"])
        return try await sequence(title, args, env: ["GIT_SEQUENCE_EDITOR": "cp \(ActivityRecord.shellQuote(todoFile.path))"], output: output)
    }

    // MARK: Quick actions (RB-03, RB-05)

    public enum QuickAction: Sendable, Equatable { case reword(String), edit, squashIntoParent, fixupIntoParent, drop, moveUp, moveDown }

    /// One-step history edits on `sha` without the dialog. "Up" is towards newer commits.
    public func quickRewrite(_ sha: String, _ action: QuickAction, options: RebaseOptions = .init()) async throws -> OperationResult {
        let parents = try await git.run(["rev-list", "--parents", "-n", "1", sha], in: workTree).output
            .split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
        let needsGrandparent = [.squashIntoParent, .fixupIntoParent, .moveDown].contains(action)
        let base: String?
        if needsGrandparent {
            guard let p = parents.first else { throw RewriteError("This is the first commit; there's no parent.") }
            base = try await git.run(["rev-list", "--parents", "-n", "1", p], in: workTree).output
                .split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init)
        } else {
            base = parents.first
        }
        var items = try await rebaseCandidates(base: base).map { RebaseItem(commit: $0) }
        guard let i = items.firstIndex(where: { $0.commit.sha.hasPrefix(sha) || sha.hasPrefix($0.commit.sha) }) else {
            throw RewriteError("That commit isn't on the current branch.")
        }
        let title: String
        switch action {
        case .reword(let message):
            items[i].action = .reword
            items[i].message = message
            title = "Reword \(items[i].commit.shortSHA)"
        case .edit:
            items[i].action = .edit
            title = "Edit \(items[i].commit.shortSHA)"
        case .squashIntoParent, .fixupIntoParent:
            items[i].action = action == .squashIntoParent ? .squash : .fixup
            title = "\(action == .squashIntoParent ? "Squash" : "Fixup") \(items[i].commit.shortSHA) into parent"
        case .drop:
            items[i].action = .drop
            title = "Drop \(items[i].commit.shortSHA)"
        case .moveUp:
            guard i + 1 < items.count else { throw RewriteError("Already the newest commit.") }
            items.swapAt(i, i + 1)
            title = "Move \(items[i + 1].commit.shortSHA) up"
        case .moveDown:
            items.swapAt(i, i - 1)
            title = "Move \(items[i - 1].commit.shortSHA) down"
        }
        return try await interactiveRebase(base: base, items: items, options: options, title: title)
    }

    /// Folds the staged changes into an older commit (RB-05).
    public func amendStaged(into sha: String, options: RebaseOptions = .init()) async throws -> OperationResult {
        try await journaled("Amend staged into \(sha.prefix(7))") {
            try await self.write(["commit", "--no-verify", "-q", "--fixup=\(sha)"])
        }
        if options.backup { try await backupBranch() }
        let parent = try? await git.run(["rev-parse", "--verify", "-q", "\(sha)^"], in: workTree).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await sequence("Amend staged into \(sha.prefix(7))",
                                  ["rebase", "-i", "--autosquash", "--autostash"] + (parent.map { [$0] } ?? ["--root"]),
                                  env: ["GIT_SEQUENCE_EDITOR": "true"])
    }

    // MARK: Cherry-pick, revert, reset (CP-01, CP-02, RST-01)

    public func cherryPick(_ shas: [String], recordOrigin: Bool = false, noCommit: Bool = false, mainline: Int? = nil) async throws -> OperationResult {
        var args = ["cherry-pick"]
        if recordOrigin { args.append("-x") }
        if noCommit { args.append("--no-commit") }
        if let mainline { args += ["-m", "\(mainline)"] }
        return try await sequence("Cherry-pick \(shas.count == 1 ? String(shas[0].prefix(7)) : "\(shas.count) commits")", args + shas)
    }

    public func revert(_ shas: [String], noCommit: Bool = false, mainline: Int? = nil) async throws -> OperationResult {
        var args = ["revert", "--no-edit"]
        if noCommit { args.append("--no-commit") }
        if let mainline { args += ["-m", "\(mainline)"] }
        return try await sequence("Revert \(shas.count == 1 ? String(shas[0].prefix(7)) : "\(shas.count) commits")", args + shas)
    }

    public func reset(to sha: String, mode: ResetMode) async throws {
        // Hard reset snapshots tracked local changes so ⌘Z brings back both the commits and the edits.
        let dirty = mode == .hard ? try await status(background: false).entries.filter { $0.kind != .ignored && $0.kind != .untracked }.map(\.path) : []
        try await journaled("Reset to \(sha.prefix(7)) (\(mode.rawValue))", discarding: dirty) {
            try await self.write(["reset", "--\(mode.rawValue)", "-q", sha])
        }
    }

    // MARK: In-progress operations (MRG-03)

    public func continueOperation(output: Output? = nil) async throws -> OperationResult {
        guard let op = operationInProgress else { return .completed }
        if let s = try? await status(background: false), !s.conflicts.isEmpty {
            throw RewriteError("Resolve all conflicts before continuing (\(s.conflicts.count) left).")
        }
        let args: [String] = switch op {
        case .merge: ["commit", "--no-edit", "--no-verify"]
        case .rebase: ["rebase", "--continue"]
        case .cherryPick: ["cherry-pick", "--continue"]
        case .revert: ["revert", "--continue"]
        case .bisect: ["bisect", "reset"]
        }
        return try await sequence("Continue \(op.title.lowercased())", args, output: output)
    }

    public func skipStep() async throws -> OperationResult {
        guard let op = operationInProgress, [.rebase, .cherryPick, .revert].contains(op) else { return .completed }
        return try await sequence("Skip", [op.rawValue, "--skip"])
    }

    public func abortOperation() async throws {
        let args: [String]
        switch operationInProgress {
        case .merge?: args = ["merge", "--abort"]
        case .rebase?: args = ["rebase", "--abort"]
        case .cherryPick?: args = ["cherry-pick", "--abort"]
        case .revert?: args = ["revert", "--abort"]
        case .bisect?: args = ["bisect", "reset"]
        case nil: args = ["reset", "--merge"]
        }
        try await journaled("Abort") { try await self.write(args) }
    }

    /// Rebase step and total, from the sequencer's state files.
    public nonisolated var rebaseProgress: (step: Int, total: Int)? {
        for (dir, n, t) in [("rebase-merge", "msgnum", "end"), ("rebase-apply", "next", "last")] {
            let d = gitDir.appendingPathComponent(dir)
            func read(_ f: String) -> Int? {
                (try? String(contentsOf: d.appendingPathComponent(f), encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            if let step = read(n), let total = read(t) { return (step, total) }
        }
        return nil
    }

    /// Real names for "Yours" and "Theirs" (§5.11). During a rebase, "ours" is the branch being rebased onto.
    public func conflictSides() async -> (ours: String, theirs: String) {
        func name(_ sha: String?) async -> String {
            guard let sha = sha?.trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else { return "?" }
            let r = try? await git.run(["name-rev", "--name-only", "--no-undefined", "--refs=refs/heads/*", "--refs=refs/remotes/*", sha],
                                       in: workTree, background: true, check: false)
            if let r, r.status == 0, !r.output.contains("~"), !r.output.contains("^") { return r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            let s = try? await git.run(["log", "-1", "--format=%h %s", sha], in: workTree, background: true, check: false)
            return s?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? String(sha.prefix(7))
        }
        func file(_ p: String) -> String? { try? String(contentsOf: gitDir.appendingPathComponent(p), encoding: .utf8) }
        let head = headBranch ?? "HEAD"
        switch operationInProgress {
        case .rebase?:
            let dir = FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path) ? "rebase-merge" : "rebase-apply"
            let branch = file("\(dir)/head-name").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "refs/heads/", with: "") }
            return (await name(file("\(dir)/onto")), branch ?? "commit being rebased")
        case .cherryPick?: return (head, await name(file("CHERRY_PICK_HEAD")))
        case .revert?: return (head, "revert of " + (await name(file("REVERT_HEAD"))))
        default:
            if let msg = file("MERGE_MSG"), let m = msg.firstMatch(of: /Merge (?:remote-tracking )?branch '([^']+)'/) { return (head, String(m.1)) }
            return (head, await name(file("MERGE_HEAD")))
        }
    }

    // MARK: Conflict files (CONF-01, CONF-02, CONF-07)

    /// Three-way view of a conflicted file, from the index stages (never the worktree, which may hold edits).
    public func conflictSegments(_ path: String) async throws -> [ConflictSegment] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spoon-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var files: [String] = []
        for (stage, label) in [(2, "ours"), (1, "base"), (3, "theirs")] {
            let r = try await git.run(["show", ":\(stage):\(path)"], in: workTree, background: true, check: false)
            if r.stdout.contains(0) { throw RewriteError("Binary file: choose a side instead.") }
            let f = dir.appendingPathComponent(label)
            try (r.status == 0 ? r.stdout : Data()).write(to: f)
            files.append(f.path)
        }
        let r = try await git.run(["merge-file", "-p", "--diff3", "-L", "Yours", "-L", "Base", "-L", "Theirs"] + files,
                                  in: workTree, background: true, check: false)
        guard r.status >= 0, r.status < 128 else { throw GitError(args: ["merge-file"], status: r.status, stderr: r.errorOutput) }
        return ConflictSegment.parse(r.output)
    }

    /// Saves a resolution and stages it.
    public func resolveConflict(_ path: String, content: String) async throws {
        try await mutate { [workTree] in
            try content.write(to: workTree.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try await stage([path])
    }

    /// Delete/modify conflicts: keep the file or delete it.
    public func resolveDeleted(_ path: String, keep: Bool) async throws {
        try await write(keep ? ["add", "--", path] : ["rm", "-q", "--", path])
    }

    /// Puts the conflict markers back after a resolution (CONF-07).
    public func revertToConflicted(_ path: String) async throws {
        try await write(["checkout", "-m", "--", path])
    }

    // MARK: Worktrees & submodules (WT-01, SUB-01)

    public func worktrees() async -> [Worktree] {
        guard let r = try? await git.run(["worktree", "list", "--porcelain"], in: workTree, background: true) else { return [] }
        return Worktree.parse(r.output)
    }

    public func submodules() async -> [Submodule] {
        guard FileManager.default.fileExists(atPath: workTree.appendingPathComponent(".gitmodules").path),
              let r = try? await git.run(["submodule", "status"], in: workTree, background: true, check: false) else { return [] }
        return Submodule.parse(r.output)
    }
}

/// A region of a merged file: agreed text, or a conflict between the two sides. Lines keep their `\n`.
public enum ConflictSegment: Sendable, Hashable {
    case common([String])
    case conflict(ours: [String], base: [String], theirs: [String])

    public var isConflict: Bool { if case .conflict = self { true } else { false } }

    /// Parses `git merge-file --diff3` output.
    public static func parse(_ text: String) -> [ConflictSegment] {
        var lines = text.components(separatedBy: "\n").map { $0 + "\n" }
        if let last = lines.last {
            lines.removeLast()
            if last != "\n" { lines.append(String(last.dropLast())) }
        }
        var out: [ConflictSegment] = []
        var common: [String] = [], ours: [String] = [], base: [String] = [], theirs: [String] = []
        enum State { case common, ours, base, theirs }
        var state = State.common
        func marker(_ l: String, _ m: String) -> Bool { l.hasPrefix(m) && (l.count == 7 || l.dropFirst(7).first == " " || l.dropFirst(7).first == "\n") }
        for l in lines {
            switch state {
            case .common where marker(l, "<<<<<<<"):
                if !common.isEmpty { out.append(.common(common)); common = [] }
                state = .ours
            case .ours where marker(l, "|||||||"): state = .base
            case .ours where marker(l, "======="), .base where marker(l, "======="): state = .theirs
            case .theirs where marker(l, ">>>>>>>"):
                out.append(.conflict(ours: ours, base: base, theirs: theirs))
                ours = []; base = []; theirs = []
                state = .common
            case .common: common.append(l)
            case .ours: ours.append(l)
            case .base: base.append(l)
            case .theirs: theirs.append(l)
            }
        }
        if !common.isEmpty { out.append(.common(common)) }
        return out
    }
}

public struct Worktree: Sendable, Hashable, Identifiable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var locked = false
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    static func parse(_ text: String) -> [Worktree] {
        text.components(separatedBy: "\n\n").compactMap { block in
            var w: Worktree?
            for line in block.split(separator: "\n") {
                let (k, v) = line.firstIndex(of: " ").map { (line[..<$0], String(line[line.index(after: $0)...])) } ?? (line[...], "")
                switch k {
                case "worktree": w = Worktree(path: v)
                case "HEAD": w?.head = v
                case "branch": w?.branch = v.replacingOccurrences(of: "refs/heads/", with: "")
                case "locked": w?.locked = true
                case "bare": return nil
                default: break
                }
            }
            return w
        }
    }
}

public struct Submodule: Sendable, Hashable, Identifiable {
    public enum State: Character, Sendable { case clean = " ", uninitialized = "-", changed = "+", conflict = "U" }
    public var path: String
    public var sha: String
    public var state: State
    public var id: String { path }

    static func parse(_ text: String) -> [Submodule] {
        text.split(separator: "\n").compactMap { line in
            guard let first = line.first, let state = State(rawValue: first) else { return nil }
            let parts = line.dropFirst().split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return Submodule(path: String(parts[1]), sha: String(parts[0]), state: state)
        }
    }
}
