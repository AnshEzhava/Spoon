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
