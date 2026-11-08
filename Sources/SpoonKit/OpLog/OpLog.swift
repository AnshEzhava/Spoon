import Foundation

/// One mutating operation, journaled to `<git-dir>/spoon/oplog.jsonl` (§4.9).
public struct OpLogEntry: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Ref moves; undo restores refs. `keepIndex` ops (commit, amend) undo as a soft reset so changes stay staged.
        case refs
        /// Working-copy change backed by a snapshot commit (discard, hard reset, stash drop).
        case workingCopy
        /// Push, remote delete: never undoable (UNDO-04).
        case remote
        case undo, redo
    }

    public var id = UUID()
    public var ts = Date()
    public var kind: Kind
    public var title: String
    public var refsBefore: [String: String] = [:]
    public var refsAfter: [String: String] = [:]
    /// `refs/heads/x` when on a branch, otherwise the detached SHA.
    public var headBefore = ""
    public var headAfter = ""
    public var keepIndex = false
    /// Snapshot commit under `refs/spoon/snapshots/` holding files as they were before the op.
    public var snapshot: String?
    public var paths: [String] = []
    /// Paths that didn't exist before the op (undo deletes them again).
    public var absentPaths: [String] = []
    /// Dropped stash commit and message (undo re-stores it).
    public var stash: String?
    public var stashMessage: String?
    public var target: UUID?

    public var undoable: Bool { kind == .refs || kind == .workingCopy }

    public init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}

public enum UndoError: Error, CustomStringConvertible, Sendable {
    case nothing
    case stateChanged(String)
    public var description: String {
        switch self {
        case .nothing: "Nothing to undo"
        case .stateChanged(let s): "The repository changed since this operation (\(s)). Use Operation History to pick a state to restore."
        }
    }
}

extension Repository {
    nonisolated var opLogURL: URL { gitDir.appendingPathComponent("spoon/oplog.jsonl") }

