import AppKit
import SwiftUI
import SpoonKit
@preconcurrency import UserNotifications

/// One group's current or last sync run (§3.3 "Run progress").
@MainActor @Observable
final class GroupRun {
    let groupID: UUID
    var action = SyncAction.pull
    var steps: [UUID: SyncStep] = [:]
    /// Last result per repo, kept after the run for the "Last sync" column.
    var results: [UUID: RepoSyncResult] = [:]
    var lastRun: [UUID] = []
    var paths: [UUID: URL] = [:]
    var running = false
    var start = Date()
    var end: Date?
    @ObservationIgnored var task: Task<Void, Never>?

    init(groupID: UUID) { self.groupID = groupID }

    var current: UUID? {
        lastRun.first { id in
            switch steps[id] {
            case .preflight, .fetching, .waitingForAuth, .integrating: true
            default: false
            }
        }
    }
    var doneCount: Int { lastRun.count { if case .done = steps[$0] { true } else { false } } }

    var summary: String {
        let rs = lastRun.compactMap { results[$0] }
        var parts: [String] = []
        func add(_ n: Int, _ label: String) { if n > 0 || label == "failed" { parts.append("\(n) \(label)") } }
        add(rs.count { if case .updated = $0 { true } else { false } }, "updated")
        add(rs.count { if case .fetched = $0 { true } else { false } }, "fetched")
        add(rs.count { if case .upToDate = $0 { true } else { false } }, "up to date")
        add(rs.count(where: \.isSkip), "skipped")
        add(rs.count { $0 == .cancelled }, "cancelled")
        add(rs.count(where: \.isFailure), "failed")
        return parts.joined(separator: " · ")
    }
}

@MainActor @Observable
final class GroupRuns {
    static let shared = GroupRuns()
    var runs: [UUID: GroupRun] = [:]

    func run(for group: UUID) -> GroupRun {
        if let r = runs[group] { return r }
        let r = GroupRun(groupID: group)
        runs[group] = r
        return r
    }

    /// Runs `action` over the group's members (or just `only`), in stored order.
    func start(_ groupID: UUID, _ action: SyncAction, only: Set<UUID>? = nil) {
        let lib = AppModel.shared.library
        guard let group = lib.group(groupID) else { return }
        let run = run(for: groupID)
        guard !run.running else { NSSound.beep(); return }
        let targets = lib.syncTargets(group).filter { only?.contains($0.id) ?? true }
        guard !targets.isEmpty else { return }
        run.action = action
        run.lastRun = targets.map(\.id)
        run.paths = Dictionary(targets.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        for t in targets { run.steps[t.id] = .queued }
        run.running = true
        run.start = Date()
        run.end = nil
        let name = lib.path(of: group)
        let title = "\(action == .pull ? "Pull" : "Fetch") group \(name)"
        let activity = AppModel.shared.activity
        let opID = activity.begin(title, repo: URL(fileURLWithPath: name)) { [weak run] in run?.task?.cancel() }
        let options = group.options
        run.task = Task {
            var sync = GroupSync(git: await AppModel.shared.git(), options: options, title: title)
            sync.authPending = { AskpassServer.isPending($0) }
            let results = await CurrentOperation.$id.withValue(opID) {
                await sync.run(action, targets) { id, step in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            run.steps[id] = step
                            if case .done(let r) = step { run.results[id] = r }
                        }
                    }
                }
            }
            // Step callbacks are queued on main ahead of this; finish after them.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    run.running = false
                    run.end = Date()
                    let failed = results.contains { $0.1.isFailure }
                    activity.end(opID, failed: failed)
                    RepoStatusCache.shared.refresh(lib.members(of: group), force: true)
                    for c in NSApp.windows.compactMap({ ($0.windowController as? TabWindowController)?.repoController })
                    where targets.contains(where: { $0.path.path == c.repo.workTree.path }) { c.refresh(state: true) }
                    let changed = results.contains { if case .updated = $0.1 { true } else if case .fetched(let n) = $0.1 { n > 0 } else { false } }
                    if (changed || failed) && !NSApp.isActive { Notifier.post(title: title, body: run.summary, group: groupID) }
                }
            }
        }
    }

    func cancel(_ groupID: UUID) { runs[groupID]?.task?.cancel() }

    /// "Undo this sync" (§3.4): only repos still exactly where the sync left them.
    func undo(_ groupID: UUID) {
        guard let run = runs[groupID], !run.running else { return }
        let entries = run.lastRun.compactMap { id in run.results[id].map { (path: run.paths[id]!, result: $0) } }
        Task {
            let leftAlone = await GroupSync.undo(entries, git: await AppModel.shared.git())
            for id in run.lastRun where !leftAlone.contains(run.paths[id]!) {
                if case .updated = run.results[id] { run.results[id] = nil; run.steps[id] = nil }
            }
            if let lib = Optional(AppModel.shared.library), let g = lib.group(groupID) { RepoStatusCache.shared.refresh(lib.members(of: g), force: true) }
            if !leftAlone.isEmpty {
                let a = NSAlert()
                a.messageText = "\(leftAlone.count) repositor\(leftAlone.count == 1 ? "y was" : "ies were") left alone"
                a.informativeText = "They changed after the sync:\n" + leftAlone.map(\.lastPathComponent).joined(separator: "\n")
                a.runModal()
            }
        }
    }
}

