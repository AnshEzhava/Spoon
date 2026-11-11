import AppKit
import SwiftUI
import SpoonKit

/// Re-runs `apply` whenever an observed property it read changes.
@MainActor func track(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking { apply() } onChange: { Task { @MainActor in track(apply) } }
}

@MainActor @Observable
final class WindowModel {
    var repo: RepoController?
    /// Scoped window (GRP-09): tabs, Quick Launch and Home show only this group.
    var scope: UUID?
    /// Group whose dashboard Home shows; nil = all repositories.
    var homeGroup: UUID?
    /// Selected rows in Home's repository table; set to highlight newly added repos.
    var homeSelection = Set<UUID>()
}

/// One window tab: Home, or one repository (§5.2, §5.4). Native NSWindow tabbing.
@MainActor
final class TabWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let model = WindowModel()
    var repoController: RepoController? { model.repo }
    private var repoVC: RepoViewController?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "spoon"
        window.titleVisibility = .hidden
        window.setFrameAutosaveName("SpoonWindow")
        window.minSize = NSSize(width: 760, height: 480)
        super.init(window: window)
        window.delegate = self
        // Bump when default items change: an autosaved layout never picks up new defaults.
        let toolbar = NSToolbar(identifier: "main.3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        showHome()
    }
    required init?(coder: NSCoder) { fatalError() }

    var tabPath: String? { repoController?.repo.workTree.path }

    func showHome() {
        repoController?.stop()
        model.repo = nil
        repoVC = nil
        window?.title = "Home"
        window?.tab.title = "Home"
        let home = NSHostingController(rootView: HomeView(window: model, open: { [weak self] r in self?.open(r) })
            .frame(minWidth: 700, minHeight: 400))
        home.sizingOptions = []
        setContent(home)
    }

    func open(_ entry: LibraryRepo) {
        Task { await open(path: entry.path) }
    }

    func open(path: String) async {
        let app = AppModel.shared
        do {
            let repo = try await Repository.open(URL(fileURLWithPath: path), git: await app.git())
            let id = app.library.add(path: repo.workTree.path)
            app.library.touch(id)
            app.saveLibrary()
            show(RepoController(repo: repo, libraryID: id))
        } catch {
            presentError(title: "Couldn't open repository", message: "\(error)")
        }
    }

    private func show(_ controller: RepoController) {
        repoController?.stop()
        model.repo = controller
        let vc = RepoViewController(controller: controller, window: model)
        repoVC = vc
        setContent(vc)
        updateTitle()
        controller.start()
        track { [weak self, weak controller] in
            guard let self, let controller, self.model.repo === controller else { return }
            _ = controller.changeCount
            _ = controller.busy
            self.updateTitle()
        }
    }

    /// Swapping the content view controller must not resize the window.
    private func setContent(_ vc: NSViewController) {
        guard let window else { return }
        let frame = window.frame
        window.contentViewController = vc
        window.setFrame(frame, display: true)
    }

    func updateTitle() {
        guard let c = repoController else { return }
        let lib = AppModel.shared.library.repo(c.libraryID)
        var title = lib?.displayName ?? c.name
        if c.repo.gitDir != c.repo.commonDir {
            title = "\(c.repo.commonDir.deletingLastPathComponent().lastPathComponent) · \(c.name)"
        }
        window?.title = title
        window?.tab.title = (c.changeCount > 0 ? "● " : "") + title
        window?.representedURL = c.repo.workTree
    }

    func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func windowWillClose(_ notification: Notification) {
        repoController?.stop()
        AppDelegate.shared.closed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Refresh on focus (Fork parity, §4.6).
        repoController?.refresh(state: true)
    }

    // MARK: Actions (reached through the responder chain via the window delegate)

    override func newWindowForTab(_ sender: Any?) { AppDelegate.shared.newTab(in: self) }
    @objc func showHomeTab(_ sender: Any?) { showHome() }
    @objc func showLocalChanges(_ sender: Any?) { repoController?.view = .localChanges }
    @objc func showAllCommits(_ sender: Any?) { repoController?.view = .history }
    @objc func refresh(_ sender: Any?) {
        guard let c = repoController else { RepoStatusCache.shared.refresh(AppModel.shared.library.repositories, force: true); return }
        c.refresh(state: true)
        c.reloadHistory()
    }
    @objc func performFind(_ sender: Any?) { repoVC?.showFind() }
    @objc func toggleCurrentBranchOnly(_ sender: Any?) {
        guard let c = repoController else { return }
        c.filter.scope = c.filter.scope == .current ? .all : .current
    }
    @objc func toggleHideRemotes(_ sender: Any?) { repoController?.filter.hideRemotes.toggle() }
    @objc func toggleHideTags(_ sender: Any?) { repoController?.filter.hideTags.toggle() }
    @objc func toggleFirstParent(_ sender: Any?) { repoController?.filter.firstParent.toggle() }
    @objc func toggleRepoSidebar(_ sender: Any?) { repoVC?.toggleSidebar(sender) }
    @objc func toggleDetails(_ sender: Any?) { repoVC?.toggleDetails() }
    @objc func toggleLayout(_ sender: Any?) {
        AppModel.shared.settings.verticalLayout.toggle()
        repoVC?.applyLayout()
    }
    @objc func detailsCommit(_ sender: Any?) { repoController?.details.tab = .commit }
    @objc func detailsChanges(_ sender: Any?) { repoController?.details.tab = .changes }
    @objc func detailsTree(_ sender: Any?) { repoController?.details.tab = .tree; repoController.map { $0.details.loadTree($0) } }
    @objc func revealHead(_ sender: Any?) { if let c = repoController { c.view = .history; c.select(c.headSHA) } }
    @objc func showInFinder(_ sender: Any?) {
        if let url = repoController?.repo.workTree { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    @objc func openInTerminal(_ sender: Any?) { if let url = repoController?.repo.workTree { External.openTerminal(url) } }
    @objc func openInEditor(_ sender: Any?) { if let url = repoController?.repo.workTree { External.openEditor(url) } }
    @objc func copyRepoPath(_ sender: Any?) {
        guard let p = repoController?.repo.workTree.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p, forType: .string)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let repoOnly: Set<Selector> = [
            #selector(showLocalChanges), #selector(showAllCommits), #selector(performFind), #selector(toggleCurrentBranchOnly),
            #selector(toggleHideRemotes), #selector(toggleHideTags), #selector(toggleFirstParent), #selector(toggleRepoSidebar), #selector(toggleDetails),
            #selector(detailsCommit), #selector(detailsChanges), #selector(detailsTree), #selector(revealHead),
            #selector(showInFinder), #selector(openInTerminal), #selector(openInEditor), #selector(copyRepoPath),
        ]
        if let action = item.action, repoOnly.contains(action) || RepoActions.selectors.contains(action) {
            guard let c = repoController else { return false }
            switch action {
            case #selector(toggleCurrentBranchOnly): item.state = c.filter.scope == .current ? .on : .off
            case #selector(toggleHideRemotes): item.state = c.filter.hideRemotes ? .on : .off
            case #selector(toggleHideTags): item.state = c.filter.hideTags ? .on : .off
            case #selector(toggleFirstParent): item.state = c.filter.firstParent ? .on : .off
            default: break
            }
            return RepoActions.validate(action, c)
        }
        if item.action == #selector(showHomeTab) { return repoController != nil }
        if item.action == #selector(toggleLayout) { item.state = AppModel.shared.settings.verticalLayout ? .on : .off }
        return true
    }

    // MARK: Toolbar (§5.3): GitHub Desktop-style repository, branch and sync controls.

    static let itemIDs: [NSToolbarItem.Identifier] = [.repository, .branch, .sync, .flexibleSpace]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.itemIDs }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIDs + [.refresh, .activity, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let m = model
        func host<V: View>(_ v: V, _ label: String) -> NSToolbarItem {
            item.view = NSHostingView(rootView: v)
            item.label = label
            item.paletteLabel = label
            return item
        }
        switch id {
        case .repository: return host(RepositoryControl(window: m), "Current Repository")
        case .branch: return host(BranchControl(window: m), "Current Branch")
        case .sync: return host(SyncControl(window: m), "Sync")
        case .refresh: return host(Button { [weak self] in self?.refresh(nil) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless), "Refresh")
        case .activity: return host(Button { AppDelegate.shared.showActivity(nil) } label: { Image(systemName: "list.bullet.rectangle") }.buttonStyle(.borderless), "Activity")
        default: return nil
        }
    }
}

