import Foundation

/// A changed line chosen in the diff view: hunk index + index into `hunk.lines`.
public struct LineRef: Hashable, Sendable {
    public var hunk: Int
    public var line: Int
    public init(hunk: Int, line: Int) {
        self.hunk = hunk
        self.line = line
    }
}

/// Builds minimal patches for hunk and line staging (§4.4.1).
public enum PatchBuilder {
    /// `reverse` builds a patch meant for `git apply -R` (unstage from the staged diff, discard from the unstaged diff):
    /// unselected `+` lines become context and unselected `-` lines are dropped. Forward (stage) does the opposite.
    /// Returns nil when the selection contains no changed lines.
    public static func patch(for file: FileDiff, selection: Set<LineRef>, reverse: Bool) -> String? {
        var hunks: [String] = []
        var delta = 0
        for (hi, hunk) in file.hunks.enumerated() {
            var out: [String] = []
            var oldCount = 0, newCount = 0
            var changed = false
            var lastKept = true
            for (li, line) in hunk.lines.enumerated() {
                let selected = selection.contains(LineRef(hunk: hi, line: li))
                switch line.kind {
                case .context:
                    out.append(" " + line.text); oldCount += 1; newCount += 1; lastKept = true
                case .added:
                    if selected {
                        out.append("+" + line.text); newCount += 1; changed = true; lastKept = true
                    } else if reverse {
                        out.append(" " + line.text); oldCount += 1; newCount += 1; lastKept = true
                    } else {
                        lastKept = false
                    }
                case .deleted:
                    if selected {
                        out.append("-" + line.text); oldCount += 1; changed = true; lastKept = true
                    } else if !reverse {
                        out.append(" " + line.text); oldCount += 1; newCount += 1; lastKept = true
                    } else {
                        lastKept = false
                    }
                case .noNewline:
                    if lastKept { out.append("\\" + line.text) }
                }
            }
            guard changed else { continue }
            // The side git matches against keeps the original start: old for stage, new for `apply -R`.
            let oldStart = reverse ? max(hunk.newStart - delta, 0) : hunk.oldStart
            let newStart = reverse ? hunk.newStart : max(hunk.oldStart + delta, 0)
            delta += newCount - oldCount
            hunks.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n" + out.joined(separator: "\n"))
        }
        guard !hunks.isEmpty else { return nil }
        let a = quote("a/" + file.oldPath), b = quote("b/" + file.newPath)
        var header = "diff --git \(a) \(b)\n"
        if file.status == .added {
            header += "new file mode \(file.newMode ?? "100644")\n--- /dev/null\n+++ \(b)\n"
        } else if file.status == .deleted {
            header += "deleted file mode \(file.oldMode ?? "100644")\n--- \(a)\n+++ /dev/null\n"
        } else {
            header += "--- \(a)\n+++ \(b)\n"
        }
        return header + hunks.joined(separator: "\n") + "\n"
    }

    /// All changed lines of the given hunks.
    public static func lines(of file: FileDiff, hunks: [Int]) -> Set<LineRef> {
        var set = Set<LineRef>()
        for h in hunks where h < file.hunks.count {
            for (i, l) in file.hunks[h].lines.enumerated() where l.kind == .added || l.kind == .deleted {
                set.insert(LineRef(hunk: h, line: i))
            }
        }
        return set
    }

    /// C-style quoting, only when git would need it.
    static func quote(_ path: String) -> String {
        guard path.contains(where: { $0 == "\"" || $0 == "\\" || $0 == "\t" || $0 == "\n" }) else { return path }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

/// Plain-language summaries for common git failures (§5.13 error sheet).
public struct GitFailure: Sendable, Equatable {
    public enum Fix: String, Sendable, CaseIterable {
        case pullThenPush = "Pull then Push"
        case forceWithLease = "Force with Lease…"
        case removeLock = "Remove stale index.lock"
        case stashAndRetry = "Stash and Retry"
        case pullRebase = "Pull with Rebase"
    }
    public enum Kind: Sendable, Equatable { case rejected, locked, auth, network, localChanges, conflicts, diverged, hook, noUpstream, other }

    public var kind: Kind
    public var summary: String
    public var fixes: [Fix]
    public init(kind: Kind, summary: String, fixes: [Fix]) { self.kind = kind; self.summary = summary; self.fixes = fixes }

    public static func classify(_ stderr: String) -> GitFailure {
        let s = stderr.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }
        if has("[rejected]", "failed to push some refs") && has("fetch first", "non-fast-forward", "rejected") {
            return GitFailure(kind: .rejected, summary: "Push rejected: remote has commits you don't have", fixes: [.pullThenPush, .forceWithLease])
        }
        if has("index.lock") && has("file exists", "unable to create") {
            return GitFailure(kind: .locked, summary: "Another git process is running in this repository", fixes: [.removeLock])
        }
        if has("authentication failed", "permission denied (publickey", "could not read username", "could not read password",
               "terminal prompts disabled", "invalid username or password", "host key verification failed") {
            return GitFailure(kind: .auth, summary: "Authentication failed", fixes: [])
        }
        if has("could not resolve host", "connection timed out", "network is unreachable", "connection refused", "unable to access",
               "could not read from remote repository") {
            return GitFailure(kind: .network, summary: "Couldn't reach the remote", fixes: [])
        }
        if has("would be overwritten by", "please commit your changes or stash them") {
            return GitFailure(kind: .localChanges, summary: "Local changes would be overwritten", fixes: [.stashAndRetry])
        }
        if has("not possible to fast-forward", "diverging branches can't be fast-forwarded", "need to specify how to reconcile") {
            return GitFailure(kind: .diverged, summary: "Branches have diverged and can't be fast-forwarded", fixes: [.pullRebase])
        }
        if has("conflict (", "automatic merge failed", "could not apply", "fix conflicts") {
            return GitFailure(kind: .conflicts, summary: "Conflicts need to be resolved", fixes: [])
        }
        if has("hook", "husky") && has("failed", "exit", "error") {
            return GitFailure(kind: .hook, summary: "A git hook failed", fixes: [])
        }
        if has("no upstream", "has no upstream branch", "no tracking information") {
            return GitFailure(kind: .noUpstream, summary: "The current branch has no upstream", fixes: [])
        }
        let first = stderr.split(separator: "\n").first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
        return GitFailure(kind: .other, summary: first.map { String($0).replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: "") }
                          ?? "The git command failed", fixes: [])
    }
}

/// Last "Phase: NN%" in a chunk of git progress output (`\r`-separated).
public enum GitProgress {
    public static func parse(_ chunk: String) -> String? {
        let lines = chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for line in lines.reversed() {
            let l = line.replacingOccurrences(of: "remote: ", with: "")
            guard let pct = l.range(of: #"\d+%"#, options: .regularExpression), let colon = l.firstIndex(of: ":"), colon < pct.lowerBound else { continue }
            return "\(l[..<colon].lowercased()) \(l[pct])"
        }
        return nil
    }
}