/// One summary notification per group run (§3.5).
@MainActor
enum Notifier {
    static func post(title: String, body: String, group: UUID) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["group": group.uuidString]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

@MainActor
enum GroupActions {
    // ponytail: no scoped windows yet (GRP-09, P1); switching shows the group's dashboard.
    static func switchTo(_ id: UUID) { dashboard(id) }

    static func run(_ id: UUID, pull: Bool) {
        GroupRuns.shared.start(id, pull ? .pull : .fetch)
        dashboard(id)
    }

    static func dashboard(_ id: UUID) {
        let home = AppDelegate.shared.home()
        home.model.homeGroup = id
    }

    /// No group in context: let the user pick one in Quick Launch.
    static func pickAndRun(pull: Bool?) {
        AppDelegate.shared.showQuickLaunch(query: pull == nil ? "Open Group Dashboard " : pull! ? "Pull Group " : "Fetch Group ")
    }
}

// MARK: Dashboard (§3.3)

struct GroupDashboard: View {
    let groupID: UUID
    var open: (LibraryRepo) -> Void
    var model = AppModel.shared
    var cache = RepoStatusCache.shared
    var runs = GroupRuns.shared
    @State private var chip = Chip.all
    @State private var filter = ""
    @State private var selection = Set<UUID>()

    enum Chip: String, CaseIterable { case all = "All", dirty = "Dirty", behind = "Behind", diverged = "Diverged", failed = "Failed", skipped = "Skipped", noUpstream = "No upstream" }

    struct Row: Identifiable {
        var id: UUID { repo.id }
        var repo: LibraryRepo
        var member: GroupMember
        var index: Int
    }

    var body: some View {
        if let group = model.library.group(groupID) {
            let run = runs.run(for: groupID)
            let all = allRows(group)
            VStack(alignment: .leading, spacing: 10) {
                header(group, run, all)
                table(group, run, rows(all, run))
                footer(run)
            }
            .padding(16)
            .onAppear { cache.refresh(all.map(\.repo), force: true) }
        } else {
            ContentUnavailableView("Group not found", systemImage: "square.stack")
        }
    }

    func allRows(_ g: RepoGroup) -> [Row] {
        g.members.enumerated().compactMap { i, m in model.library.repo(m.repo).map { Row(repo: $0, member: m, index: i) } }
    }

    func matches(_ chip: Chip, _ r: Row, _ run: GroupRun) -> Bool {
        let e = cache.entries[r.id]
        switch chip {
        case .all: return true
        case .dirty: return (e?.changes ?? 0) > 0
        case .behind: return (e?.behind ?? 0) > 0
        case .diverged: return (e?.ahead ?? 0) > 0 && (e?.behind ?? 0) > 0
        case .failed: return run.results[r.id]?.isFailure == true
        case .skipped: return run.results[r.id]?.isSkip == true
        case .noUpstream: return e != nil && e?.upstream == nil
        }
    }

