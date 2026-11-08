import Foundation

// GIT_ASKPASS / SSH_ASKPASS helper (§4.7). Forwards the prompt to the running app over a
// Unix socket and prints the answer. With no app listening it fails, so git fails instead of hanging.
//
// `--credential <action>`: git credential-helper mode. Answers `get` with the signed-in Spoon account
// for the host; prints nothing otherwise, so git carries on as if the helper weren't there.

let env = ProcessInfo.processInfo.environment

func ask(_ request: [String: String]) -> [String: Any]? {
    guard let socketPath = env["SPOON_ASKPASS_SOCKET"], !socketPath.isEmpty else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: Array(socketPath.utf8.prefix(buf.count - 1)))
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }
    var payload = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
    payload.append(10)
    _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        response.append(contentsOf: buf[0..<n])
    }
    return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
}

if let i = CommandLine.arguments.firstIndex(of: "--credential") {
    var fields: [String: String] = [:]
    while let line = readLine(), !line.isEmpty {
        if let eq = line.firstIndex(of: "=") { fields[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
    }
    // store/erase: Spoon manages its tokens itself.
    guard CommandLine.arguments.dropFirst(i + 1).first == "get",
          let reply = ask(["credential": "get", "host": fields["host"] ?? "", "protocol": fields["protocol"] ?? "",
                           "nonce": env["SPOON_ASKPASS_NONCE"] ?? ""]),
          let user = reply["username"] as? String, let pass = reply["password"] as? String else { exit(0) }
    print("username=\(user)\npassword=\(pass)")
    exit(0)
}

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
guard let reply = ask(["prompt": prompt, "repo": env["SPOON_REPO"] ?? FileManager.default.currentDirectoryPath]),
      let answer = reply["answer"] as? String else { exit(1) }
print(answer)