extension NSToolbarItem.Identifier {
    static let repository = Self("repository"), branch = Self("branch"), sync = Self("sync")
    static let refresh = Self("refresh"), activity = Self("activity")
}

/// Two-line toolbar control label: small caption over a bold value (or bold title over a caption).
struct ToolbarLabel: View {
    var icon: String?
    let top: String
    let bottom: String
    var titleOnTop = false
    var chevron = true
    var badge: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 14)).frame(width: 18) } else { ProgressView().controlSize(.small).frame(width: 18) }
            VStack(alignment: .leading, spacing: 0) {
                Text(top).font(titleOnTop ? .system(size: 12, weight: .semibold) : .system(size: 10)).foregroundStyle(titleOnTop ? .primary : .secondary)
                Text(bottom).font(titleOnTop ? .system(size: 10) : .system(size: 12, weight: .semibold)).foregroundStyle(titleOnTop ? .secondary : .primary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let badge {
                Text(badge).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.accentColor))
            }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .frame(width: 200, height: 34, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct RepositoryControl: View {
    let window: WindowModel
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            ToolbarLabel(icon: "book.closed", top: "Current Repository", bottom: window.repo?.name ?? "Choose a repository")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .bottom) { RepositoryPicker(window: window, shown: $shown) }
    }
}