    func rows(_ all: [Row], _ run: GroupRun) -> [Row] {
        all.filter { matches(chip, $0, run) && (filter.isEmpty || Fuzzy.score($0.repo.name, filter) != nil) }
    }

    @ViewBuilder func header(_ g: RepoGroup, _ run: GroupRun, _ all: [Row]) -> some View {
        HStack(spacing: 8) {
            Text(model.library.path(of: g).replacingOccurrences(of: "/", with: " / ")).font(.system(size: 15, weight: .bold))
            Spacer()
            Button { GroupRuns.shared.start(groupID, .fetch) } label: { Label("Fetch All", systemImage: "arrow.down.circle") }
                .disabled(run.running)
            Menu {
                ForEach(SyncStrategy.allCases, id: \.self) { s in
                    Toggle(s.title, isOn: Binding(get: { g.options.strategy == s },
                                                  set: { _ in model.updateLibrary { $0.updateGroup(groupID) { $0.options.strategy = s } } }))
                }
                Divider()
                Toggle("Autostash local changes", isOn: Binding(get: { g.options.localChanges == .autostash },
                                                                 set: { on in model.updateLibrary { $0.updateGroup(groupID) { $0.options.localChanges = on ? .autostash : .skip } } }))
                Toggle("Fetch all remotes", isOn: Binding(get: { g.options.fetchAllRemotes },
                                                          set: { on in model.updateLibrary { $0.updateGroup(groupID) { $0.options.fetchAllRemotes = on } } }))
                Toggle("Fast-forward other branches", isOn: Binding(get: { g.options.fastForwardOtherBranches },
                                                                     set: { on in model.updateLibrary { $0.updateGroup(groupID) { $0.options.fastForwardOtherBranches = on } } }))
                Toggle("Stop on first failure", isOn: Binding(get: { g.options.stopOnFailure },
                                                              set: { on in model.updateLibrary { $0.updateGroup(groupID) { $0.options.stopOnFailure = on } } }))
            } label: {
                Label("Pull All · \(g.options.strategy.rawValue)", systemImage: "arrow.down.to.line")
            } primaryAction: {
                GroupRuns.shared.start(groupID, .pull)
            }
            .fixedSize()
            .disabled(run.running)
            Button { GroupRuns.shared.cancel(groupID) } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!run.running)
                .keyboardShortcut(".", modifiers: .command)
        }
        .controlSize(.large)
        HStack(spacing: 6) {
            ForEach(Chip.allCases, id: \.self) { c in
                let n = all.count { matches(c, $0, run) }
                if c == .all || n > 0 {
                    Button("\(c.rawValue) \(c == .all ? "" : "\(n)")") { chip = c }
                        .buttonStyle(.bordered).tint(chip == c ? .accentColor : nil)
                        .controlSize(.small)
                }
            }
            Spacer()
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
            Button { cache.refresh(all.map(\.repo), force: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh local status (no network)")
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    func table(_ g: RepoGroup, _ run: GroupRun, _ rows: [Row]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("") { r in
                Toggle("", isOn: Binding(get: { !r.member.excluded }, set: { on in setExcluded(r, !on) })).labelsHidden()
            }
            .width(24)
            TableColumn("Repository") { r in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if !r.repo.exists { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        Text(r.repo.name).fontWeight(.medium)
                    }
                    Text(r.repo.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .width(min: 140, ideal: 190)
            TableColumn("Branch") { r in Text(cache.entries[r.id]?.branch.map { "⎇ \($0)" } ?? (r.repo.exists ? "detached" : "—")) }
            TableColumn("Changes") { r in changes(r) }.width(min: 60, ideal: 70)
            TableColumn("↑ / ↓") { r in
                let e = cache.entries[r.id]
                Text(e?.upstream == nil ? "— / —" : "\(e!.ahead) / \(e!.behind)").monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Fetched") { r in Text(cache.entries[r.id]?.fetched.map { Format.age($0) } ?? "never").foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80)
            TableColumn("Last commit") { r in
                let e = cache.entries[r.id]
                Text(e?.lastCommit.map { "\(Format.age($0)) · \(e?.author ?? "")" } ?? "").foregroundStyle(.secondary).lineLimit(1)
                    .help(e?.author ?? "")
            }
            .width(min: 100, ideal: 150)
            TableColumn("Last sync") { r in lastSync(r, run) }.width(min: 170, ideal: 230)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if picked.count == 1, let r = picked.first {
                Button("Open") { open(r.repo) }
                if !r.repo.exists { Button("Locate…") { locate(r.repo) } }
                Divider()
            }
            Button("Fetch") { GroupRuns.shared.start(groupID, .fetch, only: ids) }.disabled(run.running)
            Button("Pull") { GroupRuns.shared.start(groupID, .pull, only: ids) }.disabled(run.running)
            Divider()
            if picked.count == 1, let r = picked.first {
                Button("Open in Terminal") { External.openTerminal(r.repo.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.repo.url]) }
                Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.repo.path, forType: .string) }
                Divider()
                Button(r.member.excluded ? "Include in Sync" : "Exclude from Sync") { setExcluded(r, !r.member.excluded) }
                Button("Move Up") { move(r, by: -1) }.disabled(r.index == 0)
                Button("Move Down") { move(r, by: 1) }.disabled(r.index == g.members.count - 1)
            }
            Button("Remove from Group") {
                model.updateLibrary { $0.updateGroup(groupID) { $0.members.removeAll { ids.contains($0.repo) } } }
            }
        } primaryAction: { ids in
            if let id = ids.first, let r = model.library.repo(id) { r.exists ? open(r) : locate(r) }
        }
    }

    @ViewBuilder func changes(_ r: Row) -> some View {
        if !r.repo.exists { Text("missing").foregroundStyle(.orange) }
        else if let e = cache.entries[r.id] {
            if let op = e.operation { Text("\(op.title.lowercased()) in progress").foregroundStyle(.orange) }
            else if e.changes > 0 { Text("● \(e.changes)").foregroundStyle(Color.accentColor) }
            else { Text("clean").foregroundStyle(.secondary) }
        } else { Text("…").foregroundStyle(.tertiary) }
    }

    @ViewBuilder func lastSync(_ r: Row, _ run: GroupRun) -> some View {
        switch run.steps[r.id] {
        case .queued?: Label("queued", systemImage: "clock").foregroundStyle(.secondary)
        case .preflight?: Label("preflight", systemImage: "magnifyingglass").foregroundStyle(.secondary)
        case .fetching(let p)?: Label(p.isEmpty ? "fetching…" : "fetching \(p)", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .waitingForAuth?: Label("Waiting for authentication", systemImage: "key.fill").foregroundStyle(.orange)
        case .integrating?: Label("integrating…", systemImage: "arrow.triangle.merge").foregroundStyle(.secondary)
        default:
            if r.member.excluded { Text("excluded").foregroundStyle(.tertiary) }
            else if let res = run.results[r.id] { resultLabel(res) }
            else { Text("") }
        }
    }

    func resultLabel(_ r: RepoSyncResult) -> some View {
        let (icon, color): (String, Color) = switch r {
        case .updated: ("checkmark.circle.fill", .green)
        case .upToDate, .fetched: ("checkmark.circle", .secondary)
        case .skipped: ("forward.end.circle", .orange)
        case .failed: ("xmark.circle.fill", .red)
        case .cancelled: ("stop.circle", .secondary)
        }
        var help = r.summary
        if case .failed(_, let log) = r { help = log }
        return Label(r.summary, systemImage: icon).foregroundStyle(color).help(help)
    }

    @ViewBuilder func footer(_ run: GroupRun) -> some View {
        HStack {
            if run.running {
                ProgressView(value: Double(run.doneCount), total: Double(max(run.lastRun.count, 1))).frame(width: 120)
                let name = run.current.flatMap { model.library.repo($0)?.name } ?? ""
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(run.action == .pull ? "Pulling" : "Fetching") \(min(run.doneCount + 1, run.lastRun.count)) of \(run.lastRun.count)"
                         + (name.isEmpty ? "" : " — \(name)") + " (\(Int(Date().timeIntervalSince(run.start))) s)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { GroupRuns.shared.cancel(groupID) }
            } else if run.end != nil {
                Text(run.summary).foregroundStyle(.secondary)
                Spacer()
                let retry = run.lastRun.filter { run.results[$0]?.needsRetry == true }
                Button("Retry Failed & Skipped") { GroupRuns.shared.start(groupID, run.action, only: Set(retry)) }.disabled(retry.isEmpty)
                Button("Undo This Sync") { GroupRuns.shared.undo(groupID) }
                    .disabled(!run.lastRun.contains { if case .updated = run.results[$0] { true } else { false } })
                Button("Show Log") { AppDelegate.shared.showActivity(nil) }
            } else {
                Text("Status is local; Fetch All updates remote-tracking data.").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.system(size: 12))
    }

    func setExcluded(_ r: Row, _ excluded: Bool) {
        model.updateLibrary { $0.updateGroup(groupID) { g in
            if let i = g.members.firstIndex(where: { $0.repo == r.id }) { g.members[i].excluded = excluded }
        } }
    }

    // ponytail: Move Up/Down instead of drag-to-reorder; add Table row drag when it's missed.
    func move(_ r: Row, by delta: Int) {
        model.updateLibrary { $0.updateGroup(groupID) { g in g.members.swapAt(r.index, r.index + delta) } }
    }

    func locate(_ r: LibraryRepo) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Locate \(r.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateLibrary { lib in
            if let i = lib.repositories.firstIndex(where: { $0.id == r.id }) { lib.repositories[i].path = url.path }
        }
    }
}

/// Home's left column: All Repositories and the group tree (GRP-01).
struct GroupSidebar: View {
    @Binding var selection: UUID?
    var model = AppModel.shared
    var runs = GroupRuns.shared
    static let all = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    var body: some View {
        List(selection: Binding(get: { selection ?? Self.all }, set: { selection = $0 == Self.all ? nil : $0 })) {
            Label("All Repositories", systemImage: "tray.full").tag(Self.all)
            Section("Groups") {
                OutlineGroup(tree(nil), children: \.children) { node in
                    HStack {
                        Label(node.group.name, systemImage: node.group.symbol ?? "square.stack")
                        Spacer()
                        if runs.runs[node.group.id]?.running == true { ProgressView().controlSize(.mini) }
                        if !node.group.members.isEmpty { Text("\(node.group.members.count)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(node.group.id)
                    .contextMenu { menu(node.group) }
                    .dropDestination(for: URL.self) { urls, _ in
                        model.updateLibrary { lib in lib.addMembers(urls.map { lib.add(path: $0.path) }, to: node.group.id) }
                        return true
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { AppActions.newGroup(with: []) } label: { Label("New Group", systemImage: "plus") }
                .buttonStyle(.borderless).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    struct Node: Identifiable {
        var group: RepoGroup
        var children: [Node]?
        var id: UUID { group.id }
    }

    func tree(_ parent: UUID?) -> [Node] {
        model.library.children(of: parent).map { g in
            let kids = tree(g.id)
            return Node(group: g, children: kids.isEmpty ? nil : kids)
        }
    }

    @ViewBuilder func menu(_ g: RepoGroup) -> some View {
        Button("Fetch Group") { GroupRuns.shared.start(g.id, .fetch); selection = g.id }
        Button("Pull Group") { GroupRuns.shared.start(g.id, .pull); selection = g.id }
        Divider()
        Button("Rename…") {
            guard let name = RepoActions.prompt("Rename Group", value: g.name, action: "Rename") else { return }
            model.updateLibrary { $0.updateGroup(g.id) { $0.name = name } }
        }
        Button("New Subgroup…") {
            guard let name = RepoActions.prompt("New Subgroup of \(g.name)", value: "", action: "Create") else { return }
            model.updateLibrary { _ = $0.addGroup(name, parent: g.id) }
        }
        Divider()
        Button("Delete Group…") {
            let a = NSAlert()
            a.messageText = "Delete group \(g.name)?"
            a.informativeText = "Its subgroups are deleted too. Repositories stay in Spoon."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
            if selection == g.id { selection = nil }
            model.updateLibrary { $0.removeGroup(g.id) }
        }
    }
}
