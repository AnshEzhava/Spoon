import Foundation

/// Resolves the user's login-shell environment so hooks see nvm, pnpm, husky and friends (§4.8).
public enum LoginEnvironment {
    /// Resolved once per process. ponytail: not re-resolved when rc files change; add an FSEvents watch on ~/.zshrc etc. if needed.
    public static let shared: [String: String] = resolve()

    static let sentinel = "__SPOON_ENV_7f3a__"

    public static func resolve(shell: String? = nil, timeout: TimeInterval = 3) -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        // `make dev` and the CLI already run inside a login shell; the GUI launched from Finder does not.
        if base["SPOON_SKIP_LOGIN_ENV"] != nil { return base }
        let shell = shell ?? base["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\(sentinel)'; command env -0"]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return base }

        let done = DispatchSemaphore(value: 0)
        let box = OutBox()
        DispatchQueue.global().async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return base
        }
        process.waitUntilExit()
        guard let parsed = parse(box.data), parsed["PATH"] != nil else { return base }
        return parsed
    }

    /// Everything before the last sentinel is rc-file noise; after it, `env -0` output.
    static func parse(_ data: Data) -> [String: String]? {
        let marker = Data(sentinel.utf8)
        guard let range = data.range(of: marker, options: .backwards) else { return nil }
        var env: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return env
    }
}

private final class OutBox: @unchecked Sendable { var data = Data() }
