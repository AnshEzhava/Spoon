import Foundation

/// GitHub sign-in through the OAuth device flow (ACC-01): no callback server, no client secret.
public enum GitHub {
    /// Public by design: the device flow has no secret.
    public static let clientID = "Ov23lixQPoyNuu3aPczc"
    /// `workflow` is required to push changes under `.github/workflows`.
    public static let scopes = "repo read:org workflow"

    public struct DeviceCode: Decodable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURI: URL
        public let expiresIn: Int
        public let interval: Int
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri", expiresIn = "expires_in", interval
        }
    }

    public struct User: Decodable, Sendable {
        public let login: String
        public let name: String?
    }

    public struct AuthError: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(description: String) { self.description = description }
    }

    enum Poll: Equatable { case token(String), pending, slowDown, failed(String) }

    public static func requestCode() async throws -> DeviceCode {
        let data = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": scopes])
        if case .failed(let message) = parse(data) { throw AuthError(description: message) }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Polls until the user approves in the browser, declines, or the code expires.
    public static func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let data = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID, "device_code": code.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            switch parse(data) {
            case .token(let token): return token
            case .pending: continue
            case .slowDown: interval += 5
            case .failed(let message): throw AuthError(description: message)
            }
        }
        throw AuthError(description: "The code expired. Try again.")
    }

    /// Who the token belongs to; also proves the token works.
    public static func user(token: String) async throws -> User {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AuthError(description: "GitHub didn't accept that token.") }
        return try JSONDecoder().decode(User.self, from: data)
    }

    public struct CreatedRepo: Decodable, Sendable {
        public let cloneURL: String
        public let htmlURL: URL
        enum CodingKeys: String, CodingKey { case cloneURL = "clone_url", htmlURL = "html_url" }
    }

    /// Creates a repository under the token's own account. Needs the `repo` scope.
    public static func createRepo(name: String, description: String, isPrivate: Bool, token: String) async throws -> CreatedRepo {
        var req = URLRequest(url: URL(string: "https://api.github.com/user/repos")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "description": description, "private": isPrivate])
        let (data, response) = try await URLSession.shared.data(for: req)
        return try parseCreated(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func parseCreated(_ data: Data, status: Int) throws -> CreatedRepo {
        if status == 201, let repo = try? JSONDecoder().decode(CreatedRepo.self, from: data) { return repo }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // A 422's top-level message is just "Repository creation failed."; the reason is in errors[].
        let reason = ((obj?["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String }.first)
            ?? obj?["message"] as? String ?? "HTTP \(status)"
        throw AuthError(description: "GitHub couldn't create the repository: \(reason).")
    }

    public struct Repo: Decodable, Sendable, Identifiable {
        public let fullName: String
        public let cloneURL: String
        public let isPrivate: Bool
        public var id: String { fullName }
        enum CodingKeys: String, CodingKey { case fullName = "full_name", cloneURL = "clone_url", isPrivate = "private" }
    }

    /// Repos the token can see (own, collaborator, org member), most recently pushed first.
    /// Org repos only show if the org allows this OAuth app.
    public static func repos(token: String) async throws -> [Repo] {
        var all: [Repo] = [], page = 1
        while true {
            var req = URLRequest(url: URL(string: "https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100&page=\(page)")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            let batch = try parseRepos(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            all += batch
            if batch.count < 100 { return all }
            page += 1
        }
    }

    static func parseRepos(_ data: Data, status: Int) throws -> [Repo] {
        if status == 200, let repos = try? JSONDecoder().decode([Repo].self, from: data) { return repos }
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
        throw AuthError(description: "Couldn't load your GitHub repositories: \(message).")
    }

    static func post(_ url: String, _ form: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        return try await URLSession.shared.data(for: req).0
    }

    /// Token-endpoint responses; device-code responses only use the `.failed` case.
    static func parse(_ data: Data) -> Poll {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed("Unexpected response from GitHub.") }
        if let token = obj["access_token"] as? String { return .token(token) }
        switch obj["error"] as? String {
        case nil: return .pending
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": return .failed("The code expired. Try again.")
        case "access_denied": return .failed("Sign-in was cancelled on GitHub.")
        case "device_flow_disabled": return .failed("Device flow is disabled for this OAuth app. Enable it in the app's GitHub settings.")
        case let e?: return .failed(obj["error_description"] as? String ?? e)
        }
    }
}

extension GitRunner {
    /// `-c` pairs that make `helper` the only credential helper for `https://host` (§4.7).
    /// The empty value clears helpers from system/global config for that host only; other hosts keep the user's helpers.
    public static func credentialArgs(host: String, helper: String) -> [String] {
        let key = "credential.https://\(host).helper"
        return ["-c", "\(key)=", "-c", "\(key)=!\(ActivityRecord.shellQuote(helper)) --credential"]
    }
}
