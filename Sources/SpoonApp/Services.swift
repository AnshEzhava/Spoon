import AppKit
import SpoonKit
import Synchronization

/// Answers SpoonAskpass prompts (§4.7): a Unix socket in the per-user temp dir.
/// Prompts are queued and shown one at a time, as a sheet on the asking repo's window.
// ponytail: plain socket instead of XPC; switch when the app is sandboxed.
@MainActor
final class AskpassServer {
    nonisolated static let socketPath = NSTemporaryDirectory() + "spoon-askpass-\(getpid()).sock"
    /// Only in the environment of git processes Spoon starts; required to get a token over the socket.
    // ponytail: stops other socket clients, not same-user code reading a running git's environment; XPC with code-signing checks once Developer ID signed.
    nonisolated static let nonce = UUID().uuidString
    private var queue: [(prompt: String, repo: String, reply: @Sendable (String?) -> Void)] = []
    private var showing = false
    /// Repos with a prompt waiting on the user; group sync pauses their stall timers (§3.4 invariant 5).
    nonisolated private static let pending = Mutex<[String: Int]>([:])

    nonisolated static func isPending(_ path: String) -> Bool {
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return pending.withLock { ($0[key] ?? 0) > 0 }
    }

    func start() {
        let path = Self.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8.prefix($0.count - 1))) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return }
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { if errno == EINTR { continue } else { return } }
                guard let request = Self.readLine(client),
                      let obj = try? JSONSerialization.jsonObject(with: request) as? [String: String] else { close(client); continue }
                if obj["credential"] == "get" {
                    // Credential-helper request: answered here, off the main thread, with no UI.
                    var answer: [String: String] = [:]
                    if obj["nonce"] == Self.nonce, obj["protocol"] == "https", let host = obj["host"], let c = Accounts.credential(host: host) {
                        answer = ["username": c.login, "password": c.token]
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: answer) { _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) } }
                    close(client)
                    continue
                }
                let reply: @Sendable (String?) -> Void = { answer in
                    if let answer, let data = try? JSONSerialization.data(withJSONObject: ["answer": answer]) {
                        _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                    }
                    close(client)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AppDelegate.shared.askpass.enqueue(obj["prompt"] ?? "", repo: obj["repo"] ?? "", reply: reply) }
                }
            }
        }
    }

    func stop() { unlink(Self.socketPath) }

    nonisolated private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 65_536, read(fd, &byte, 1) == 1 {
            if byte == 10 { return data }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    func enqueue(_ prompt: String, repo: String, reply: @escaping @Sendable (String?) -> Void) {
        let key = URL(fileURLWithPath: repo).resolvingSymlinksInPath().path
        Self.pending.withLock { $0[key, default: 0] += 1 }
        let reply: @Sendable (String?) -> Void = { answer in
            Self.pending.withLock { $0[key, default: 1] -= 1 }
            reply(answer)
        }
        queue.append((prompt, repo, reply))
        next()
    }

    private func next() {
        guard !showing, !queue.isEmpty else { return }
        showing = true
        let (prompt, repo, reply) = queue.removeFirst()
        let a = NSAlert()
        a.messageText = "\(URL(fileURLWithPath: repo).lastPathComponent) needs your input"
        a.informativeText = prompt.trimmingCharacters(in: .whitespaces)
        let yesNo = prompt.contains("(yes/no")
        var field: NSTextField?
        if yesNo {
            a.addButton(withTitle: "Yes")
            a.addButton(withTitle: "No")
        } else {
            let secret = ["password", "passphrase", "token", "pin", "otp", "code"].contains { prompt.lowercased().contains($0) }
            let f = secret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            a.accessoryView = f
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            field = f
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            let ok = r == .alertFirstButtonReturn
            reply(yesNo ? (ok ? "yes" : "no") : ok ? field?.stringValue : nil)
            self?.showing = false
            self?.next()
        }
        let window = NSApp.windows.first { ($0.windowController as? TabWindowController)?.repoController?.repo.workTree.path == repo }
            ?? NSApp.keyWindow
        if let window, window.attachedSheet == nil {
            a.beginSheetModal(for: window, completionHandler: finish)
            a.window.initialFirstResponder = field
        } else {
            a.window.initialFirstResponder = field
            finish(a.runModal())
        }
    }
}

/// NET-06: background fetch of open repos every `autoFetchMinutes`, soon after open, and on wake.
@MainActor
final class AutoFetch {
    static let shared = AutoFetch()
    private var last: [URL: Date] = [:]
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { AutoFetch.shared.tick(force: false) } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AutoFetch.shared.tick(force: true) }
        }
    }

    func tick(force: Bool) {
        let minutes = AppModel.shared.settings.autoFetchMinutes
        guard minutes > 0 else { return }
        let open = NSApp.windows.compactMap { ($0.windowController as? TabWindowController)?.repoController }
        for c in open where c.busy == nil && !c.remotes.isEmpty {
            let key = c.repo.workTree
            if !force, let t = last[key], Date().timeIntervalSince(t) < Double(minutes * 60) { continue }
            last[key] = Date()
            // No askpass during background work: prompts must come from something the user started.
            c.perform("Auto-fetch", background: true) { repo, _ in try await repo.fetch(remote: nil, env: ["SPOON_ASKPASS_SOCKET": ""]) }
        }
    }
}
