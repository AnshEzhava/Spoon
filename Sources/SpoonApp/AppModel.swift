import AppKit
import Observation
import SpoonKit

/// App-wide state: the library, the git runner, and the activity log.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var library: Library
    let activity = ActivityLog()
    @ObservationIgnored let store = JSONStore<Library>(url: JSONStore<Library>.supportDirectory.appendingPathComponent("library.json"), backups: 5)
    @ObservationIgnored let stateStore = JSONStore<WindowState>(url: JSONStore<WindowState>.supportDirectory.appendingPathComponent("state.json"))
    @ObservationIgnored let settingsStore = JSONStore<Settings>(url: JSONStore<Settings>.supportDirectory.appendingPathComponent("settings.json"))
    var settings: Settings { didSet { try? settingsStore.save(settings) } }

    /// Login-shell resolution can take up to 3 s, so it never blocks launch (§4.8).
    @ObservationIgnored private let gitTask: Task<GitRunner, Never>

    private init() {
        library = store.load() ?? Library()
        settings = settingsStore.load() ?? Settings()
        let activity = self.activity
        gitTask = Task.detached {
            var runner = GitRunner()
            runner.environment["SPOON_ASKPASS_SOCKET"] = AskpassServer.socketPath
            runner.environment["SPOON_ASKPASS_NONCE"] = AskpassServer.nonce
            runner.dynamicConfig = { Accounts.gitConfig() }
            runner.onRecord = { record in
                let op = CurrentOperation.id
                Task { @MainActor in activity.add(record, to: op) }
            }
            return runner
        }
    }

    func git() async -> GitRunner { await gitTask.value }

    func saveLibrary() {
        do { try store.save(library) } catch { NSLog("Spoon: saving library failed: \(error)") }
    }

    func updateLibrary(_ body: (inout Library) -> Void) {
        body(&library)
        saveLibrary()
    }
}

/// Persisted preferences (§8). Human-readable JSON.
struct Settings: Codable, Equatable {
    var commitOrder: CommitOrder = .date
    var diffSideBySide = false
    var diffContext = 3
    var ignoreWhitespace = false
    var showInvisibles = false
    var wrapLines = false
    var autoFetchMinutes = 10
    var subjectSoftLimit = 50
    var subjectHardLimit = 72
    var pushAfterCommit = false
    var sourceFolders: [String] = []
    var terminalApp = "Terminal"
    var editorApp = ""
    var cmdNumberSelectsTabs = false
    var verticalLayout = false

    init() {}
    init(from decoder: Decoder) throws {
        // Missing keys fall back to defaults so old files keep loading.
        let defaults = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        commitOrder = v(.commitOrder, defaults.commitOrder)
        diffSideBySide = v(.diffSideBySide, defaults.diffSideBySide)
        diffContext = v(.diffContext, defaults.diffContext)
        ignoreWhitespace = v(.ignoreWhitespace, defaults.ignoreWhitespace)
        showInvisibles = v(.showInvisibles, defaults.showInvisibles)
        wrapLines = v(.wrapLines, defaults.wrapLines)
        autoFetchMinutes = v(.autoFetchMinutes, defaults.autoFetchMinutes)
        subjectSoftLimit = v(.subjectSoftLimit, defaults.subjectSoftLimit)
        subjectHardLimit = v(.subjectHardLimit, defaults.subjectHardLimit)
        pushAfterCommit = v(.pushAfterCommit, defaults.pushAfterCommit)
        sourceFolders = v(.sourceFolders, defaults.sourceFolders)
        terminalApp = v(.terminalApp, defaults.terminalApp)
        editorApp = v(.editorApp, defaults.editorApp)
        cmdNumberSelectsTabs = v(.cmdNumberSelectsTabs, defaults.cmdNumberSelectsTabs)
        verticalLayout = v(.verticalLayout, defaults.verticalLayout)
    }
}

/// Open windows and their tabs, restored on relaunch (REPO-09).
struct WindowState: Codable {
    struct Window: Codable { var tabs: [String?]; var selected: Int }
    var windows: [Window] = []
}

/// Ring buffer of git invocations for the Activity Manager (§5.16).
@MainActor @Observable
final class ActivityLog {
    struct Operation: Identifiable {
        let id = UUID()
        var title: String
        var repo: String
        var start = Date()
        var end: Date?
        var failed = false
        var background = false
        var records: [ActivityRecord] = []
        var cancel: (() -> Void)?
        var isRunning: Bool { end == nil }
    }

    private(set) var operations: [Operation] = []
    private(set) var records: [ActivityRecord] = []

    /// `op` comes from the `CurrentOperation.id` task-local of the task that ran git.
    func add(_ r: ActivityRecord, to op: UUID?) {
        records.append(r)
        if records.count > 500 { records.removeFirst(records.count - 500) }
        if let op, let i = operations.firstIndex(where: { $0.id == op }) { operations[i].records.append(r) }
    }

    func begin(_ title: String, repo: URL, background: Bool = false, cancel: (() -> Void)? = nil) -> UUID {
        let op = Operation(title: title, repo: repo.path, background: background, cancel: cancel)
        operations.insert(op, at: 0)
        if operations.count > 500 { operations.removeLast() }
        return op.id
    }

    func end(_ id: UUID, failed: Bool) {
        guard let i = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[i].end = Date()
        operations[i].failed = failed
        operations[i].cancel = nil
    }

    func running(in repo: URL) -> Operation? {
        operations.first { $0.repo == repo.path && $0.isRunning && !$0.background }
    }
}

/// Ties git invocations to the Activity operation that ran them, across actor hops and `mutate` tasks.
enum CurrentOperation {
    @TaskLocal static var id: UUID?
}
