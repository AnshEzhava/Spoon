import Foundation

public enum SyncStrategy: String, Codable, Sendable, CaseIterable {
    case ffOnly = "ff-only", rebase, merge
    public var title: String {
        switch self {
        case .ffOnly: "Fast-forward only"
        case .rebase: "Rebase"
        case .merge: "Merge"
        }
    }
}

public enum LocalChangesPolicy: String, Codable, Sendable, CaseIterable { case skip, autostash }

public struct GroupMember: Codable, Hashable, Sendable {
    public var repo: UUID
    /// GRP-14 per-member overrides.
    public var excluded = false
    public var strategy: SyncStrategy?
    public var remote: String?

    public init(repo: UUID) { self.repo = repo }
}

/// Group run defaults (§3.4).
public struct SyncOptions: Codable, Hashable, Sendable {
    public var strategy: SyncStrategy = .ffOnly
    public var fetchAllRemotes = false
    public var localChanges: LocalChangesPolicy = .skip
    public var fastForwardOtherBranches = false
    public var concurrency = 1
    public var delaySeconds = 0.0
    public var stallTimeout = 90.0
    public var stopOnFailure = false

    public init() {}
}

/// Ordered, nestable, many-to-many collection of repositories (§3.1).
public struct RepoGroup: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var parent: UUID?
    public var color: String?
    public var symbol: String?
    public var members: [GroupMember] = []
    public var options = SyncOptions()

    public init(name: String, parent: UUID? = nil) {
        self.name = name
        self.parent = parent
    }

    public func contains(_ repo: UUID) -> Bool { members.contains { $0.repo == repo } }
}

extension Library {
    public func group(_ id: UUID) -> RepoGroup? { groups.first { $0.id == id } }
    public func children(of parent: UUID?) -> [RepoGroup] { groups.filter { $0.parent == parent } }
    public func members(of group: RepoGroup) -> [LibraryRepo] { group.members.compactMap { repo($0.repo) } }
    public func groups(containing repo: UUID) -> [RepoGroup] { groups.filter { $0.contains(repo) } }

    @discardableResult
    public mutating func addGroup(_ name: String, parent: UUID? = nil) -> UUID {
        // Typing `/` in the name nests (GRP-01).
        var parent = parent
        let parts = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for part in parts {
            if let existing = groups.first(where: { $0.parent == parent && $0.name == part }) {
                parent = existing.id
                continue
            }
            let g = RepoGroup(name: part, parent: parent)
            groups.append(g)
            parent = g.id
        }
        return parent ?? UUID()
    }

    public mutating func updateGroup(_ id: UUID, _ body: (inout RepoGroup) -> Void) {
        if let i = groups.firstIndex(where: { $0.id == id }) { body(&groups[i]) }
    }

    /// Removes the group and its subgroups; repos stay in the library (GRP-05).
    public mutating func removeGroup(_ id: UUID) {
        for child in children(of: id) { removeGroup(child.id) }
        groups.removeAll { $0.id == id }
    }

    public mutating func addMembers(_ repos: [UUID], to group: UUID) {
        updateGroup(group) { g in
            for r in repos where !g.contains(r) { g.members.append(GroupMember(repo: r)) }
        }
    }

    public mutating func removeRepo(_ id: UUID) {
        repositories.removeAll { $0.id == id }
        for i in groups.indices { groups[i].members.removeAll { $0.repo == id } }
    }

    /// Group by full path name, `Work/Payments` (case-insensitive).
    public func group(named path: String) -> RepoGroup? {
        groups.first { self.path(of: $0).caseInsensitiveCompare(path) == .orderedSame }
    }

    /// Members in sync order; members whose repo was removed from the library are dropped.
    public func syncTargets(_ group: RepoGroup) -> [SyncTarget] {
        group.members.compactMap { m in repo(m.repo).map { SyncTarget(id: m.repo, path: $0.url, member: m) } }
    }

    /// Full path name, `Work/Payments`.
    public func path(of group: RepoGroup) -> String {
        var names = [group.name]
        var p = group.parent
        while let id = p, let g = self.group(id) { names.insert(g.name, at: 0); p = g.parent }
        return names.joined(separator: "/")
    }
}