struct RepositoryPicker: View {
    let window: WindowModel
    @Binding var shown: Bool
    @State private var query = ""

    var body: some View {
        let repos = AppModel.shared.library.repositories
            .filter { $0.exists && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { if let r = repos.first { open(r.path) } }
                Menu("Add") {
                    Button("Add Existing Repository…") { send(#selector(AppDelegate.addExistingRepository(_:))) }
                    Button("Clone Repository…") { send(#selector(AppDelegate.cloneRepository(_:))) }
                    Button("New Repository…") { send(#selector(AppDelegate.initRepository(_:))) }
                }
                .fixedSize()
            }
            .padding(10)
            List(repos) { r in
                Button { open(r.path) } label: {
                    HStack {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                        Text(r.name).fontWeight(r.path == window.repo?.repo.workTree.path ? .semibold : .regular)
                        Spacer()
                        if r.path == window.repo?.repo.workTree.path { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            Divider()
            Button("Show All Repositories") { shown = false; send(#selector(TabWindowController.showHomeTab(_:))) }
                .buttonStyle(.borderless).padding(8)
        }
        .frame(width: 320, height: 360)
    }

    func open(_ path: String) { shown = false; AppDelegate.shared.openRepo(path: path) }
    func send(_ action: Selector) { shown = false; NSApp.sendAction(action, to: nil, from: nil) }
}

struct BranchControl: View {
    let window: WindowModel

    var body: some View {
        if let c = window.repo {
            @Bindable var c = c
            Button { c.branchPickerShown.toggle() } label: {
                ToolbarLabel(icon: "arrow.triangle.branch", top: c.currentBranch == nil ? "Detached HEAD" : "Current Branch",
                             bottom: c.currentBranch ?? String(c.headSHA?.prefix(7) ?? ""))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $c.branchPickerShown, arrowEdge: .bottom) { BranchPicker(controller: c) }
        }
    }
}

/// Switch (one click), create, and merge branches (BR-01).
struct BranchPicker: View {
    let controller: RepoController
    @State private var query = ""

    var body: some View {
        let c = controller
        let match: (Ref) -> Bool = { query.isEmpty || $0.shortName.localizedCaseInsensitiveContains(query) }
        let locals = c.localBranches.filter(match).sorted { $0.isHead != $1.isHead ? $0.isHead : $0.date > $1.date }
        // Remote branches that already have a local branch are reached through it.
        let localNames = Set(c.localBranches.map(\.shortName))
        let remotes = c.remoteBranches.filter { r in
            match(r) && !localNames.contains(String(r.shortName.dropFirst((r.remoteName?.count ?? -1) + 1)))
        }.sorted { $0.date > $1.date }
        VStack(spacing: 0) {
            TextField("Filter branches", text: $query).textFieldStyle(.roundedBorder).padding(10)
                .onSubmit { if let r = (locals.filter { !$0.isHead } + remotes).first { pick(r) } }
            List {
                Section("Branches") { ForEach(locals) { row($0) } }
                if !remotes.isEmpty { Section("Remote branches") { ForEach(remotes) { row($0) } } }
            }
            .listStyle(.plain)
            Divider()
            HStack {
                Button { c.branchPickerShown = false; RepoActions.newBranch(c, at: nil) } label: { Label("New Branch…", systemImage: "plus") }
                Spacer()
                if let current = c.currentBranch {
                    Button("Merge into \(current)…") { c.branchPickerShown = false; HistoryActions.mergeDialog(c, ref: nil) }
                        .help("Bring the commits from another branch into \(current)")
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 360, height: 440)
    }

    func row(_ r: Ref) -> some View {
        Button { pick(r) } label: {
            HStack(spacing: 8) {
                Image(systemName: r.isHead ? "checkmark" : r.kind == .remoteBranch ? "cloud" : "arrow.triangle.branch")
                    .frame(width: 16).foregroundStyle(r.isHead ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(r.shortName).fontWeight(r.isHead ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                Spacer()
                Group {
                    if r.ahead > 0 { Text("↑\(r.ahead)") }
                    if r.behind > 0 { Text("↓\(r.behind)") }
                    Text(Format.age(Date(timeIntervalSince1970: TimeInterval(r.date))))
                }
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(r.isHead ? "Current branch" : "Switch to \(r.shortName)")
        .contextMenu { RefMenu(controller: controller, ref: r) }
    }

    func pick(_ r: Ref) {
        controller.branchPickerShown = false
        RepoActions.checkout(controller, ref: r)
    }
}

/// One button that does the next sensible network step, like GitHub Desktop's "Fetch origin".
struct SyncControl: View {
    let window: WindowModel

    enum Step { case publishRepo, publishBranch, pull(Int), push(Int), fetch }

    var body: some View {
        if let c = window.repo {
            let step = Self.step(c)
            let remote = c.upstream?.remoteName ?? c.preferredRemote ?? "origin"
            HStack(spacing: 0) {
                Button { run(step, c) } label: {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        ToolbarLabel(icon: c.busy != nil ? nil : icon(step), top: title(step, remote),
                                     bottom: c.busy ?? caption(step, c, remote), titleOnTop: true, chevron: false, badge: badge(step))
                    }
                }
                .buttonStyle(.plain)
                .disabled(c.busy != nil)
                Menu {
                    Button("Fetch") { RepoActions.quickFetch(c) }
                    Button("Pull…") { RepoActions.pullDialog(c) }
                    Button("Push…") { RepoActions.pushDialog(c) }
                    Button("Force Push…") { RepoActions.pushDialog(c, force: true) }.disabled(c.remotes.isEmpty)
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, 6)
                .help("More sync options")
            }
        }
    }

    static func step(_ c: RepoController) -> Step {
        if c.remotes.isEmpty { return .publishRepo }
        guard let head = c.headRef else { return .fetch }
        if head.upstream == nil || head.upstreamGone { return .publishBranch }
        if head.behind > 0 { return .pull(head.behind) }
        if head.ahead > 0 { return .push(head.ahead) }
        return .fetch
    }

    func title(_ s: Step, _ remote: String) -> String {
        switch s {
        case .publishRepo: "Publish repository"
        case .publishBranch: "Publish branch"
        case .pull: "Pull \(remote)"
        case .push: "Push \(remote)"
        case .fetch: "Fetch \(remote)"
        }
    }

    func caption(_ s: Step, _ c: RepoController, _ remote: String) -> String {
        switch s {
        case .publishRepo: return "Put this repository on GitHub"
        case .publishBranch: return "Share this branch on \(remote)"
        default:
            guard let d = c.lastFetched else { return "Never fetched" }
            return Date().timeIntervalSince(d) < 60 ? "Last fetched just now" : "Last fetched " + Self.relative.localizedString(for: d, relativeTo: Date())
        }
    }

    func icon(_ s: Step) -> String {
        switch s {
        case .publishRepo, .publishBranch: "icloud.and.arrow.up"
        case .pull: "arrow.down"
        case .push: "arrow.up"
        case .fetch: "arrow.triangle.2.circlepath"
        }
    }

    func badge(_ s: Step) -> String? {
        switch s {
        case .pull(let n): "\(n)↓"
        case .push(let n): "\(n)↑"
        default: nil
        }
    }

    func run(_ s: Step, _ c: RepoController) {
        switch s {
        case .publishRepo: RepoActions.publish(c)
        case .publishBranch, .push: RepoActions.quickPush(c)
        case .pull: RepoActions.quickPull(c)
        case .fetch: RepoActions.quickFetch(c)
        }
    }

    static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f }()
}

/// Sidebar | content, where content is History (list over details) or Local Changes.
@MainActor
final class RepoViewController: NSSplitViewController {
    let controller: RepoController
    let window: WindowModel
    let list: CommitListController
    private let historySplit = NSSplitViewController()
    private let localChanges: NSViewController
    private let contentContainer = NSViewController()
    /// Holds History or Local Changes, below the in-progress operation bar.
    private let content = NSView()
    private var detailsItem: NSSplitViewItem!

    init(controller: RepoController, window: WindowModel) {
        self.controller = controller
        self.window = window
        list = CommitListController(controller: controller)
        let local = NSHostingController(rootView: LocalChangesView(controller: controller))
        local.sizingOptions = []
        localChanges = local
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "RepoSplit"
        let sidebarHost = NSHostingController(rootView: SidebarView(controller: controller))
        sidebarHost.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 420
        addSplitViewItem(sidebar)

        historySplit.splitView.autosaveName = "HistorySplit"
        let listItem = NSSplitViewItem(viewController: list)
        listItem.minimumThickness = 120
        historySplit.addSplitViewItem(listItem)
        let detailsHost = NSHostingController(rootView: DetailsView(controller: controller))
        detailsHost.sizingOptions = []
        detailsItem = NSSplitViewItem(viewController: detailsHost)
        detailsItem.minimumThickness = 160
        historySplit.addSplitViewItem(detailsItem)
        applyLayout()

        contentContainer.view = NSView()
        let bar = NSHostingView(rootView: OperationBar(controller: controller))
        bar.translatesAutoresizingMaskIntoConstraints = false
        // Height only: an empty bar's zero max width would otherwise squeeze the window.
        bar.sizingOptions = [.intrinsicContentSize]
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.setContentHuggingPriority(.required, for: .vertical)
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.view.addSubview(bar)
        contentContainer.view.addSubview(content)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: contentContainer.view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: contentContainer.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentContainer.view.trailingAnchor),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentContainer.view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.view.bottomAnchor),
        ])
        addSplitViewItem(NSSplitViewItem(viewController: contentContainer))
        track { [weak self] in
            guard let self else { return }
            self.showContent(self.controller.view)
        }
    }

    func applyLayout() {
        historySplit.splitView.isVertical = AppModel.shared.settings.verticalLayout
        historySplit.splitView.adjustSubviews()
    }

    private var shown: RepoView?
    private func showContent(_ v: RepoView) {
        guard shown != v else { return }
        shown = v
        let child = v == .history ? historySplit : localChanges
        for c in contentContainer.children { c.view.removeFromSuperview(); c.removeFromParent() }
        contentContainer.addChild(child)
        child.view.frame = content.bounds
        child.view.autoresizingMask = [.width, .height]
        content.addSubview(child.view)
        if v == .history { view.window?.makeFirstResponder(list.table) }
    }

    func showFind() {
        controller.view = .history
        list.showFind()
    }

    func toggleDetails() { detailsItem.animator().isCollapsed.toggle() }
}

@MainActor
enum External {
    static func openTerminal(_ url: URL) {
        let app = AppModel.shared.settings.terminalApp
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app.isEmpty ? "Terminal" : app, url.path]
        try? p.run()
    }

    static func openEditor(_ url: URL, line: Int? = nil) {
        let editor = AppModel.shared.settings.editorApp
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = editor.isEmpty ? [url.path] : ["-a", editor, url.path]
        try? p.run()
    }
}
