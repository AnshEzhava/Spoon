import AppKit
import Observation
import SpoonKit

enum RepoView: Hashable { case localChanges, history }

/// History filter (HIST-06).
struct HistoryFilter: Equatable {
    enum Scope: Equatable { case all, current, refs([String]) }
    var scope: Scope = .all
    var hideRemotes = false
    var hideTags = false

    var arguments: [String] {
        switch scope {
        case .current: return ["HEAD"]
        case .refs(let refs): return refs
        case .all:
            var args = ["--exclude=refs/spoon/*", "--exclude=refs/stash"]
            if hideRemotes { args.append("--exclude=refs/remotes/*") }
            if hideTags { args.append("--exclude=refs/tags/*") }
            return args + ["--all"]
        }
    }
}

/// Everything one open repository tab shows. Reads come from `Repository`; refresh is driven by FSEvents (§4.6).
@MainActor @Observable
final class RepoController {
    let repo: Repository
    let libraryID: UUID
    var name: String { repo.workTree.lastPathComponent }

    var view: RepoView = .history
    var refs: [Ref] = []
    var stashes: [Stash] = []
    var remotes: [Remote] = []
    var status = RepoStatus()
    var operation: RepoOperation?
    var isLocked = false
    var filter = HistoryFilter() { didSet { if filter != oldValue { reloadHistory() } } }

    // History (append-only while streaming; the table reads these flat arrays by index).
    @ObservationIgnored private(set) var commits: [Commit] = []
    @ObservationIgnored private(set) var rows: [GraphRow] = []
    @ObservationIgnored private(set) var indexBySHA: [String: Int] = [:]
    var historyGeneration = 0
    var historyLoading = false
    var historyError: String?
    @ObservationIgnored var onHistoryReset: (() -> Void)?
    @ObservationIgnored var onHistoryAppend: ((Range<Int>) -> Void)?
    @ObservationIgnored var onSelect: (() -> Void)?

    var selectedSHA: String?
    var details = DetailsModel()

    var lastError: String?
    var busy: String?
    @ObservationIgnored var currentTask: Task<Void, Never>?
    @ObservationIgnored lazy var local = LocalChangesModel(controller: self)
    var showIgnored = false
    var worktrees: [Worktree] = []
    var submodules: [Submodule] = []
    var focusCommitToken = 0
    /// `pull.rebase` / `pull.ff` value, for the default pull strategy.
    var pullConfig = ""

    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pendingChange = RepoChange()
    @ObservationIgnored private var lastRefSignature = ""

    init(repo: Repository, libraryID: UUID) {
        self.repo = repo
        self.libraryID = libraryID
    }

    var git: GitRunner { repo.git }
    var headRef: Ref? { refs.first { $0.isHead } }
    var headSHA: String? { status.branch.oid }
    var currentBranch: String? { status.branch.head }
    var refsBySHA: [String: [Ref]] = [:]
    var localBranches: [Ref] { refs.filter { $0.kind == .localBranch } }
    var remoteBranches: [Ref] { refs.filter { $0.kind == .remoteBranch } }
    var tags: [Ref] { refs.filter { $0.kind == .tag } }
    var changeCount: Int { status.entries.filter { $0.kind != .ignored }.count }
    var upstream: Ref? {
        guard let up = headRef?.upstream else { return nil }
        return refs.first { $0.name == up }
    }

    func start() {
        let paths = Set([repo.workTree.path, repo.gitDir.path, repo.commonDir.path]).sorted()
        let work = repo.workTree.path, gitDir = repo.gitDir.path, common = repo.commonDir.path
        watcher = FileWatcher(paths: paths) { [weak self] events, rescan in
            var change = RepoChange.classify(events, workTree: work, gitDir: gitDir, commonDir: common)
            if rescan { change.fullRescan = true; change.state = true }
            MainActor.assumeIsolated { self?.handle(change) }
        }
        refresh(state: true)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        historyTask?.cancel()
        refreshTask?.cancel()
    }

    private func handle(_ change: RepoChange) {
        guard !change.isEmpty else { return }
        pendingChange.state = pendingChange.state || change.state
        pendingChange.paths.formUnion(change.paths)
        pendingChange.fullRescan = pendingChange.fullRescan || change.fullRescan
        // Self-suppression: events during our own mutation coalesce into one refresh after it (§4.6).
        guard busy == nil else { return }
        flushChanges()
    }

    private func flushChanges() {
        let change = pendingChange
        pendingChange = RepoChange()
        guard !change.isEmpty else { return }
        refresh(state: change.state)
    }

