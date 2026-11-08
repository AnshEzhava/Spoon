import Foundation
import Testing
@testable import SpoonKit

private func nul(_ parts: [String]) -> Data { Data(parts.joined(separator: "\0").utf8) + Data([0]) }

@Suite struct StatusParserTests {
    @Test func parsesBranchHeadersAndEntries() {
        let data = nul([
            "# branch.oid 3fa2b1c0",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +1 -4",
            "1 .M N... 100644 100644 100644 aaa bbb src/a file.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new name", "old name",
            "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt",
            "? docs/notes.md",
            "! build/out",
        ])
        let s = RepoStatus.parse(data)
        #expect(s.branch == BranchStatus(oid: "3fa2b1c0", head: "main", upstream: "origin/main", ahead: 1, behind: 4))
        #expect(s.entries.count == 5)
        #expect(s.entries[0].path == "src/a file.swift")
        #expect(s.entries[0].isUnstaged && !s.entries[0].isStaged)
        #expect(s.entries[1].kind == .renamed && s.entries[1].originalPath == "old name" && s.entries[1].path == "new name")
        #expect(s.conflicts.map(\.path) == ["conflict.txt"])
        #expect(s.unstaged.map(\.path) == ["src/a file.swift", "docs/notes.md"])
        #expect(s.staged.map(\.path) == ["new name"])
    }

    @Test func initialAndDetached() {
        let s = RepoStatus.parse(nul(["# branch.oid (initial)", "# branch.head (detached)"]))
        #expect(s.branch.oid == nil && s.branch.head == nil && s.isClean)
    }
}

@Suite struct LogParserTests {
    static let record = ["abc123", "p1 p2", "Kim", "kim@x", "1700000000", "Sam", "sam@x", "1700000100",
                         "HEAD -> main, origin/main, tag: v1", "Merge branch 'feat/x'"]

    @Test func parsesRecord() {
        let commits = LogParser.parse(nul(Self.record) + nul(Self.record.map { $0 == "abc123" ? "def456" : $0 }))
        #expect(commits.count == 2)
        let c = commits[0]
        #expect(c.sha == "abc123" && c.parents == ["p1", "p2"] && c.isMerge)
        #expect(c.decorations == ["HEAD -> main", "origin/main", "tag: v1"])
        #expect(c.subject == "Merge branch 'feat/x'" && c.commitDate == 1700000100)
    }

    @Test func streamingByteByByteMatchesWhole() {
        let data = nul(Self.record) + nul(Self.record)
        var p = LogParser()
        var out: [Commit] = []
        for byte in data { out += p.feed(Data([byte])) }
        out += p.finish()
        #expect(out == LogParser.parse(data))
        #expect(out.count == 2)
    }
}

@Suite struct DiffParserTests {
    @Test func modifiedAddedDeletedRenamed() {
        let text = """
        diff --git a/src/round.swift b/src/round.swift
        index 1111111..2222222 100644
        --- a/src/round.swift
        +++ b/src/round.swift
        @@ -41,3 +41,4 @@ func round(x: Double)
             let scale = 10
        -    return x
        +    return y
        +    // banker's
        \\ No newline at end of file
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100755
        index 4444444..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old name.txt b/new name.txt
        similarity index 90%
        rename from old name.txt
        rename to new name.txt
        diff --git a/img.png b/img.png
        index 5555555..6666666 100644
        Binary files a/img.png and b/img.png differ
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755

        """
        let files = DiffParser.parse(text)
        #expect(files.count == 6)
        let m = files[0]
        #expect(m.path == "src/round.swift" && m.status == .modified)
        #expect(m.hunks.count == 1 && m.hunks[0].heading == "func round(x: Double)")
        #expect(m.additions == 2 && m.deletions == 1)
        let lines = m.hunks[0].lines
        #expect(lines[0] == DiffLine(kind: .context, text: "    let scale = 10", oldLine: 41, newLine: 41))
        #expect(lines[1].oldLine == 42 && lines[1].kind == .deleted)
        #expect(lines[2].newLine == 42 && lines[3].newLine == 43)
        #expect(lines[4].kind == .noNewline)
        #expect(files[1].status == .added && files[1].newMode == "100644" && files[1].hunks[0].newCount == 1)
        #expect(files[2].status == .deleted && files[2].path == "gone.txt")
        #expect(files[3].status == .renamed && files[3].oldPath == "old name.txt" && files[3].newPath == "new name.txt"
                && files[3].similarity == 90)
        #expect(files[4].isBinary)
        #expect(files[5].oldMode == "100644" && files[5].newMode == "100755" && files[5].status == .modified)
    }

    @Test func quotedPaths() {
        #expect(DiffParser.unquote("\"caf\\303\\251 \\\"x\\\"\\t\"") == "café \"x\"\t")
        let (a, b) = DiffParser.splitGitHeader("\"a/t\\tab\" \"b/t\\tab\"")
        #expect(a == "t\tab" && b == "t\tab")
        let (c, d) = DiffParser.splitGitHeader("a/x b/y b/z b/x b/y b/z")
        #expect(c == "x b/y b/z" && d == "x b/y b/z")
    }
}

