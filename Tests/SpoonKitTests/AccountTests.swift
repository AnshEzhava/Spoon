import Foundation
import Testing
@testable import SpoonKit

@Suite struct AccountTests {
    @Test func parsesDeviceFlowResponses() {
        func p(_ json: String) -> GitHub.Poll { GitHub.parse(Data(json.utf8)) }
        #expect(p(#"{"access_token":"gho_x","token_type":"bearer","scope":"repo"}"#) == .token("gho_x"))
        #expect(p(#"{"error":"authorization_pending"}"#) == .pending)
        #expect(p(#"{"error":"slow_down","interval":10}"#) == .slowDown)
        #expect(p(#"{"error":"access_denied"}"#) == .failed("Sign-in was cancelled on GitHub."))
        #expect(p("not json") == .failed("Unexpected response from GitHub."))
    }

    @Test func parsesCreateRepoResponses() throws {
        let ok = try GitHub.parseCreated(Data(#"{"clone_url":"https://github.com/me/Spoon.git","html_url":"https://github.com/me/Spoon"}"#.utf8), status: 201)
        #expect(ok.cloneURL == "https://github.com/me/Spoon.git")
        func failure(_ json: String, _ status: Int) -> String {
            do { _ = try GitHub.parseCreated(Data(json.utf8), status: status); return "no error" } catch { return "\(error)" }
        }
        let taken = #"{"message":"Repository creation failed.","errors":[{"resource":"Repository","field":"name","message":"name already exists on this account"}]}"#
        #expect(failure(taken, 422) == "GitHub couldn't create the repository: name already exists on this account.")
        #expect(failure(#"{"message":"Bad credentials"}"#, 401) == "GitHub couldn't create the repository: Bad credentials.")
        #expect(failure("", 502) == "GitHub couldn't create the repository: HTTP 502.")
    }

    @Test func parsesRepoList() throws {
        let json = #"[{"full_name":"acme/api","clone_url":"https://github.com/acme/api.git","private":true,"description":null}]"#
        let repos = try GitHub.parseRepos(Data(json.utf8), status: 200)
        #expect(repos.map(\.fullName) == ["acme/api"])
        #expect(repos[0].cloneURL == "https://github.com/acme/api.git" && repos[0].isPrivate)
        #expect(throws: GitHub.AuthError.self) { try GitHub.parseRepos(Data(#"{"message":"Bad credentials"}"#.utf8), status: 401) }
    }

    /// Real `git credential fill`: github.com gets Spoon's helper, even over a global helper; other hosts keep the user's.
    @Test func credentialHelperIsScopedToHost() async throws {
        let dir = TestRepo.tempDir("cred")
        let helper = dir.appendingPathComponent("spoon helper") // space: exercises quoting
        try "#!/bin/sh\ncat >/dev/null\n[ \"$2\" = get ] && printf 'username=octocat\\npassword=spoon-token\\n'\nexit 0\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let global = dir.appendingPathComponent("gitconfig")
        try "[credential]\n\thelper = \"!f() { cat >/dev/null; echo username=me; echo password=global-secret; }; f\"\n"
            .write(to: global, atomically: true, encoding: .utf8)
        var env = TestRepo.runner.environment
        env["GIT_CONFIG_GLOBAL"] = global.path
        let git = GitRunner(environment: env)

        func fill(_ host: String) async throws -> String {
            try await git.run(GitRunner.credentialArgs(host: "github.com", helper: helper.path) + ["credential", "fill"],
                              input: Data("protocol=https\nhost=\(host)\n\n".utf8)).output
        }
        let github = try await fill("github.com")
        #expect(github.contains("username=octocat"))
        #expect(github.contains("password=spoon-token"))
        #expect(try await fill("gitlab.com").contains("password=global-secret"))
    }
}
