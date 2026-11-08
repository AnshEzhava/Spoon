import Foundation

public struct Ref: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case localBranch, remoteBranch, tag, other }
    public var name: String
    /// Commit the ref points at (tags are peeled).
    public var target: String
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var upstreamGone = false
    public var worktreePath: String?
    public var isHead = false
    public var date: Int64 = 0

    public var id: String { name }

    public var kind: Kind {
        if name.hasPrefix("refs/heads/") { return .localBranch }
        if name.hasPrefix("refs/remotes/") { return .remoteBranch }
        if name.hasPrefix("refs/tags/") { return .tag }
        return .other
    }

    public var shortName: String {
        for p in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(p) {
            return String(name.dropFirst(p.count))
        }
        return name
    }

    /// For remote branches, `origin` of `origin/main`.
    public var remoteName: String? {
        kind == .remoteBranch ? shortName.split(separator: "/", maxSplits: 1).first.map(String.init) : nil
    }

    public static let arguments = [
        "for-each-ref",
        "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(upstream:track,nobracket)%00%(worktreepath)%00%(HEAD)%00%(creatordate:unix)%00%(symref)",
        "refs/heads", "refs/remotes", "refs/tags",
    ]

    public static func parse(_ data: Data) -> [Ref] {
        var refs: [Ref] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let f = line.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard f.count >= 9, f[8].isEmpty else { continue }  // skip symrefs like origin/HEAD
            var ref = Ref(name: f[0], target: f[2].isEmpty ? f[1] : f[2])
            ref.upstream = f[3].isEmpty ? nil : f[3]
            for part in f[4].split(separator: ",") {
                let words = part.split(separator: " ")
                switch words.first {
                case "ahead": ref.ahead = Int(words.last ?? "") ?? 0
                case "behind": ref.behind = Int(words.last ?? "") ?? 0
                case "gone": ref.upstreamGone = true
                default: break
                }
            }
            ref.worktreePath = f[5].isEmpty ? nil : f[5]
            ref.isHead = f[6] == "*"
            ref.date = Int64(f[7]) ?? 0
            refs.append(ref)
        }
        return refs
    }
}

public struct Stash: Sendable, Hashable, Identifiable {
    public var sha: String
    public var index: Int
    public var message: String
    public var date: Int64
    public var id: String { sha }
    public var refName: String { "stash@{\(index)}" }

    public static let arguments = ["log", "-g", "-z", "--format=%H%x00%ct%x00%gs", "refs/stash", "--"]

    public static func parse(_ data: Data) -> [Stash] {
        let f = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var out: [Stash] = []
        var i = 0
        while i + 2 < f.count {
            let sha = f[i].trimmingCharacters(in: .newlines)
            if !sha.isEmpty { out.append(Stash(sha: sha, index: out.count, message: f[i + 2], date: Int64(f[i + 1]) ?? 0)) }
            i += 3
        }
        return out
    }
}
