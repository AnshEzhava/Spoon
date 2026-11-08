import Foundation

public struct GitResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

public struct GitError: Error, CustomStringConvertible, Sendable {
    public let args: [String]
    public let status: Int32
    public let stderr: String
    public init(args: [String], status: Int32, stderr: String) { self.args = args; self.status = status; self.stderr = stderr }
    public var description: String {
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(args.joined(separator: " ")) exited \(status)" + (msg.isEmpty ? "" : ": \(msg)")
    }
}

/// One finished git invocation, for the Activity Manager (§4.3, §5.16).
public struct ActivityRecord: Sendable, Identifiable {
    public let id = UUID()
    public let args: [String]
    public let directory: String?
    public let start: Date
    public let end: Date
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var commandLine: String { "git " + args.map(Self.shellQuote).joined(separator: " ") }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@^~{}".contains($0) }) && !s.isEmpty
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Strips credentials from URLs (`https://user:token@host`) and Authorization headers (§10.3).
    static func redact(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"(\w+://)[^/@\s]+@"#, with: "$1***@", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)(authorization:\s*)\S.*"#, with: "$1***", options: .regularExpression)
        return out
    }
}

/// Wraps `Foundation.Process`. Arguments are always an array, never a shell string (§4.3).
public struct GitRunner: Sendable {
    public var gitPath: String
    public var environment: [String: String]
    /// Called after every invocation; feeds the activity log.
    public var onRecord: (@Sendable (ActivityRecord) -> Void)?
    /// Extra `-c` args read at every invocation, so signing in or out applies to runners already handed out.
    public var dynamicConfig: (@Sendable () -> [String])?

    public static let prefix = ["--no-pager", "-c", "color.ui=false", "-c", "core.quotepath=false"]

    public init(gitPath: String? = nil, environment: [String: String]? = nil) {
        let env = environment ?? LoginEnvironment.shared
        self.environment = env
        self.gitPath = gitPath ?? GitRunner.locateGit(path: env["PATH"])
    }

    public static func locateGit(path: String?) -> String {
        for dir in (path ?? "").split(separator: ":") {
            let candidate = "\(dir)/git"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/git"
    }

    func processEnvironment(background: Bool, extra: [String: String]) -> [String: String] {
        var env = environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        if background { env["GIT_OPTIONAL_LOCKS"] = "0" }
        if let askpass = Self.askpassPath {
            env["GIT_ASKPASS"] = askpass
            env["SSH_ASKPASS"] = askpass
            env["SSH_ASKPASS_REQUIRE"] = "force"
        }
        env.merge(extra) { _, new in new }
        return env
    }

    /// SpoonAskpass sits next to the running executable inside the app bundle (Contents/Helpers).
    public static let askpassPath: String? = {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for candidate in [
            exe.deletingLastPathComponent().appendingPathComponent("SpoonAskpass"),
            exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/SpoonAskpass"),
        ] where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }()

    /// Runs git and collects all output. Throws `GitError` on non-zero exit when `check` is true.
    @discardableResult
    public func run(_ args: [String], in dir: URL? = nil, background: Bool = false, input: Data? = nil,
                    env extra: [String: String] = [:], check: Bool = true) async throws -> GitResult {
        let result = try await execute(args, in: dir, background: background, input: input, extra: extra, onStdout: nil)
        if check && result.status != 0 {
            throw GitError(args: args, status: result.status, stderr: result.errorOutput)
        }
        return result
    }

    /// Runs git and hands stdout to `onStdout` chunk by chunk as it arrives. The returned result has empty stdout.
    @discardableResult
    public func stream(_ args: [String], in dir: URL? = nil, background: Bool = false, input: Data? = nil,
                       env extra: [String: String] = [:], check: Bool = true,
                       onStderr: (@Sendable (Data) -> Void)? = nil,
                       onStdout: (@Sendable (Data) -> Void)? = nil) async throws -> GitResult {
        let result = try await execute(args, in: dir, background: background, input: input, extra: extra,
                                       onStdout: onStdout, onStderr: onStderr)
        if check && result.status != 0 {
            throw GitError(args: args, status: result.status, stderr: result.errorOutput)
        }
        return result
    }

    private func execute(_ args: [String], in dir: URL?, background: Bool, input: Data?, extra: [String: String],
                         onStdout: (@Sendable (Data) -> Void)?, onStderr: (@Sendable (Data) -> Void)? = nil) async throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = Self.prefix + (dynamicConfig?() ?? []) + args
        process.environment = processEnvironment(background: background, extra: extra)
        if let dir { process.currentDirectoryURL = dir }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let box = ProcessBox(process)
        let start = Date()
        let result: GitResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GitResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try process.run() } catch { cont.resume(throwing: error); return }
                    if let inPipe, let input {
                        DispatchQueue.global().async {
                            try? inPipe.fileHandleForWriting.write(contentsOf: input)
                            try? inPipe.fileHandleForWriting.close()
                        }
                    }
                    let group = DispatchGroup()
                    let errData = DataBox()
                    group.enter()
                    DispatchQueue.global().async {
                        if let onStderr {
                            while true {
                                let chunk = err.fileHandleForReading.availableData
                                if chunk.isEmpty { break }
                                errData.data.append(chunk)
                                onStderr(chunk)
                            }
                        } else {
                            errData.data = err.fileHandleForReading.readDataToEndOfFile()
                        }
                        group.leave()
                    }
                    var stdout = Data()
                    let handle = out.fileHandleForReading
                    if let onStdout {
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            onStdout(chunk)
                        }
                    } else {
                        stdout = handle.readDataToEndOfFile()
                    }
                    group.wait()
                    process.waitUntilExit()
                    cont.resume(returning: GitResult(status: process.terminationStatus, stdout: stdout, stderr: errData.data))
                }
            }
        } onCancel: {
            box.cancel()
        }
        if let onRecord {
            onRecord(ActivityRecord(args: args.map(ActivityRecord.redact), directory: dir?.path, start: start, end: Date(),
                                    status: result.status,
                                    stdout: ActivityRecord.redact(String(decoding: result.stdout.prefix(16_384), as: UTF8.self)),
                                    stderr: ActivityRecord.redact(String(decoding: result.stderr.prefix(16_384), as: UTF8.self))))
        }
        if Task.isCancelled { throw CancellationError() }
        return result
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

/// SIGTERM, then SIGKILL after 5 s (§4.3).
// ponytail: signals git itself, not its process group; git forwards to its children on SIGTERM.
// Switch to posix_spawn with POSIX_SPAWN_SETPGROUP if orphaned ssh/remote-https helpers show up.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