@Suite struct RefsParserTests {
    @Test func parsesTrackAndSkipsSymrefs() {
        let lines = [
            ["refs/heads/main", "aaa", "", "refs/remotes/origin/main", "ahead 1, behind 4", "/repo", "*", "1700000000", ""],
            ["refs/heads/old", "bbb", "", "refs/remotes/origin/old", "gone", "", " ", "1", ""],
            ["refs/remotes/origin/HEAD", "aaa", "", "", "", "", " ", "1", "refs/remotes/origin/main"],
            ["refs/tags/v1", "tagobj", "ccc", "", "", "", " ", "1", ""],
        ].map { $0.joined(separator: "\0") }.joined(separator: "\n")
        let refs = Ref.parse(Data(lines.utf8))
        #expect(refs.map(\.shortName) == ["main", "old", "v1"])
        #expect(refs[0].isHead && refs[0].ahead == 1 && refs[0].behind == 4 && refs[0].worktreePath == "/repo")
        #expect(refs[1].upstreamGone && !refs[1].isHead)
        #expect(refs[2].kind == .tag && refs[2].target == "ccc")
    }
}

@Suite struct EnvironmentTests {
    @Test func stripsRcNoise() {
        var data = Data("Welcome to zsh! \(LoginEnvironment.sentinel)\n".utf8)
        data = Data("motd \(LoginEnvironment.sentinel)".utf8) + Data("PATH=/a:/b\0FOO=x=y\0".utf8)
        let env = LoginEnvironment.parse(data)
        #expect(env == ["PATH": "/a:/b", "FOO": "x=y"])
    }

    @Test func resolvesRealLoginShell() {
        let env = LoginEnvironment.resolve(shell: "/bin/zsh")
        #expect(env["PATH"]?.isEmpty == false)
    }
}

@Suite struct ChangeClassifierTests {
    @Test func classifies() {
        let c = RepoChange.classify([
            "/r/.git/HEAD", "/r/.git/objects/ab/cdef", "/r/.git/logs/HEAD", "/r/.git/index.lock",
            "/r/src/a.swift", "/r/.git/refs/heads/main",
        ], workTree: "/r", gitDir: "/r/.git", commonDir: "/r/.git")
        #expect(c.state && c.paths == ["src/a.swift"] && !c.fullRescan)

        let quiet = RepoChange.classify(["/r/.git/objects/x", "/r/.git/logs/refs/heads/main"],
                                        workTree: "/r", gitDir: "/r/.git", commonDir: "/r/.git")
        #expect(quiet.isEmpty)

        let burst = RepoChange.classify((0..<501).map { "/r/f\($0)" }, workTree: "/r", gitDir: "/r/.git", commonDir: "/r/.git")
        #expect(burst.fullRescan && burst.paths.isEmpty)
    }

    @Test func redactsSecrets() {
        #expect(ActivityRecord.redact("https://kim:ghp_123@github.com/a/b.git") == "https://***@github.com/a/b.git")
        #expect(ActivityRecord.redact("Authorization: Bearer xyz") == "Authorization: ***")
    }
}
