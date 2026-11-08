import Foundation

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case context, added, deleted, noNewline }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
        self.kind = kind; self.text = text; self.oldLine = oldLine; self.newLine = newLine
    }
}

public struct Hunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Function context after the second `@@`.
    public var heading: String
    public var lines: [DiffLine]

    public var header: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" + (heading.isEmpty ? "" : " \(heading)")
    }
}

public struct FileDiff: Sendable, Hashable, Identifiable {
    public enum Status: Character, Sendable, Hashable {
        case added = "A", deleted = "D", modified = "M", renamed = "R", copied = "C", typeChanged = "T"
    }
    public var oldPath: String
    public var newPath: String
    public var status: Status = .modified
    public var oldMode: String?
    public var newMode: String?
    public var similarity: Int?
    public var isBinary = false
    public var hunks: [Hunk] = []

    public init(oldPath: String, newPath: String, status: Status = .modified, isBinary: Bool = false) {
        self.oldPath = oldPath; self.newPath = newPath; self.status = status; self.isBinary = isBinary
    }

    public var id: String { newPath }
    public var path: String { status == .deleted ? oldPath : newPath }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deleted } } }
}

public struct DiffOptions: Sendable, Hashable {
    public var ignoreWhitespace = false
    public var context = 3
    public init(ignoreWhitespace: Bool = false, context: Int = 3) {
        self.ignoreWhitespace = ignoreWhitespace
        self.context = context
    }
    public var flags: [String] {
        ["--no-color", "--no-ext-diff", "-M", "--patch", "-U\(context)"] + (ignoreWhitespace ? ["-w"] : [])
    }
}

