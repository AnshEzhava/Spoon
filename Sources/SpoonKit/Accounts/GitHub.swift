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
