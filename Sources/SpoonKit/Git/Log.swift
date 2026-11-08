import Foundation

public struct Commit: Sendable, Hashable, Identifiable {
    public var sha: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var authorDate: Int64
    public var committerName: String
    public var committerEmail: String
    public var commitDate: Int64
    /// `%D` decorations, e.g. `HEAD -> main`, `origin/main`, `tag: v1`.
    public var decorations: [String]
    public var subject: String

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

/// Streaming parser for `git log -z --format=<fields separated by %x00>` (§4.4).
/// Feed it chunks as they arrive; it returns the commits completed so far.
public struct LogParser: Sendable {
    public static let format = "%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%D%x00%s"
    static let fieldCount = 10

    public static func arguments(order: CommitOrder = .topo, refs: [String] = ["--all"], extra: [String] = []) -> [String] {
        ["log", order.flag, "-z", "--format=\(format)"] + extra + refs + ["--"]
    }

    private var pending = Data()
    private var fields: [String] = []

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Commit] {
        pending.append(chunk)
        var commits: [Commit] = []
        var start = pending.startIndex
        while let nul = pending[start...].firstIndex(of: 0) {
            fields.append(String(decoding: pending[start..<nul], as: UTF8.self))
            start = pending.index(after: nul)
            if fields.count == Self.fieldCount {
                commits.append(Self.makeCommit(fields))
                fields.removeAll(keepingCapacity: true)
            }
        }
        pending = Data(pending[start...])
        return commits
    }

    /// Flushes a final record that lacked its terminating NUL.
    public mutating func finish() -> [Commit] {
        guard !pending.isEmpty || !fields.isEmpty else { return [] }
        fields.append(String(decoding: pending, as: UTF8.self))
        pending = Data()
        defer { fields.removeAll() }
        return fields.count == Self.fieldCount ? [Self.makeCommit(fields)] : []
    }

    public static func parse(_ data: Data) -> [Commit] {
        var p = LogParser()
        return p.feed(data) + p.finish()
    }

    static func makeCommit(_ f: [String]) -> Commit {
        Commit(sha: f[0].trimmingCharacters(in: .newlines),
               parents: f[1].split(separator: " ").map(String.init),
               authorName: f[2], authorEmail: f[3], authorDate: Int64(f[4]) ?? 0,
               committerName: f[5], committerEmail: f[6], commitDate: Int64(f[7]) ?? 0,
               decorations: f[8].isEmpty ? [] : f[8].components(separatedBy: ", "),
               subject: f[9])
    }
}

public enum CommitOrder: String, Sendable, Codable, CaseIterable {
    case topo, date
    var flag: String { self == .topo ? "--topo-order" : "--date-order" }
}

/// Full commit details for the Commit tab (§5.8.1).
public struct CommitDetails: Sendable, Hashable {
    public var commit: Commit
    public var body: String

    public static func arguments(_ sha: String) -> [String] {
        ["show", "-s", "-z", "--format=\(LogParser.format)%x00%b", sha]
    }

    public static func parse(_ data: Data) -> CommitDetails? {
        let f = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard f.count >= 11 else { return nil }
        return CommitDetails(commit: LogParser.makeCommit(Array(f[0..<10])),
                             body: f[10].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