    /// Reloads status (always) and refs/stashes/history when repo state changed.
    func refresh(state: Bool = true) {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                async let s = repo.status(ignored: showIgnored)
                if state {
                    async let r = repo.refs()
                    async let st = repo.stashes()
                    async let rm = repo.remotes()
                    async let pc = repo.config("pull.rebase")
                    async let ff = repo.config("pull.ff")
                    async let wt = repo.worktrees()
                    async let sm = repo.submodules()
                    let (refs, stashes, remotes) = try await (r, st, rm)
                    (worktrees, submodules) = await (wt, sm)
                    let (rebase, ffOnly) = await (pc, ff)
                    pullConfig = rebase ?? (ffOnly == "only" ? "ff-only" : ffOnly == nil ? "" : "false")
                    guard !Task.isCancelled else { return }
                    apply(refs: refs)
                    self.stashes = stashes
                    self.remotes = remotes
                }
                let status = try await s
                guard !Task.isCancelled else { return }
                self.status = status
                operation = repo.operationInProgress
                isLocked = repo.isLocked
                if view == .localChanges { local.reload() }
            } catch is CancellationError {
            } catch {
                lastError = "\(error)"
            }
        }
    }

    private func apply(refs: [Ref]) {
        self.refs = refs
        var map: [String: [Ref]] = [:]
        for r in refs { map[r.target, default: []].append(r) }
        refsBySHA = map
        let signature = refs.map { "\($0.name)=\($0.target)" }.joined(separator: "\n") + "|\(repo.headBranch ?? "")"
        if signature != lastRefSignature {
            lastRefSignature = signature
            reloadHistory()
        }
    }

    var mainTip: String? {
        let names = ["refs/heads/main", "refs/heads/master", "refs/heads/trunk", "refs/heads/develop"]
        for n in names { if let r = refs.first(where: { $0.name == n }) { return r.target } }
        return headRef?.target
    }

    func reloadHistory() {
        historyTask?.cancel()
        let previousSelection = selectedSHA
        commits = []
        rows = []
        indexBySHA = [:]
        historyGeneration += 1
        historyLoading = true
        historyError = nil
        onHistoryReset?()
        let generation = historyGeneration
        let box = LayoutBox(mainTip: mainTip)
        let order = AppModel.shared.settings.commitOrder
        let refs = filter.arguments
        let repo = self.repo
        historyTask = Task { [weak self] in
            do {
                try await repo.log(order: order, refs: refs) { [weak self] page in
                    let laid = box.layout(page)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.historyGeneration == generation else { return }
                            self.append(page, laid)
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                // Unborn branch: no commits yet is not an error.
                if self?.status.branch.oid != nil { self?.historyError = "\(error)" }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.historyGeneration == generation else { return }
                    self.historyLoading = false
                    if self.selectedSHA == nil || self.indexBySHA[self.selectedSHA!] == nil {
                        if let prev = previousSelection, self.indexBySHA[prev] != nil { self.select(prev) }
                    }
                }
            }
        }
    }

    private func append(_ page: [Commit], _ laid: [GraphRow]) {
        let start = commits.count
        commits += page
        rows += laid
        for (i, c) in page.enumerated() { indexBySHA[c.sha] = start + i }
        onHistoryAppend?(start..<commits.count)
        if selectedSHA == nil, let head = headSHA, indexBySHA[head] != nil { select(head) }
    }

    func select(_ sha: String?) {
        guard selectedSHA != sha else { return }
        selectedSHA = sha
        if let sha { details.load(sha: sha, in: self) } else { details.clear() }
        onSelect?()
    }

    func reveal(_ ref: Ref) {
        view = .history
        select(ref.target)
    }

    func isUnpushed(_ index: Int) -> Bool {
        // Commits reachable from HEAD but not from upstream show an accent dot (HIST-04).
        unpushed.contains(commits[index].sha)
    }

    func isUnpulled(_ index: Int) -> Bool { unpulled.contains(commits[index].sha) }

    /// Filled lazily per history load from `rev-list` (cheap; bounded by ahead/behind counts).
    @ObservationIgnored var unpushed: Set<String> = []
    @ObservationIgnored var unpulled: Set<String> = []

    func loadSyncMarkers() async {
        guard let up = headRef?.upstream else { unpushed = []; unpulled = []; return }
        async let a = try? git.run(["rev-list", "HEAD", "^\(up)"], in: repo.workTree, background: true)
        async let b = try? git.run(["rev-list", up, "^HEAD"], in: repo.workTree, background: true)
        let (ra, rb) = await (a, b)
        unpushed = Set(ra?.output.split(separator: "\n").map(String.init) ?? [])
        unpulled = Set(rb?.output.split(separator: "\n").map(String.init) ?? [])
    }
}

/// Lane layout runs on the log reader's thread so the main thread only appends.
private final class LayoutBox: @unchecked Sendable {
    private var layout: GraphLayout
    private let lock = NSLock()
    init(mainTip: String?) { layout = GraphLayout(mainTip: mainTip) }
    func layout(_ page: [Commit]) -> [GraphRow] {
        lock.withLock { page.map { layout.place($0) } }
    }
}