    public func opLog() -> [OpLogEntry] {
        guard let data = try? Data(contentsOf: opLogURL) else { return [] }
        let decoder = JSONDecoder.spoon
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(OpLogEntry.self, from: Data($0)) }
    }

    func appendOpLog(_ entry: OpLogEntry) {
        let fm = FileManager.default
        try? fm.createDirectory(at: opLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard var line = try? JSONEncoder().encodeISO(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: opLogURL) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: opLogURL)
        }
    }

    /// Local branches and tags, plus HEAD.
    func captureRefs() async throws -> (refs: [String: String], head: String) {
        let r = try await git.run(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"], in: workTree, background: true)
        var refs: [String: String] = [:]
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { refs[String(parts[0])] = String(parts[1]) }
        }
        let sym = try await git.run(["symbolic-ref", "-q", "HEAD"], in: workTree, background: true, check: false)
        if sym.status == 0 { return (refs, sym.output.trimmingCharacters(in: .newlines)) }
        let sha = try await git.run(["rev-parse", "-q", "--verify", "HEAD"], in: workTree, background: true, check: false)
        return (refs, sha.output.trimmingCharacters(in: .newlines))
    }

    /// Runs a ref-changing operation and journals before/after state (UNDO-01).
    @discardableResult
    /// `discarding` snapshots those local changes first, so undoing the operation also brings them back (hard reset).
    public func journaled<T: Sendable>(_ title: String, keepIndex: Bool = false, kind: OpLogEntry.Kind = .refs, discarding: [String] = [],
                                       _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let before = try await captureRefs()
        let snap = discarding.isEmpty ? nil : try await snapshotFiles(discarding)
        let value: T
        do {
            value = try await body()
        } catch {
            await recordIfChanged(title, keepIndex: keepIndex, kind: kind, before: before, snap: snap, paths: discarding)
            throw error
        }
        await recordIfChanged(title, keepIndex: keepIndex, kind: kind, before: before, snap: snap, paths: discarding)
        return value
    }

    private func recordIfChanged(_ title: String, keepIndex: Bool, kind: OpLogEntry.Kind, before: (refs: [String: String], head: String),
                                 snap: (commit: String, absent: [String])? = nil, paths: [String] = []) async {
        guard let after = try? await captureRefs(), after.refs != before.refs || after.head != before.head || kind == .remote else { return }
        var e = OpLogEntry(kind: kind, title: title)
        if let snap {
            e.snapshot = snap.commit
            e.paths = paths.filter { !snap.absent.contains($0) }
        }
        e.refsBefore = before.refs
        e.refsAfter = after.refs
        e.headBefore = before.head
        e.headAfter = after.head
        e.keepIndex = keepIndex
        appendOpLog(e)
    }

    /// Commit holding the current worktree content of `paths`, kept alive under `refs/spoon/snapshots/` (§4.4.1).
    /// Returns the snapshot and the paths that don't exist on disk.
    func snapshotFiles(_ paths: [String]) async throws -> (commit: String, absent: [String]) {
        let fm = FileManager.default
        let indexFile = gitDir.appendingPathComponent("spoon/snapshot-index-\(UUID().uuidString)")
        try fm.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: indexFile) }
        let env = ["GIT_INDEX_FILE": indexFile.path]
        var absent: [String] = []
        for path in paths {
            let url = workTree.appendingPathComponent(path)
            guard fm.fileExists(atPath: url.path) else { absent.append(path); continue }
            let blob = try await git.run(["hash-object", "-w", "--", path], in: workTree).output.trimmingCharacters(in: .newlines)
            let exec = fm.isExecutableFile(atPath: url.path)
            try await git.run(["update-index", "--add", "--cacheinfo", "\(exec ? "100755" : "100644"),\(blob),\(path)"], in: workTree, env: env)
        }
        let tree = try await git.run(["write-tree"], in: workTree, env: env).output.trimmingCharacters(in: .newlines)
        let commit = try await git.run(["commit-tree", tree, "-m", "spoon snapshot"], in: workTree).output.trimmingCharacters(in: .newlines)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        try await git.run(["update-ref", "refs/spoon/snapshots/\(stamp)", commit], in: workTree)
        return (commit, absent)
    }

    /// Next operation `undo()` would revert.
    public func undoCandidate() -> OpLogEntry? { stacks().undo.last }
    public func redoCandidate() -> OpLogEntry? { stacks().redo.last }

    /// Replays undo/redo markers to find what is currently undoable and redoable.
    func stacks() -> (undo: [OpLogEntry], redo: [OpLogEntry]) {
        var undo: [OpLogEntry] = [], redo: [OpLogEntry] = []
        var byID: [UUID: OpLogEntry] = [:]
        for e in opLog() {
            switch e.kind {
            case .undo:
                if let t = e.target, let i = undo.lastIndex(where: { $0.id == t }) { redo.append(undo.remove(at: i)) }
            case .redo:
                if let t = e.target, let i = redo.lastIndex(where: { $0.id == t }) { undo.append(redo.remove(at: i)) }
            case .remote:
                byID[e.id] = e
            case .refs, .workingCopy:
                undo.append(e)
                redo.removeAll()
                byID[e.id] = e
            }
        }
        return (undo, redo)
    }

    public func undo() async throws -> OpLogEntry {
        guard let e = undoCandidate() else { throw UndoError.nothing }
        try await mutate { try await self.revert(e, toBefore: true) }
        var marker = OpLogEntry(kind: .undo, title: "Undo \(e.title)")
        marker.target = e.id
        appendOpLog(marker)
        return e
    }

    public func redo() async throws -> OpLogEntry {
        guard let e = redoCandidate() else { throw UndoError.nothing }
        try await mutate { try await self.revert(e, toBefore: false) }
        var marker = OpLogEntry(kind: .redo, title: "Redo \(e.title)")
        marker.target = e.id
        appendOpLog(marker)
        return e
    }

    /// Moves refs/HEAD from one recorded state to the other, refusing if the repo has moved on (§4.9).
    private func revert(_ e: OpLogEntry, toBefore: Bool) async throws {
        if e.kind == .workingCopy {
            guard toBefore else { throw UndoError.stateChanged("redo of a working-copy change isn't supported") }
            if let snap = e.snapshot, !e.paths.isEmpty {
                try await git.run(["restore", "--source=\(snap)", "--worktree", "--"] + e.paths, in: workTree)
            }
            for p in e.absentPaths { try? FileManager.default.removeItem(at: workTree.appendingPathComponent(p)) }
            if let stash = e.stash {
                try await git.run(["stash", "store", "-m", e.stashMessage ?? "Restored stash", stash], in: workTree)
            }
            return
        }
        let (from, to) = toBefore ? (e.refsAfter, e.refsBefore) : (e.refsBefore, e.refsAfter)
        let (headFrom, headTo) = toBefore ? (e.headAfter, e.headBefore) : (e.headBefore, e.headAfter)
        let current = try await captureRefs()
        let keys = Set(from.keys).union(to.keys).filter { from[$0] != to[$0] }
        for k in keys where current.refs[k] != from[k] {
            throw UndoError.stateChanged("\(k.replacingOccurrences(of: "refs/heads/", with: "")) moved")
        }
        guard current.head == headFrom else { throw UndoError.stateChanged("HEAD moved") }

        let currentBranch = headFrom.hasPrefix("refs/") ? headFrom : nil
        var tx = ""
        for k in keys.sorted() where k != currentBranch || headFrom != headTo {
            switch (from[k], to[k]) {
            case let (old?, new?): tx += "update \(k) \(new) \(old)\n"
            case let (old?, nil): tx += "delete \(k) \(old)\n"
            case let (nil, new?): tx += "create \(k) \(new)\n"
            default: break
            }
        }
        if headFrom != headTo {
            // Branch switch (checkout). Refs first so the target branch exists.
            if !tx.isEmpty { try await git.run(["update-ref", "--stdin"], in: workTree, input: Data(tx.utf8)) }
            if headTo.hasPrefix("refs/heads/") {
                try await git.run(["switch", String(headTo.dropFirst("refs/heads/".count))], in: workTree)
            } else if !headTo.isEmpty {
                try await git.run(["switch", "--detach", headTo], in: workTree)
            }
            if let b = currentBranch, keys.contains(b), let target = to[b], current.refs[b] != target {
                try await git.run(["update-ref", b, target, current.refs[b] ?? ""], in: workTree)
            }
            return
        }
        if !tx.isEmpty { try await git.run(["update-ref", "--stdin"], in: workTree, input: Data(tx.utf8)) }
        if let b = currentBranch, keys.contains(b) {
            if let target = to[b] {
                // Soft keeps the committed changes staged; --keep moves the worktree but refuses to clobber local edits.
                try await git.run(["reset", e.keepIndex && toBefore ? "--soft" : "--keep", target], in: workTree)
            } else {
                try await git.run(["update-ref", "-d", b], in: workTree)
            }
        } else if !headFrom.hasPrefix("refs/"), headFrom != headTo {
            try await git.run(["reset", "--keep", headTo], in: workTree)
        }
        if toBefore, let snap = e.snapshot, !e.paths.isEmpty {
            try await git.run(["restore", "--source=\(snap)", "--worktree", "--"] + e.paths, in: workTree)
        }
    }

    /// Drops snapshot refs older than `days` or beyond `keep` entries.
    public func pruneSnapshots(days: Int = 14, keep: Int = 200) async {
        guard let r = try? await git.run(["for-each-ref", "--format=%(refname)", "--sort=-refname", "refs/spoon/snapshots"],
                                         in: workTree, background: true) else { return }
        let cutoff = Int((Date().timeIntervalSince1970 - Double(days) * 86400) * 1000)
        let refs = r.output.split(separator: "\n").map(String.init)
        for (i, ref) in refs.enumerated() {
            let stamp = Int(ref.split(separator: "/").last ?? "") ?? 0
            if i >= keep || stamp < cutoff { _ = try? await git.run(["update-ref", "-d", ref], in: workTree) }
        }
    }
}

extension JSONEncoder {
    func encodeISO<T: Encodable>(_ v: T) throws -> Data {
        dateEncodingStrategy = .iso8601
        return try encode(v)
    }
}
