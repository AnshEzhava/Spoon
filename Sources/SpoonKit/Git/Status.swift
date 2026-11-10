import Foundation

/// One entry of `git status --porcelain=v2 -z`.
public struct StatusEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case ordinary, renamed, unmerged, untracked, ignored }
    public var kind: Kind
    /// X (index) and Y (worktree) status letters; `.` means unchanged.
    public var index: Character
    public var worktree: Character
    public var path: String
    public var originalPath: String?
    public var isSubmodule: Bool

    public var isStaged: Bool { kind == .ordinary || kind == .renamed ? index != "." : false }
    public var isUnstaged: Bool {
        switch kind {
        case .untracked: true
        case .ordinary, .renamed: worktree != "."
        case .unmerged, .ignored: false
        }
    }
}

public struct BranchStatus: Sendable, Hashable {
    /// nil for an unborn branch.
    public var oid: String?
    /// nil when HEAD is detached.
    public var head: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0

    public init(oid: String? = nil, head: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0) {
        self.oid = oid; self.head = head; self.upstream = upstream; self.ahead = ahead; self.behind = behind
    }
}

public struct RepoStatus: Sendable, Hashable {
    public var branch = BranchStatus()
    public var entries: [StatusEntry] = []

    public init() {}

    public var staged: [StatusEntry] { entries.filter(\.isStaged) }
    public var unstaged: [StatusEntry] { entries.filter(\.isUnstaged) }
    public var conflicts: [StatusEntry] { entries.filter { $0.kind == .unmerged } }
    /// Changes vs HEAD with no staged/unstaged split, one entry per path.
    public var changes: [StatusEntry] {
        var seen = Set<String>()
        return entries.filter { $0.kind != .ignored && $0.kind != .unmerged && seen.insert($0.path).inserted }
    }
    public var isClean: Bool { entries.allSatisfy { $0.kind == .ignored } }
    /// Tracked changes only (untracked files don't block a pull).
    public var hasTrackedChanges: Bool { entries.contains { $0.kind != .untracked && $0.kind != .ignored } }

    public static let arguments = ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]

    public static func parse(_ data: Data) -> RepoStatus {
        var status = RepoStatus()
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false).makeIterator()
        while let raw = tokens.next() {
            let line = String(decoding: raw, as: UTF8.self)
            guard let tag = line.first else { continue }
            switch tag {
            case "#":
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": status.branch.oid = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": status.branch.head = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": status.branch.upstream = parts[2]
                case "branch.ab":
                    let ab = parts[2].split(separator: " ")
                    if ab.count == 2 {
                        status.branch.ahead = Int(ab[0].dropFirst()) ?? 0
                        status.branch.behind = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
            case "1", "2", "u":
                // 1 XY sub mH mI mW hH hI path / 2 … Xscore path\0orig / u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fieldCount = tag == "1" ? 8 : tag == "2" ? 9 : 10
                let parts = line.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
                guard parts.count == fieldCount + 1 else { continue }
                let xy = Array(parts[1])
                var entry = StatusEntry(kind: tag == "1" ? .ordinary : tag == "2" ? .renamed : .unmerged,
                                        index: xy.first ?? ".", worktree: xy.last ?? ".",
                                        path: String(parts[fieldCount]), originalPath: nil,
                                        isSubmodule: parts[2].first == "S")
                if tag == "2", let orig = tokens.next() {
                    entry.originalPath = String(decoding: orig, as: UTF8.self)
                }
                status.entries.append(entry)
            case "?", "!":
                status.entries.append(StatusEntry(kind: tag == "?" ? .untracked : .ignored, index: tag, worktree: tag,
                                                  path: String(line.dropFirst(2)), originalPath: nil, isSubmodule: false))
            default:
                continue
            }
        }
        return status
    }
}
