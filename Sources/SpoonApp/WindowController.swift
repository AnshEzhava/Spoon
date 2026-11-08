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
        let toolbar = NSToolbar(identifier: "main.2")
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
            #selector(toggleHideRemotes), #selector(toggleHideTags), #selector(toggleRepoSidebar), #selector(toggleDetails),
            #selector(detailsCommit), #selector(detailsChanges), #selector(detailsTree), #selector(revealHead),
            #selector(showInFinder), #selector(openInTerminal), #selector(openInEditor), #selector(copyRepoPath),
        ]
        if let action = item.action, repoOnly.contains(action) || RepoActions.selectors.contains(action) {
            guard let c = repoController else { return false }
            switch action {
            case #selector(toggleCurrentBranchOnly): item.state = c.filter.scope == .current ? .on : .off
            case #selector(toggleHideRemotes): item.state = c.filter.hideRemotes ? .on : .off
            case #selector(toggleHideTags): item.state = c.filter.hideTags ? .on : .off
            default: break
            }
            return RepoActions.validate(action, c)
        }
        if item.action == #selector(showHomeTab) { return repoController != nil }
        if item.action == #selector(toggleLayout) { item.state = AppModel.shared.settings.verticalLayout ? .on : .off }
        return true
    }

    // MARK: Toolbar (§5.3)

    static let itemIDs: [NSToolbarItem.Identifier] = [.back, .quickLaunch, .fetch, .pull, .push, .stash, .flexibleSpace, .status, .flexibleSpace, .newBranch, .openIn]

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
        case .back: return host(ToolbarButton(symbol: "chevron.left", label: "Back", window: m, requiresRepo: true) { [weak self] _ in self?.showHome() }, "Back")
        case .quickLaunch: return host(ToolbarButton(symbol: "magnifyingglass", label: "Quick Launch", window: m) { _ in AppDelegate.shared.showQuickLaunch(nil) }, "Quick Launch")
        case .fetch: return host(ToolbarButton(symbol: "arrow.down.circle", label: "Fetch", window: m, requiresRepo: true) { c in
            NSEvent.modifierFlags.contains(.option) ? RepoActions.quickFetch(c) : RepoActions.fetchDialog(c) }, "Fetch")
        case .pull: return host(ToolbarButton(symbol: "arrow.down.to.line", label: "Pull", window: m, requiresRepo: true, badge: { "\($0.headRef?.behind ?? 0)" }) { c in
            NSEvent.modifierFlags.contains(.option) ? RepoActions.quickPull(c) : RepoActions.pullDialog(c) }, "Pull")
        case .push: return host(ToolbarButton(symbol: "arrow.up.to.line", label: "Push", window: m, requiresRepo: true, badge: { "\($0.headRef?.ahead ?? 0)" }) { c in
            NSEvent.modifierFlags.contains(.option) ? RepoActions.quickPush(c) : RepoActions.pushDialog(c) }, "Push")
        case .stash: return host(StashToolbarMenu(window: m), "Stash")
        case .status: return host(StatusControl(window: m), "Repository")
        case .newBranch: return host(ToolbarButton(symbol: "arrow.triangle.branch", label: "New Branch", window: m, requiresRepo: true) { c in
            RepoActions.newBranch(c, at: nil) }, "New Branch")
        case .openIn: return host(OpenInMenu(window: m), "Open in")
        case .refresh: return host(ToolbarButton(symbol: "arrow.clockwise", label: "Refresh", window: m) { [weak self] _ in self?.refresh(nil) }, "Refresh")
        case .activity: return host(ToolbarButton(symbol: "list.bullet.rectangle", label: "Activity", window: m) { _ in AppDelegate.shared.showActivity(nil) }, "Activity")
        default: return nil
        }
    }
}

extension NSToolbarItem.Identifier {
    static let quickLaunch = Self("quickLaunch"), fetch = Self("fetch"), pull = Self("pull"), push = Self("push")
    static let stash = Self("stash"), status = Self("status"), newBranch = Self("newBranch"), openIn = Self("openIn")
    static let refresh = Self("refresh"), activity = Self("activity"), back = Self("back")
}

struct ToolbarButton: View {
    let symbol: String
    let label: String
    let window: WindowModel
    var requiresRepo = false
    var badge: ((RepoController) -> String)? = nil
    let action: (RepoController?) -> Void

    var body: some View {
        Button { action(window.repo) } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol).frame(width: 28, height: 22)
                if let c = window.repo, let b = badge?(c), b != "0" {
                    Text(b).font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 3).background(Capsule().fill(Color.accentColor)).offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(requiresRepo && window.repo == nil)
        .help(window.repo.map { RepoActions.tooltip(label, $0) } ?? label)
        .accessibilityLabel(label)
    }
}

/// Repo name, branch popup and ↑↓, plus running-operation progress (§5.3).
struct StatusControl: View {
    let window: WindowModel
    private var activity: ActivityLog { AppModel.shared.activity }

    var body: some View {
        HStack(spacing: 8) {
            Button { AppDelegate.shared.showActivity(nil) } label: {
                Image(systemName: activity.operations.first(where: { $0.repo == window.repo?.repo.workTree.path })?.failed == true
                      ? "exclamationmark.circle" : "line.3.horizontal")
            }
            .buttonStyle(.borderless)
            .help("Activity")
            if let c = window.repo {
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
                    if let busy = c.busy {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(busy).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                        }
                    } else {
                        BranchPopup(controller: c)
                    }
                }
                Spacer(minLength: 4)
                if let h = c.headRef, h.upstream != nil {
                    Text("↑\(h.ahead) ↓\(h.behind)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                Text("Welcome to Spoon — Open or clone a repository").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 260, idealWidth: 340, maxWidth: 420, minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
    }
}

struct BranchPopup: View {
    let controller: RepoController
    var body: some View {
        Menu {
            Section("Local") {
                ForEach(controller.localBranches) { r in
                    Button { RepoActions.checkout(controller, ref: r) } label: { Text(r.isHead ? "✓ \(r.shortName)" : r.shortName) }
                }
            }
            Section("Remote") {
                ForEach(controller.remoteBranches) { r in Button(r.shortName) { RepoActions.checkout(controller, ref: r) } }
            }
            Divider()
            Button("Checkout… (⌘B)") { RepoActions.checkoutPicker(controller) }
        } label: {
            Text("⎇ \(controller.currentBranch ?? "detached \(controller.headSHA?.prefix(7) ?? "")")").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct StashToolbarMenu: View {
    let window: WindowModel
    var body: some View {
        Menu {
            if let c = window.repo {
                Button("Save Stash…") { RepoActions.stashDialog(c) }
                Button("Quick Stash") { RepoActions.quickStash(c) }
                Button("Pop Latest") { if let s = c.stashes.first { RepoActions.applyStash(c, s, pop: true) } }
                    .disabled(c.stashes.isEmpty)
            }
        } label: { Image(systemName: "archivebox") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(window.repo == nil)
        .help("Stash")
    }
}

struct OpenInMenu: View {
    let window: WindowModel
    var body: some View {
        Menu {
            if let c = window.repo {
                Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.repo.workTree]) }
                Button("Terminal") { External.openTerminal(c.repo.workTree) }
                Button("Editor") { External.openEditor(c.repo.workTree) }
                if let url = c.remotes.first?.webURL { Button("Browser") { NSWorkspace.shared.open(url) } }
            }
        } label: { Image(systemName: "arrow.up.forward.app") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(window.repo == nil)
        .help("Open in")
    }
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