public enum DiffParser {
    public static func parse(_ data: Data) -> [FileDiff] {
        parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var file: FileDiff?
        var hunk: Hunk?
        var oldLine = 0, newLine = 0

        func flushHunk() {
            if let h = hunk { file?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = file { files.append(f) }
            file = nil
        }

        // Split on \n only; keep \r as content (CRLF files).
        for sub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sub)
            if hunk != nil, let first = line.first, " +-\\".contains(first) {
                let body = String(line.dropFirst())
                switch first {
                case " ":
                    hunk!.lines.append(DiffLine(kind: .context, text: body, oldLine: oldLine, newLine: newLine))
                    oldLine += 1; newLine += 1
                case "+":
                    hunk!.lines.append(DiffLine(kind: .added, text: body, oldLine: nil, newLine: newLine))
                    newLine += 1
                case "-":
                    hunk!.lines.append(DiffLine(kind: .deleted, text: body, oldLine: oldLine, newLine: nil))
                    oldLine += 1
                default:
                    hunk!.lines.append(DiffLine(kind: .noNewline, text: body, oldLine: nil, newLine: nil))
                }
                continue
            }
            if line.hasPrefix("diff --git ") {
                flushFile()
                let (a, b) = splitGitHeader(String(line.dropFirst("diff --git ".count)))
                file = FileDiff(oldPath: a, newPath: b)
            } else if line.hasPrefix("@@ "), file != nil, let h = parseHunkHeader(line) {
                flushHunk()
                hunk = h
                oldLine = h.oldStart
                newLine = h.newStart
            } else if file != nil {
                flushHunk()
                if line.hasPrefix("new file mode ") {
                    file!.status = .added; file!.newMode = String(line.dropFirst(14))
                } else if line.hasPrefix("deleted file mode ") {
                    file!.status = .deleted; file!.oldMode = String(line.dropFirst(18))
                } else if line.hasPrefix("old mode ") {
                    file!.oldMode = String(line.dropFirst(9))
                } else if line.hasPrefix("new mode ") {
                    file!.newMode = String(line.dropFirst(9))
                } else if line.hasPrefix("rename from ") {
                    file!.status = .renamed; file!.oldPath = unquote(String(line.dropFirst(12)))
                } else if line.hasPrefix("rename to ") {
                    file!.newPath = unquote(String(line.dropFirst(10)))
                } else if line.hasPrefix("copy from ") {
                    file!.status = .copied; file!.oldPath = unquote(String(line.dropFirst(10)))
                } else if line.hasPrefix("copy to ") {
                    file!.newPath = unquote(String(line.dropFirst(8)))
                } else if line.hasPrefix("similarity index ") {
                    file!.similarity = Int(line.dropFirst(17).dropLast())
                } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                    file!.isBinary = true
                } else if line.hasPrefix("--- ") {
                    let p = String(line.dropFirst(4))
                    if p != "/dev/null" { file!.oldPath = stripPrefix(unquote(p)) }
                } else if line.hasPrefix("+++ ") {
                    let p = String(line.dropFirst(4))
                    if p != "/dev/null" { file!.newPath = stripPrefix(unquote(p)) }
                }
            }
        }
        flushFile()
        for i in files.indices where files[i].status == .modified {
            if let o = files[i].oldMode, let n = files[i].newMode, o != n,
               o.hasPrefix("12") != n.hasPrefix("12") || o.hasPrefix("16") != n.hasPrefix("16") {
                files[i].status = .typeChanged
            }
        }
        return files
    }

    /// `@@ -a,b +c,d @@ heading`
    static func parseHunkHeader(_ line: String) -> Hunk? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[3] == "@@" else { return nil }
        func range(_ s: Substring) -> (Int, Int) {
            let nums = s.dropFirst().split(separator: ",")
            return (Int(nums[0]) ?? 0, nums.count > 1 ? Int(nums[1]) ?? 0 : 1)
        }
        let (os, oc) = range(parts[1])
        let (ns, nc) = range(parts[2])
        return Hunk(oldStart: os, oldCount: oc, newStart: ns, newCount: nc,
                    heading: parts.count > 4 ? String(parts[4]) : "", lines: [])
    }

    /// `a/x b/y` — ambiguous when paths contain " b/", but `---`/`+++`/rename lines override it.
    static func splitGitHeader(_ s: String) -> (String, String) {
        if s.hasPrefix("\"") {
            let (a, rest) = takeQuoted(s)
            return (stripPrefix(a), stripPrefix(unquote(rest.trimmingCharacters(in: .whitespaces))))
        }
        // Same path on both sides is by far the common case: "a/P b/P".
        let half = (s.count - 1) / 2
        if s.count % 2 == 1 {
            let a = String(s.prefix(half)), b = String(s.suffix(half))
            if a.dropFirst(2) == b.dropFirst(2) { return (stripPrefix(a), stripPrefix(b)) }
        }
        if let r = s.range(of: " b/") {
            return (stripPrefix(String(s[..<r.lowerBound])), String(s[r.upperBound...]))
        }
        return (s, s)
    }

    static func stripPrefix(_ p: String) -> String {
        (p.hasPrefix("a/") || p.hasPrefix("b/")) ? String(p.dropFirst(2)) : p
    }

    static func takeQuoted(_ s: String) -> (String, String) {
        var escaped = false
        for (i, ch) in s.enumerated().dropFirst() {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" {
                let end = s.index(s.startIndex, offsetBy: i + 1)
                return (unquote(String(s[..<end])), String(s[end...]))
            }
        }
        return (s, "")
    }

    /// Undoes git's C-style path quoting (`"a\tb\303\251"`).
    public static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        var bytes: [UInt8] = []
        var it = Array(s.utf8.dropFirst().dropLast()).makeIterator()
        while let c = it.next() {
            guard c == UInt8(ascii: "\\"), let e = it.next() else { bytes.append(c); continue }
            switch e {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var v = Int(e - 48)
                for _ in 0..<2 { if let d = it.next() { v = v * 8 + Int(d - 48) } }
                bytes.append(UInt8(truncatingIfNeeded: v))
            default: bytes.append(e)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
