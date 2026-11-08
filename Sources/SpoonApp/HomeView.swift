import AppKit
import SwiftUI
import SpoonKit

/// Local status for Home rows, read lazily with `--no-optional-locks` (never touches the network).
@MainActor @Observable
final class RepoStatusCache {
    static let shared = RepoStatusCache()
    struct Entry {
        var branch: String?; var changes: Int; var ahead: Int; var behind: Int; var operation: RepoOperation?
        var upstream: String?
        /// Age of the remote-tracking data: FETCH_HEAD's mtime.
        var fetched: Date?
        var lastCommit: Date?
        var author: String?
    }
    var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []

    func refresh(_ repos: [LibraryRepo], force: Bool = false) {
        let todo = repos.filter { r in r.exists && !inFlight.contains(r.id) && (force || entries[r.id] == nil) }
        guard !todo.isEmpty else { return }
        inFlight.formUnion(todo.map(\.id))
        Task {
            let git = await AppModel.shared.git()
            await withTaskGroup(of: (UUID, Entry?).self) { group in
                var it = todo.makeIterator()
                func next() -> Bool {
                    guard let r = it.next() else { return false }
                    group.addTask {
                        guard let repo = try? await Repository.open(r.url, git: git), let s = try? await repo.status() else { return (r.id, nil) }
                        var e = Entry(branch: s.branch.head, changes: s.entries.count { $0.kind != .ignored },
                                      ahead: s.branch.ahead, behind: s.branch.behind, operation: repo.operationInProgress, upstream: s.branch.upstream)
                        e.fetched = try? FileManager.default.attributesOfItem(atPath: repo.commonDir.appendingPathComponent("FETCH_HEAD").path)[.modificationDate] as? Date
                        if let log = try? await git.run(["log", "-1", "--format=%ct%x00%an"], in: repo.workTree, background: true, check: false) {
                            let f = log.output.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
                            if f.count == 2 { e.lastCommit = Double(f[0]).map { Date(timeIntervalSince1970: $0) }; e.author = String(f[1]) }
                        }
                        return (r.id, e)
                    }
                    return true
                }
                for _ in 0..<6 { _ = next() }
                for await (id, entry) in group {
                    inFlight.remove(id)
                    if let entry { entries[id] = entry }
                    _ = next()
                }
            }
        }
    }
}

