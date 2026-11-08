import Foundation
@testable import SpoonKit

/// Throwaway repo in a temp dir, with git isolated from the user's config (§10.5).
struct TestRepo {
    let url: URL
    let git: GitRunner

    static let env: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        "HOME": NSTemporaryDirectory(),
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Kim Lee", "GIT_AUTHOR_EMAIL": "kim@example.com",
        "GIT_COMMITTER_NAME": "Kim Lee", "GIT_COMMITTER_EMAIL": "kim@example.com",
    ]
    static let runner = GitRunner(environment: env)

    static func tempDir(_ name: String = "repo") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoon-tests-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    init(_ name: String = "repo", at dir: URL? = nil, bare: Bool = false) async throws {
        url = dir ?? Self.tempDir(name)
        git = Self.runner
        try await git.run(["init", "-q", "-b", "main"] + (bare ? ["--bare"] : []), in: url)
    }

    /// Clone of `origin` (a bare TestRepo or any path).
    init(cloning origin: URL, name: String = "clone") async throws {
        let parent = Self.tempDir("parent")
        url = parent.appendingPathComponent(name)
        git = Self.runner
        try await git.run(["clone", "-q", origin.path, url.path], in: parent)
    }

    @discardableResult
    func run(_ args: String...) async throws -> String {
        try await git.run(args, in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ content: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    @discardableResult
    func commit(_ message: String, files: [String: String] = [:]) async throws -> String {
        for (p, c) in files { try write(p, c) }
        try await run("add", "-A")
        try await run("commit", "-q", "--allow-empty", "-m", message)
        return try await run("rev-parse", "HEAD")
    }

    func repository() async throws -> Repository {
        try await Repository.open(url, git: git)
    }
}
