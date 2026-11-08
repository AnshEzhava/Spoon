import Foundation

public struct LibraryRepo: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var path: String
    public var lastOpened: Date?
    /// Tab rename (REPO-10).
    public var displayName: String?

    public init(path: String) { self.path = path }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { displayName ?? url.lastPathComponent }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) }
}

/// `library.json` (§3.7, §4.10).
public struct Library: Codable, Sendable {
    public var version = 1
    public var repositories: [LibraryRepo] = []
    public var groups: [RepoGroup] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        repositories = try c.decodeIfPresent([LibraryRepo].self, forKey: .repositories) ?? []
        groups = try c.decodeIfPresent([RepoGroup].self, forKey: .groups) ?? []
    }

    public func repo(_ id: UUID) -> LibraryRepo? { repositories.first { $0.id == id } }
    public func repo(path: String) -> LibraryRepo? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return repositories.first { $0.url.standardizedFileURL.path == p }
    }

    /// Adds a repo if it's not already known; returns its id either way.
    @discardableResult
    public mutating func add(path: String) -> UUID {
        if let existing = repo(path: path) { return existing.id }
        let r = LibraryRepo(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        repositories.append(r)
        return r.id
    }

    public mutating func touch(_ id: UUID) {
        if let i = repositories.firstIndex(where: { $0.id == id }) { repositories[i].lastOpened = Date() }
    }

    public var recent: [LibraryRepo] {
        repositories.filter { $0.lastOpened != nil }.sorted { $0.lastOpened! > $1.lastOpened! }.prefix(8).map { $0 }
    }
}

/// Atomic JSON file with rotating backups; a corrupt file is quarantined and the newest good backup used (§10.2).
public struct JSONStore<T: Codable>: Sendable {
    public let url: URL
    public let backups: Int

    public init(url: URL, backups: Int = 0) {
        self.url = url
        self.backups = backups
    }

    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SPOON_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spoon")
    }

    func backupURL(_ n: Int) -> URL { url.appendingPathExtension("\(n)") }

    public func load() -> T? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder.spoon.decode(T.self, from: data) {
            return value
        }
        let stamp = Int(Date().timeIntervalSince1970)
        try? fm.moveItem(at: url, to: url.appendingPathExtension("corrupt-\(stamp)"))
        for n in stride(from: 1, through: backups, by: 1) {
            if let data = try? Data(contentsOf: backupURL(n)), let value = try? JSONDecoder.spoon.decode(T.self, from: data) {
                return value
            }
        }
        return nil
    }

    public func save(_ value: T) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.spoon.encode(value)
        if backups > 0, fm.fileExists(atPath: url.path), (try? Data(contentsOf: url)) != data {
            try? fm.removeItem(at: backupURL(backups))
            for n in stride(from: backups - 1, through: 1, by: -1) {
                try? fm.moveItem(at: backupURL(n), to: backupURL(n + 1))
            }
            try? fm.copyItem(at: url, to: backupURL(1))
        }
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    public static var spoon: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    public static var spoon: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Finds repositories under a folder (REPO-06). Doesn't descend into repos it finds.
public enum RepoScanner {
    static let skipped: Set<String> = ["node_modules", "Library", "Pods", "DerivedData", "build", "dist", "vendor"]

    public enum FolderCheck: Sendable {
        /// The working tree's top level, even when a subfolder was picked.
        case repository(URL)
        /// No repository here; `nested` are repos found inside it.
        case notRepository(nested: [URL])
        case unsupported(String)
    }

    /// What "Add Existing Repository" should do with a picked folder. Asks git, so worktrees and subfolders count.
    public static func check(_ folder: URL, git: GitRunner) async -> FolderCheck {
        do {
            return .repository(try await Repository.open(folder, git: git).workTree)
        } catch let e as GitError where e.stderr.contains("not a git repository") {
            return .notRepository(nested: scan(folder, maxDepth: 3))
        } catch let e as GitError where e.stderr.contains("must be run in a work tree") {
            return .unsupported("It's a bare repository; Spoon needs a working copy.")
        } catch let e as GitError {
            return .unsupported(e.stderr.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "fatal: ", with: "") } ?? "git failed")
        } catch {
            return .unsupported(error.localizedDescription)
        }
    }

    public static func scan(_ root: URL, maxDepth: Int = 4) -> [URL] {
        var found: [URL] = []
        walk(root.standardizedFileURL, depth: 0, maxDepth: maxDepth, into: &found)
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func walk(_ dir: URL, depth: Int, maxDepth: Int, into found: inout [URL]) {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            found.append(dir)
            return
        }
        guard depth < maxDepth,
              let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        for child in children where !skipped.contains(child.lastPathComponent) {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            walk(child, depth: depth + 1, maxDepth: maxDepth, into: &found)
        }
    }
}
