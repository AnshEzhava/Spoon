import Foundation

public enum RepoOperation: String, Sendable, Hashable {
    case merge, rebase, cherryPick = "cherry-pick", revert, bisect

    public var title: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .bisect: "Bisect"
        }
    }
}

/// A repository on disk. Reads may run concurrently; mutations go through `mutate` and never overlap (§4.3).
public actor Repository {
    public nonisolated let workTree: URL
    public nonisolated let gitDir: URL
    /// Shared git dir; differs from `gitDir` inside a linked worktree.
    public nonisolated let commonDir: URL
    public nonisolated let git: GitRunner

    public var name: String { workTree.lastPathComponent }

    init(workTree: URL, gitDir: URL, commonDir: URL, git: GitRunner) {
        self.workTree = workTree
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.git = git
    }

    public static func open(_ url: URL, git: GitRunner = GitRunner()) async throws -> Repository {
        let r = try await git.run(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--path-format=absolute", "--git-common-dir"], in: url)
        let lines = r.output.split(separator: "\n").map(String.init)
        guard lines.count == 3 else { throw GitError(args: ["rev-parse"], status: 128, stderr: "Not a work tree") }
        let dir = { URL(fileURLWithPath: $0, isDirectory: true) }
        return Repository(workTree: dir(lines[0]), gitDir: dir(lines[1]), commonDir: dir(lines[2]), git: git)
    }

    // MARK: Cheap state read straight from the git dir (§4.4)

    public nonisolated var operationInProgress: RepoOperation? {
        let fm = FileManager.default
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: gitDir.appendingPathComponent(p).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        if exists("BISECT_LOG") { return .bisect }
        return nil
    }

    public nonisolated var isLocked: Bool {
        FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("index.lock").path)
    }

    /// Branch name from `.git/HEAD`, or nil when detached.
    public nonisolated var headBranch: String? {
        guard let s = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8),
              s.hasPrefix("ref: refs/heads/") else { return nil }
        return String(s.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reads

    public func status(background: Bool = true, ignored: Bool = false) async throws -> RepoStatus {
        let args = RepoStatus.arguments + (ignored ? ["--ignored"] : [])
        return RepoStatus.parse(try await git.run(args, in: workTree, background: background).stdout)
    }

    public func refs() async throws -> [Ref] {
        Ref.parse(try await git.run(Ref.arguments, in: workTree, background: true).stdout)
    }

    public func stashes() async throws -> [Stash] {
        let r = try await git.run(Stash.arguments, in: workTree, background: true, check: false)
        return r.status == 0 ? Stash.parse(r.stdout) : []
    }

    public func details(_ sha: String) async throws -> CommitDetails? {
        CommitDetails.parse(try await git.run(CommitDetails.arguments(sha), in: workTree, background: true).stdout)
    }

    /// Diff of a commit against a parent (1-based); root commits diff against the empty tree.
    public func diff(commit sha: String, parent: Int = 1, options: DiffOptions = .init()) async throws -> [FileDiff] {
        let args = parent == 1
            ? ["show", "--format=", "--diff-merges=first-parent"] + options.flags + [sha]
            : ["diff"] + options.flags + ["\(sha)^\(parent)", sha]
        return DiffParser.parse(try await git.run(args, in: workTree, background: true).stdout)
    }

    public func diff(from a: String, to b: String, options: DiffOptions = .init()) async throws -> [FileDiff] {
        DiffParser.parse(try await git.run(["diff"] + options.flags + [a, b, "--"], in: workTree, background: true).stdout)
    }

    /// Working-copy diff: staged (index vs HEAD) or unstaged (worktree vs index).
    public func diffWorkingCopy(staged: Bool, paths: [String] = [], options: DiffOptions = .init()) async throws -> [FileDiff] {
        let args = ["diff"] + options.flags + (staged ? ["--cached"] : []) + ["--"] + paths
        return DiffParser.parse(try await git.run(args, in: workTree, background: true).stdout)
    }

    /// Diff of an untracked file against /dev/null.
    public func diffUntracked(_ path: String, options: DiffOptions = .init()) async throws -> FileDiff? {
        let r = try await git.run(["diff", "--no-index"] + options.flags + ["--", "/dev/null", path],
                                  in: workTree, background: true, check: false)
        guard var file = DiffParser.parse(r.stdout).first else { return nil }
        file.oldPath = path
        file.newPath = path
        return file
    }

    /// Streams history in pages (§4.4). `onPage` is called for each batch of commits as they arrive.
    public func log(order: CommitOrder = .topo, refs: [String] = ["--all"], extra: [String] = [], pageSize: Int = 2000,
                    onPage: @escaping @Sendable ([Commit]) -> Void) async throws {
        let parser = ParserBox()
        try await git.stream(LogParser.arguments(order: order, refs: refs, extra: extra), in: workTree, background: true, onStdout: { chunk in
            let commits = parser.feed(chunk, pageSize: pageSize)
            if !commits.isEmpty { onPage(commits) }
        })
        let rest = parser.finish()
        if !rest.isEmpty { onPage(rest) }
    }

    public func show(path: String, at rev: String) async throws -> Data {
        try await git.run(["show", "\(rev):\(path)"], in: workTree, background: true).stdout
    }

    public func files(at rev: String) async throws -> [String] {
        let r = try await git.run(["ls-tree", "-r", "-z", "--name-only", rev], in: workTree, background: true)
        return r.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    public func config(_ key: String) async -> String? {
        let r = try? await git.run(["config", "--get", key], in: workTree, background: true, check: false)
        guard let r, r.status == 0 else { return nil }
        return r.output.trimmingCharacters(in: .newlines)
    }

    public func remotes() async throws -> [Remote] {
        let r = try await git.run(["remote", "-v"], in: workTree, background: true)
        return Remote.parse(r.output)
    }

    // MARK: Mutations

    private var mutationTail: Task<Void, Never>?
    private var pendingMutations = 0
    public var isMutating: Bool { pendingMutations > 0 }

    /// Serializes mutating operations on this repo; overlapping git writes would fight over index.lock.
    public func mutate<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = mutationTail
        let task = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        mutationTail = Task { _ = try? await task.value }
        pendingMutations += 1
        defer { pendingMutations -= 1 }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

public struct Remote: Sendable, Hashable, Identifiable {
    public var name: String
    public var fetchURL: String
    public var pushURL: String
    public var id: String { name }

    static func parse(_ text: String) -> [Remote] {
        var out: [String: Remote] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 3 else { continue }
            if out[parts[0]] == nil { order.append(parts[0]); out[parts[0]] = Remote(name: parts[0], fetchURL: "", pushURL: "") }
            if parts[2] == "(fetch)" { out[parts[0]]!.fetchURL = parts[1] } else { out[parts[0]]!.pushURL = parts[1] }
        }
        return order.compactMap { out[$0] }
    }

    /// Browser URL for GitHub/GitLab/etc. remotes (`git@host:o/r.git` → `https://host/o/r`).
    public var webURL: URL? {
        var s = fetchURL
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let at = s.firstIndex(of: "@"), !s.contains("://") {
            s = "https://" + s[s.index(after: at)...].replacingOccurrences(of: ":", with: "/")
        } else if s.hasPrefix("ssh://") {
            s = "https://" + (s.dropFirst(6).split(separator: "@").last.map(String.init) ?? "")
        }
        return s.hasPrefix("http") ? URL(string: s) : nil
    }
}

private final class ParserBox: @unchecked Sendable {
    private var parser = LogParser()
    private var buffer: [Commit] = []
    private let lock = NSLock()

    func feed(_ chunk: Data, pageSize: Int) -> [Commit] {
        lock.withLock {
            buffer += parser.feed(chunk)
            // First page is small so the first screen renders immediately.
            guard buffer.count >= pageSize || (buffer.count >= 100 && pagesSent == 0) else { return [] }
            pagesSent += 1
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer
        }
    }

    private var pagesSent = 0

    func finish() -> [Commit] {
        lock.withLock {
            defer { buffer.removeAll() }
            return buffer + parser.finish()
        }
    }
}