struct HomeView: View {
    @Bindable var window: WindowModel
    var open: (LibraryRepo) -> Void
    var model = AppModel.shared
    var cache = RepoStatusCache.shared
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\LibraryRepo.name)]

    var body: some View {
        HSplitView {
            GroupSidebar(selection: $window.homeGroup)
                .frame(minWidth: 180, maxWidth: 240)
            if let g = window.homeGroup {
                GroupDashboard(groupID: g, open: open).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                library.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { AppActions.addExisting() } label: { Label("Add Existing…", systemImage: "folder.badge.plus") }
                    .help("Add a repository already on this Mac. Picking a folder of projects finds the repositories inside it.")
                Button { AppActions.clone(nil) } label: { Label("Clone…", systemImage: "square.and.arrow.down") }
                Button { AppActions.initRepo(nil) } label: { Label("New…", systemImage: "plus.square") }
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            .controlSize(.large)

            if !model.library.recent.isEmpty {
                Text("RECENT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.library.recent) { r in
                            Button { open(r) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).font(.system(size: 13, weight: .semibold))
                                    Text(cache.entries[r.id]?.branch.map { "⎇ \($0)" } ?? " ").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .frame(width: 140, alignment: .leading)
                                .padding(10)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Text("ALL REPOSITORIES (\(model.library.repositories.count))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Table(rows, selection: $window.homeSelection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { r in
                    HStack {
                        if !r.exists { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Missing") }
                        Text(r.name).fontWeight(.medium)
                    }
                }
                TableColumn("Path", value: \.path) { r in
                    Text(r.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                TableColumn("Groups") { r in
                    Text(model.library.groups(containing: r.id).map(\.name).joined(separator: ", ")).foregroundStyle(.secondary)
                }
                TableColumn("Branch") { r in Text(cache.entries[r.id]?.branch ?? (r.exists ? "" : "—")) }
                TableColumn("Status") { r in statusText(r) }
                TableColumn("Last opened") { r in Text(Format.age(r.lastOpened)).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                let repos = ids.compactMap { model.library.repo($0) }
                if repos.count == 1, let r = repos.first {
                    Button("Open") { open(r) }
                    if !r.exists { Button("Locate…") { locate(r) } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.path, forType: .string) }
                }
                if !model.library.groups.isEmpty {
                    Menu("Add to Group") {
                        ForEach(model.library.groups) { g in
                            Button(model.library.path(of: g)) { model.updateLibrary { $0.addMembers(repos.map(\.id), to: g.id) } }
                        }
                    }
                }
                Button("New Group from Selection…") { AppActions.newGroup(with: repos.map(\.id)) }
                Divider()
                Button("Remove from Spoon") { model.updateLibrary { lib in repos.forEach { lib.removeRepo($0.id) } } }
            } primaryAction: { ids in
                if let id = ids.first, let r = model.library.repo(id) { r.exists ? open(r) : locate(r) }
            }
        }
        .padding(16)
        .onAppear { cache.refresh(model.library.repositories) }
        .onChange(of: model.library.repositories.count) { _, _ in cache.refresh(model.library.repositories) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in AppActions.addExisting([url]) }
                }
            }
            return true
        }
    }

    var rows: [LibraryRepo] {
        let list = filter.isEmpty ? model.library.repositories
            : model.library.repositories.filter { Fuzzy.score($0.name, filter) != nil || $0.path.localizedCaseInsensitiveContains(filter) }
        return list.sorted(using: sortOrder)
    }

    @ViewBuilder
    func statusText(_ r: LibraryRepo) -> some View {
        if !r.exists { Text("Missing").foregroundStyle(.orange) }
        else if let e = cache.entries[r.id] {
            HStack(spacing: 6) {
                if let op = e.operation { Text("\(op.title) in progress").foregroundStyle(.orange) }
                else if e.changes > 0 { Text("● \(e.changes)").foregroundStyle(Color.accentColor) } else { Text("clean").foregroundStyle(.secondary) }
                if e.ahead > 0 || e.behind > 0 { Text("↑\(e.ahead) ↓\(e.behind)").monospacedDigit().foregroundStyle(.secondary) }
            }
        } else { Text("…").foregroundStyle(.tertiary) }
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

struct ScanResults: Identifiable {
    let id = UUID()
    let root: URL
    let found: [URL]
}

/// Review repos found by a scan; optionally create groups mirroring subfolders (GRP-06).
struct ScanSheet: View {
    let results: ScanResults
    @Environment(\.dismissSheet) private var done
    @State private var checked: Set<URL> = []
    @State private var createGroups = false
    private var model: AppModel { AppModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Found \(results.found.count) repositor\(results.found.count == 1 ? "y" : "ies") in “\(results.root.lastPathComponent)”")
                .font(.system(size: 14, weight: .bold))
            Text(results.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary)
            List(results.found, id: \.self) { url in
                Toggle(isOn: Binding(get: { checked.contains(url) }, set: { on in if on { checked.insert(url) } else { checked.remove(url) } })) {
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                        Text(url.path.replacingOccurrences(of: results.root.path + "/", with: "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.library.repo(path: url.path) != nil)
            }
            .frame(minHeight: 260)
            Toggle("Create groups from folders", isOn: $createGroups)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done() }.keyboardShortcut(.cancelAction)
                Button("Add \(checked.count) Repositories") { add(); done() }
                    .keyboardShortcut(.defaultAction).disabled(checked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { checked = Set(results.found.filter { model.library.repo(path: $0.path) == nil }) }
    }

    func add() {
        var ids: [UUID] = []
        defer {
            let home = AppDelegate.shared.home()
            home.model.homeGroup = nil
            home.model.homeSelection = Set(ids)
        }
        model.updateLibrary { lib in
            let rootName = results.root.lastPathComponent
            for url in results.found where checked.contains(url) {
                let id = lib.add(path: url.path)
                ids.append(id)
                guard createGroups else { continue }
                let rel = url.deletingLastPathComponent().path.replacingOccurrences(of: results.root.path, with: "")
                let groupPath = ([rootName] + rel.split(separator: "/").map(String.init)).joined(separator: "/")
                let gid = lib.addGroup(groupPath)
                lib.addMembers([id], to: gid)
            }
        }
    }
}
