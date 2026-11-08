import AppKit
import Security
import SwiftUI
import Synchronization
import SpoonKit

/// Signed-in forge accounts (ACC-01/02). Tokens live in the Keychain as `login@host` items;
/// logins are cached in memory, tokens after their first read (a dev rebuild re-prompts once).
enum Accounts {
    static let service = "app.spoon.Spoon"
    /// host → login. nil until first loaded.
    private static let logins = Mutex<[String: String]?>(nil)
    private static let tokens = Mutex<[String: String]>([:])

    static func login(for host: String) -> String? { all()[host] }

    static func all() -> [String: String] {
        if let cached = logins.withLock({ $0 }) { return cached }
        var result: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true]
        var found: [String: String] = [:]
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[CFString: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount] as? String, let at = account.lastIndex(of: "@") else { continue }
                found[String(account[account.index(after: at)...])] = String(account[..<at])
            }
        }
        logins.withLock { $0 = found }
        return found
    }

    static func save(host: String, login: String, token: String) throws {
        remove(host: host)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: "\(login)@\(host)", kSecAttrLabel: "Spoon: \(host) (\(login))",
                                     kSecValueData: Data(token.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GitHub.AuthError(description: "Couldn't save to the Keychain (\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")).")
        }
        let current = all() // outside the lock: Mutex isn't reentrant
        logins.withLock { $0 = current.merging([host: login]) { $1 } }
        tokens.withLock { $0[host] = token }
    }

    static func remove(host: String) {
        if let login = login(for: host) {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "\(login)@\(host)"]
            SecItemDelete(query as CFDictionary)
        }
        logins.withLock { $0?[host] = nil }
        tokens.withLock { $0[host] = nil }
    }

    /// Username and token for git over HTTPS, or nil when not signed in to `host`.
    static func credential(host: String) -> (login: String, token: String)? {
        guard let login = login(for: host) else { return nil }
        if let token = tokens.withLock({ $0[host] }) { return (login, token) }
        var result: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: "\(login)@\(host)", kSecReturnData: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        tokens.withLock { $0[host] = token }
        return (login, token)
    }

    /// Credential-helper args for every signed-in host; added to each git invocation the app runs.
    static func gitConfig() -> [String] {
        guard let helper = GitRunner.askpassPath else { return [] }
        return all().keys.sorted().flatMap { GitRunner.credentialArgs(host: $0, helper: helper) }
    }
}

/// Settings → Accounts.
struct AccountsPane: View {
    static let host = "github.com"
    @State private var login = Accounts.login(for: host)
    @State private var code: GitHub.DeviceCode?
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var showToken = false
    @State private var token = ""

    var body: some View {
        Form {
            Section("GitHub") {
                if let login {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: "https://github.com/\(login).png?size=80")) { $0.resizable() } placeholder: {
                            Circle().fill(.quaternary)
                        }
                        .frame(width: 40, height: 40).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(login).font(.headline)
                            Text("Used for git over HTTPS on github.com").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign Out") {
                            Accounts.remove(host: Self.host)
                            self.login = nil
                        }
                    }
                } else if let code {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enter this code on GitHub (it's on your clipboard):")
                        Text(code.userCode).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button("Open GitHub") { NSWorkspace.shared.open(code.verificationURI) }
                            Button("Copy Code") { copy(code.userCode) }
                            ProgressView().controlSize(.small)
                            Text("Waiting for approval…").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { task?.cancel() }
                        }
                    }
                } else {
                    HStack {
                        Button("Sign in with GitHub…") { signIn() }.keyboardShortcut(.defaultAction).disabled(task != nil)
                        Button(showToken ? "Hide Token Field" : "Use a Token Instead…") { showToken.toggle() }
                        if task != nil { ProgressView().controlSize(.small) }
                    }
                    if showToken {
                        SecureField("Personal access token", text: $token)
                        HStack {
                            Text("Needs the repo, read:org and workflow scopes.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Save Token") { saveToken() }.disabled(token.isEmpty || task != nil)
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section {
                Text("Without an account, Spoon uses your existing git credentials (SSH keys, the Keychain helper).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func signIn() {
        error = nil
        task = Task {
            do {
                let c = try await GitHub.requestCode()
                code = c
                copy(c.userCode)
                NSWorkspace.shared.open(c.verificationURI)
                try await finish(try await GitHub.waitForToken(c))
                NSApp.activate()
            } catch {
                if !Task.isCancelled { self.error = (error as? GitHub.AuthError)?.description ?? error.localizedDescription }
            }
            code = nil
            task = nil
        }
    }

    func saveToken() {
        error = nil
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task {
            do {
                try await finish(t)
                token = ""
                showToken = false
            } catch {
                self.error = (error as? GitHub.AuthError)?.description ?? error.localizedDescription
            }
            task = nil
        }
    }

    func finish(_ token: String) async throws {
        let user = try await GitHub.user(token: token)
        try Accounts.save(host: Self.host, login: user.login, token: token)
        login = user.login
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
