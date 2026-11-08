import Foundation
import SpoonKit

// `spoon` CLI (§3.6). Headless; links SpoonKit only.

func usage() -> Never {
    print("""
    usage: spoon [-C <path>] <command>

      status                  print parsed working-copy status
      [open] [path]           open a repository in Spoon
      group list
      group add <group> <path>…
      group sync <group> [--fetch-only] [--strategy ff-only|rebase|merge] [--jobs N] [--json]
    """)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("spoon: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
if args.first == "-C" {
    guard args.count >= 2 else { usage() }
    directory = URL(fileURLWithPath: args[1], relativeTo: directory).standardizedFileURL
    args.removeFirst(2)
}

func printStatus(_ status: RepoStatus) {
    let b = status.branch
    var line = "On " + (b.head.map { "branch \($0)" } ?? "detached HEAD \(b.oid?.prefix(7) ?? "")")
    if let up = b.upstream { line += " ← \(up) (↑\(b.ahead) ↓\(b.behind))" }
    print(line)
    if b.oid == nil { print("No commits yet") }
    func section(_ title: String, _ entries: [StatusEntry], _ letter: (StatusEntry) -> Character) {
        guard !entries.isEmpty else { return }
        print("\n\(title) (\(entries.count))")
        for e in entries {
            let path = e.originalPath.map { "\($0) → \(e.path)" } ?? e.path
            print("  \(letter(e)) \(path)")
        }
    }
    section("CONFLICTS", status.conflicts) { _ in "!" }
    section("STAGED", status.staged) { $0.index }
    section("UNSTAGED", status.unstaged) { $0.kind == .untracked ? "U" : $0.worktree }
    if status.isClean { print("\nNothing to commit — working tree clean") }
}

let command = args.first ?? "open"
switch command {
case "status":
    do {
        let repo = try await Repository.open(directory)
        printStatus(try await repo.status())
    } catch {
        fail("\(error)")
    }
case "open":
    let path = args.count > 1 ? URL(fileURLWithPath: args[1], relativeTo: directory).standardizedFileURL : directory
    var components = URLComponents()
    components.scheme = "spoon"
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "path", value: path.path)]
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [components.url!.absoluteString]
    try? open.run()
    open.waitUntilExit()
    exit(open.terminationStatus)
case "group":
    await groupCommand(Array(args.dropFirst()))
case "-h", "--help", "help":
    usage()
default:
    // `spoon <path>` opens that path, Fork-style.
    if FileManager.default.fileExists(atPath: command) {
        args.insert("open", at: 0)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        open.arguments = ["-C", directory.path] + args
        try? open.run()
        open.waitUntilExit()
        exit(open.terminationStatus)
    }
    usage()
}

// MARK: spoon group (§3.6)

@MainActor func groupCommand(_ args: [String]) async {
    // ponytail: last writer wins on library.json if the app saves at the same moment; add file locking if that bites.
    let store = JSONStore<Library>(url: JSONStore<Library>.supportDirectory.appendingPathComponent("library.json"), backups: 5)
    var library = store.load() ?? Library()
    switch args.first {
    case "list":
        for g in library.groups.sorted(by: { library.path(of: $0) < library.path(of: $1) }) {
            print("\(library.path(of: g))  (\(g.members.count) repo\(g.members.count == 1 ? "" : "s"))")
        }
    case "add":
        guard args.count >= 3 else { usage() }
        let gid = library.group(named: args[1])?.id ?? library.addGroup(args[1])
        let ids = args.dropFirst(2).map { library.add(path: URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL.path) }
        library.addMembers(ids, to: gid)
        do { try store.save(library) } catch { fail("saving library: \(error)") }
    case "sync":
        guard args.count >= 2, let group = library.group(named: args[1]) else { fail("no group named '\(args.count >= 2 ? args[1] : "")'") }
        var options = group.options
        var action = SyncAction.pull
        var json = false
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--fetch-only": action = .fetch
            case "--json": json = true
            case "--strategy":
                i += 1
                guard i < args.count, let s = SyncStrategy(rawValue: args[i]) else { usage() }
                options.strategy = s
            case "--jobs":
                i += 1
                guard i < args.count, let n = Int(args[i]) else { usage() }
                options.concurrency = n
            default: usage()
            }
            i += 1
        }
        let targets = library.syncTargets(group)
        let names = Dictionary(targets.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        let results = await GroupSync(git: GitRunner(), options: options, title: "Group sync \(group.name)").run(action, targets)
        for (id, r) in results {
            let path = names[id]?.path ?? ""
            if json {
                var obj: [String: Any] = ["path": path, "result": r.kind, "summary": r.summary]
                if case .failed(_, let log) = r { obj["log"] = log }
                if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
            } else {
                print("\(URL(fileURLWithPath: path).lastPathComponent.padding(toLength: 28, withPad: " ", startingAt: 0)) \(r.summary)")
            }
        }
        // Skips aren't failures (§3.8 #10).
        exit(results.contains { $0.1.isFailure } ? 1 : 0)
    default:
        usage()
    }
}
