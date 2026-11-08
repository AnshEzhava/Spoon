import AppKit
import SwiftUI
import SpoonKit

/// ⌘P palette (§5.14): every menu command, repositories, groups, branches and files, fuzzy-matched.
@MainActor
final class QuickLaunchPanel: NSPanel {
    private let model = QuickLaunchModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingView(rootView: QuickLaunchView(model: model, close: { [weak self] in self?.orderOut(nil) }))
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.state = .active
        blur.blendingMode = .behindWindow
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor), host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor), host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        contentView = blur
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); orderOut(nil) }

    func present(for window: TabWindowController?, query: String = "") {
        model.reset(window: window)
        model.query = query
        if let frame = window?.window?.frame {
            setFrameOrigin(NSPoint(x: frame.midX - 320, y: frame.maxY - 120 - 420))
        } else {
            center()
        }
        makeKeyAndOrderFront(nil)
    }
}

struct QuickItem: Identifiable {
    enum Kind: String { case command = "Commands", repository = "Repositories", group = "Groups", branch = "Branches", file = "Files", commit = "Commits" }
    let id = UUID()
    var kind: Kind
    var title: String
    var subtitle = ""
    var shortcut = ""
    var symbol: String
    var run: @MainActor () -> Void
}

@MainActor @Observable
final class QuickLaunchModel {
    var query = "" { didSet { selected = 0 } }
    var selected = 0
    @ObservationIgnored weak var window: TabWindowController?
    @ObservationIgnored private var all: [QuickItem] = []
    @ObservationIgnored private var files: [String] = []
    /// Frequency + recency learning (QL-04).
    @ObservationIgnored @AppStorage("quicklaunch.usage") private var usageRaw = ""

    func reset(window: TabWindowController?) {
        self.window = window
        query = ""
        selected = 0
        all = commands() + repositories() + groups() + branches()
        files = []
        if let c = window?.repoController {
            Task {
                files = (try? await c.repo.files(at: "HEAD")) ?? []
            }
        }
    }

    var usage: [String: Int] {
        get { (try? JSONDecoder().decode([String: Int].self, from: Data(usageRaw.utf8))) ?? [:] }
        set { usageRaw = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self) }
    }

    func record(_ item: QuickItem) {
        var u = usage
        u[item.title, default: 0] += 1
        usage = u
    }

    var results: [QuickItem] {
        var q = query
        var kinds: Set<QuickItem.Kind>? = nil
        if let first = q.first {
            switch first {
            case ">": kinds = [.command]
            case "@": kinds = [.branch]
            case "/": kinds = [.file]
            case ":": return commitLookup(String(q.dropFirst()))
            default: break
            }
            if kinds != nil { q.removeFirst() }
        }
        q = q.trimmingCharacters(in: .whitespaces)
        var pool = all
        if kinds?.contains(.file) == true || (!q.isEmpty && kinds == nil) { pool += fileItems(q) }
        if let kinds { pool = pool.filter { kinds.contains($0.kind) } }
        if q.isEmpty {
            let recentRepos = pool.filter { $0.kind == .repository }.prefix(6)
            let u = usage
            let recentCommands = pool.filter { $0.kind == .command && u[$0.title] != nil }.sorted { u[$0.title]! > u[$1.title]! }.prefix(6)
            return kinds == nil ? Array(recentRepos) + Array(recentCommands) + pool.filter { $0.kind == .branch }.prefix(8) : Array(pool.prefix(50))
        }
        let u = usage
        return pool.compactMap { item -> (QuickItem, Int)? in
            guard let s = Fuzzy.score(item.title, q) ?? Fuzzy.score(item.subtitle + " " + item.title, q).map({ $0 - 5 }) else { return nil }
            return (item, s + min(u[item.title] ?? 0, 20))
        }
        .sorted { $0.1 > $1.1 }
        .prefix(60)
        .map(\.0)
    }

    private func fileItems(_ q: String) -> [QuickItem] {
        guard let c = window?.repoController, !q.isEmpty else { return [] }
        return files.lazy.filter { Fuzzy.score($0, q) != nil }.prefix(40).map { path in
            QuickItem(kind: .file, title: path, symbol: "doc") {
                NSWorkspace.shared.activateFileViewerSelecting([c.repo.workTree.appendingPathComponent(path)])
            }
        }
    }

    private func commitLookup(_ prefix: String) -> [QuickItem] {
        guard let c = window?.repoController, !prefix.isEmpty else { return [] }
        return c.commits.lazy.filter { $0.sha.hasPrefix(prefix.lowercased()) }.prefix(20).map { commit in
            QuickItem(kind: .commit, title: commit.subject, subtitle: commit.shortSHA, symbol: "smallcircle.filled.circle") {
                c.view = .history
                c.select(commit.sha)
            }
        }
    }

    private func commands() -> [QuickItem] {
        MainMenu.commands().compactMap { entry in
            let item = entry.item
            guard item.title != "Quick Launch…" else { return nil }
            return QuickItem(kind: .command, title: item.title, subtitle: entry.path, shortcut: Self.shortcut(item), symbol: "command") {
                NSApp.sendAction(item.action!, to: item.target, from: item)
            }
        }
    }

    private func repositories() -> [QuickItem] {
        let lib = AppModel.shared.library
        let scoped = window?.model.scope.flatMap { lib.group($0) }.map { Set($0.members.map(\.repo)) }
        let repos = (lib.recent + lib.repositories.filter { $0.lastOpened == nil })
            .filter { scoped == nil || scoped!.contains($0.id) }
        var seen = Set<UUID>()
        return repos.filter { seen.insert($0.id).inserted }.map { r in
            QuickItem(kind: .repository, title: r.name, subtitle: r.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), symbol: "folder") {
                AppDelegate.shared.openRepo(path: r.path, newTab: NSEvent.modifierFlags.contains(.command))
            }
        }
    }

    private func groups() -> [QuickItem] {
        let lib = AppModel.shared.library
        return lib.groups.flatMap { g -> [QuickItem] in
            let name = lib.path(of: g)
            return [
                QuickItem(kind: .group, title: "Switch to Group \(name)", symbol: "square.stack") { GroupActions.switchTo(g.id) },
                QuickItem(kind: .group, title: "Fetch Group \(name)", symbol: "arrow.down.circle") { GroupActions.run(g.id, pull: false) },
                QuickItem(kind: .group, title: "Pull Group \(name)", symbol: "arrow.down.to.line") { GroupActions.run(g.id, pull: true) },
                QuickItem(kind: .group, title: "Open Group Dashboard \(name)", symbol: "tablecells") { GroupActions.dashboard(g.id) },
            ]
        }
    }

    private func branches() -> [QuickItem] {
        guard let c = window?.repoController else { return [] }
        return (c.localBranches + c.remoteBranches).map { r in
            QuickItem(kind: .branch, title: r.shortName, subtitle: r.kind == .remoteBranch ? "remote" : r.isHead ? "current" : "",
                      symbol: r.kind == .remoteBranch ? "cloud" : "arrow.triangle.branch") {
                RepoActions.checkout(c, ref: r)
            }
        }
    }

    static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var s = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + item.keyEquivalent.uppercased()
    }
}

struct QuickLaunchView: View {
    @Bindable var model: QuickLaunchModel
    var close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            TextField("Search commands, repositories, branches, files…  ( >  @  /  : )", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .padding(14)
                .focused($focused)
                .onSubmit { run(results) }
                .onKeyPress(.downArrow) { model.selected = min(model.selected + 1, results.count - 1); return .handled }
                .onKeyPress(.upArrow) { model.selected = max(model.selected - 1, 0); return .handled }
                .onKeyPress(.escape) {
                    if model.query.isEmpty { close() } else { model.query = "" }
                    return .handled
                }
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                        row(item, highlighted: i == model.selected)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selected = i; run(results) }
                            .listRowBackground(i == model.selected ? Color.accentColor.opacity(0.25) : Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: model.selected) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 640, height: 420)
        .onAppear { focused = true }
    }

    func row(_ item: QuickItem, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
            highlightedTitle(item.title)
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text(item.kind.rawValue).font(.system(size: 10)).foregroundStyle(.tertiary)
            if !item.shortcut.isEmpty { Text(item.shortcut).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }

    func highlightedTitle(_ title: String) -> Text {
        var q = model.query
        if let f = q.first, ">@/:".contains(f) { q.removeFirst() }
        let hits = Fuzzy.matchedIndices(title, q.trimmingCharacters(in: .whitespaces))
        var text = Text("")
        for (i, ch) in title.enumerated() {
            text = text + Text(String(ch)).fontWeight(hits.contains(i) ? .bold : .regular)
        }
        return text.font(.system(size: 13))
    }

    func run(_ results: [QuickItem]) {
        guard model.selected < results.count else { return }
        let item = results[model.selected]
        model.record(item)
        close()
        item.run()
    }
}

