import AppKit
import SwiftUI
import SpoonKit

/// Repository operations reachable from menus, toolbar, context menus and Quick Launch.
@MainActor
enum RepoActions {
    static let selectors: Set<Selector> = [
        #selector(TabWindowController.fetchAction), #selector(TabWindowController.quickFetchAction),
        #selector(TabWindowController.pullAction), #selector(TabWindowController.quickPullAction),
        #selector(TabWindowController.pushAction), #selector(TabWindowController.quickPushAction),
        #selector(TabWindowController.stashAction), #selector(TabWindowController.quickStashAction),
        #selector(TabWindowController.checkoutAction), #selector(TabWindowController.newBranchAction),
        #selector(TabWindowController.newTagAction), #selector(TabWindowController.mergeAction),
        #selector(TabWindowController.rebaseAction), #selector(TabWindowController.addRemoteAction),
        #selector(TabWindowController.publishAction), #selector(TabWindowController.focusCommit), #selector(TabWindowController.operationHistory),
        #selector(TabWindowController.undo(_:)), #selector(TabWindowController.redo(_:)),
    ]

    static func validate(_ action: Selector, _ c: RepoController) -> Bool {
        switch action {
        case #selector(TabWindowController.operationHistory), #selector(TabWindowController.focusCommit): return true
        case #selector(TabWindowController.undo(_:)), #selector(TabWindowController.redo(_:)): return c.busy == nil
        case #selector(TabWindowController.publishAction): return c.busy == nil && !c.remotes.contains { $0.name == "origin" }
        default: return c.busy == nil
        }
    }

    /// Button tooltips show exactly what will run (§5.3).
    static func tooltip(_ label: String, _ c: RepoController) -> String {
        let up = c.upstream
        switch label {
        case "Fetch": return "git fetch --prune --all  (⌥-click: quick fetch)"
        case "Pull":
            guard let up, let r = up.remoteName else { return "Pull (no upstream)" }
            return "git pull \(c.defaultPullStrategy.flag) \(r) \(up.shortName.dropFirst(r.count + 1))  (⌥-click: quick pull)"
        case "Push":
            guard let b = c.currentBranch else { return "Push" }
            return "git push \(up?.remoteName ?? c.remotes.first?.name ?? "origin") \(b)  (⌥-click: quick push)"
        default: return label
        }
    }

    // MARK: Network

    static func quickFetch(_ c: RepoController?) {
        guard let c else { return }
        c.perform("Fetch", context: .fetch) { repo, out in try await repo.fetch(remote: nil, prune: true, output: out) }
    }

    static func fetchDialog(_ c: RepoController?) {
        guard let c else { return }
        Sheets.present(FetchDialog(controller: c), on: c.window)
    }

    static func quickPull(_ c: RepoController?, strategy: PullStrategy? = nil, then: (@MainActor () -> Void)? = nil) {
        guard let c else { return }
        guard let up = c.upstream, let remote = up.remoteName else { pullDialog(c); return }
        let branch = String(up.shortName.dropFirst(remote.count + 1))
        let strat = strategy ?? c.defaultPullStrategy
        c.perform("Pull \(up.shortName)", context: .pull, { repo, out in
            try await repo.pull(remote: remote, branch: branch, strategy: strat, localChanges: .stash, output: out)
        }, then: then)
    }

    static func pullDialog(_ c: RepoController?) {
        guard let c else { return }
        Sheets.present(PullDialog(controller: c), on: c.window)
    }

    static func quickPush(_ c: RepoController?) {
        guard let c, let branch = c.currentBranch else { return }
        let up = c.upstream
        let remote = up?.remoteName ?? c.remotes.first?.name
        guard let remote else { pushDialog(c); return }
        let remoteBranch = up.map { String($0.shortName.dropFirst(remote.count + 1)) } ?? branch
        c.perform("Push \(branch)", context: .push) { repo, out in
            try await repo.push([PushSpec(local: branch, remote: remote, remoteBranch: remoteBranch)],
                                options: PushOptions(setUpstream: up == nil), output: out)
        }
    }

    static func pushDialog(_ c: RepoController?, force: Bool = false) {
        guard let c else { return }
        guard !c.remotes.isEmpty else { publish(c); return } // nowhere to push yet
        Sheets.present(PushDialog(controller: c, force: force), on: c.window)
    }

    static func publish(_ c: RepoController) { Sheets.present(PublishDialog(controller: c), on: c.window) }

    // MARK: Branches

    static func newBranch(_ c: RepoController?, at start: String?) {
        guard let c else { return }
        Sheets.present(NewBranchDialog(controller: c, start: start ?? c.currentBranch ?? c.headSHA ?? "HEAD"), on: c.window)
    }

    static func checkout(_ c: RepoController, ref: Ref, mode: LocalChangesMode = .keep) {
        if ref.isHead { return }
        let all = c.refs
        c.perform("Checkout \(ref.shortName)", context: .checkout(retry: { m in checkout(c, ref: ref, mode: m) })) { repo, _ in
            try await repo.checkout(ref, localChanges: mode, allRefs: all)
        }
    }

    static func checkoutCommit(_ c: RepoController, _ sha: String) {
        let a = NSAlert()
        a.messageText = "Check out commit \(sha.prefix(7))?"
        a.informativeText = "You will be in detached HEAD state. Create a branch to keep new commits."
        a.addButton(withTitle: "Checkout")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        c.perform("Checkout \(sha.prefix(7))", context: .checkout(retry: { m in
            c.perform("Checkout \(sha.prefix(7))") { repo, _ in try await repo.checkoutDetached(sha, localChanges: m) }
        })) { repo, _ in try await repo.checkoutDetached(sha) }
    }

    static func checkoutPicker(_ c: RepoController) {
        Sheets.present(CheckoutPicker(controller: c), on: c.window)
    }

    static func rename(_ c: RepoController, _ ref: Ref) {
        Sheets.present(RenameBranchDialog(controller: c, ref: ref), on: c.window)
    }

    static func delete(_ c: RepoController, _ refs: [Ref]) {
        let locals = refs.filter { $0.kind == .localBranch && !$0.isHead }
        if !locals.isEmpty { Sheets.present(DeleteBranchDialog(controller: c, refs: locals), on: c.window) }
        for r in refs where r.kind == .remoteBranch {
            guard let remote = r.remoteName else { continue }
            let branch = String(r.shortName.dropFirst(remote.count + 1))
            let a = NSAlert()
            a.messageText = "Delete \(r.shortName) from \(remote)?"
            a.informativeText = "This can't be undone: deleting a remote branch affects everyone using \(remote)."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            if a.runModal() == .alertFirstButtonReturn {
                c.perform("Delete \(r.shortName)") { repo, _ in try await repo.deleteRemoteBranch(remote: remote, branch: branch) }
            }
        }
        for t in refs where t.kind == .tag { deleteTag(c, t) }
    }

    static func setUpstream(_ c: RepoController, _ ref: Ref, to upstream: Ref?) {
        c.perform("Set upstream") { repo, _ in try await repo.setUpstream(ref.shortName, to: upstream?.shortName) }
    }

    static func fastForward(_ c: RepoController, _ ref: Ref) {
        guard let up = ref.upstream else { return }
        if ref.isHead {
            c.perform("Fast-forward \(ref.shortName)") { repo, _ in
                _ = try await repo.journaled("Fast-forward \(ref.shortName)") { try await repo.git.run(["merge", "--ff-only", up], in: repo.workTree) }
            }
        } else {
            c.perform("Fast-forward \(ref.shortName)") { repo, _ in try await repo.fastForward(ref.shortName, to: up) }
        }
    }

    // MARK: Stash

    static func stashDialog(_ c: RepoController, paths: [String] = []) {
        Sheets.present(StashDialog(controller: c, paths: paths), on: c.window)
    }

    static func quickStash(_ c: RepoController) {
        c.perform("Stash") { repo, _ in try await repo.stash(message: nil, includeUntracked: true) }
    }

    static func applyStash(_ c: RepoController, _ s: Stash, pop: Bool) {
        c.perform(pop ? "Pop stash" : "Apply stash") { repo, _ in try await repo.applyStash(s, pop: pop) }
    }

    static func dropStash(_ c: RepoController, _ s: Stash) {
        let a = NSAlert()
        a.messageText = "Drop stash “\(s.message)”?"
        a.informativeText = "A dropped stash can be restored with Undo (⌘Z)."
        a.addButton(withTitle: "Drop")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        c.perform("Drop stash") { repo, _ in try await repo.dropStash(s) }
    }

    static func renameStash(_ c: RepoController, _ s: Stash) {
        guard let name = prompt("Rename Stash", value: s.message, action: "Rename") else { return }
        c.perform("Rename stash") { repo, _ in try await repo.renameStash(s, to: name) }
    }

    static func branchFromStash(_ c: RepoController, _ s: Stash) {
        guard let name = prompt("Create Branch from Stash", value: "", placeholder: "branch-name", action: "Create Branch") else { return }
        c.perform("Branch from stash") { repo, _ in try await repo.branchFromStash(s, name: name) }
    }

    // MARK: Tags

    static func newTag(_ c: RepoController, at target: String?) {
        Sheets.present(NewTagDialog(controller: c, target: target ?? c.headSHA ?? "HEAD"), on: c.window)
    }

    static func deleteTag(_ c: RepoController, _ t: Ref) {
        let a = NSAlert()
        a.messageText = "Delete tag \(t.shortName)?"
        let remote = NSButton(checkboxWithTitle: "Also delete from \(c.remotes.first?.name ?? "remote") (can't be undone)", target: nil, action: nil)
        if !c.remotes.isEmpty { a.accessoryView = remote }
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let alsoRemote = remote.state == .on ? c.remotes.first?.name : nil
        c.perform("Delete tag \(t.shortName)") { repo, _ in
            try await repo.deleteTag(t.shortName)
            if let r = alsoRemote { try await repo.deleteRemoteTag(t.shortName, remote: r) }
        }
    }

    static func pushTag(_ c: RepoController, _ t: Ref, remote: String) {
        c.perform("Push tag \(t.shortName)") { repo, _ in try await repo.pushTags([t.shortName], remote: remote) }
    }

    // MARK: Remotes

    static func addRemote(_ c: RepoController) { Sheets.present(RemoteDialog(controller: c, remote: nil), on: c.window) }
    static func editRemote(_ c: RepoController, _ r: Remote) { Sheets.present(RemoteDialog(controller: c, remote: r), on: c.window) }
    static func removeRemote(_ c: RepoController, _ r: Remote) {
        let a = NSAlert()
        a.messageText = "Remove remote \(r.name)?"
        a.informativeText = "Its remote-tracking branches are removed too."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        c.perform("Remove remote \(r.name)") { repo, _ in try await repo.removeRemote(r.name) }
    }

    // MARK: Conflicts (minimal until the merge editor lands)

    static func resolve(_ c: RepoController, _ paths: [String], ours: Bool) {
        c.perform(ours ? "Take Yours" : "Take Theirs") { repo, _ in
            try await repo.git.run(["checkout", ours ? "--ours" : "--theirs", "--"] + paths, in: repo.workTree)
            try await repo.stage(paths)
        }
    }

    // MARK: Undo (§4.9)

    static func undo(_ c: RepoController, redo: Bool = false) {
        c.perform(redo ? "Redo" : "Undo") { repo, _ in
            _ = redo ? try await repo.redo() : try await repo.undo()
        }
    }

    static func prompt(_ title: String, value: String, placeholder: String = "", action: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        a.accessoryView = field
        a.addButton(withTitle: action)
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}

extension RepoController {
    func doubleClick(_ ref: Ref) { RepoActions.checkout(self, ref: ref) }

    var defaultPullStrategy: PullStrategy {
        switch pullConfig {
        case "true", "merges", "interactive": .rebase
        case "ff-only": .ffOnly
        case "false": .merge
        default: .ffOnly
        }
    }
}

extension TabWindowController {
    @objc func fetchAction(_ s: Any?) { RepoActions.fetchDialog(repoController) }
    @objc func quickFetchAction(_ s: Any?) { RepoActions.quickFetch(repoController) }
    @objc func pullAction(_ s: Any?) { RepoActions.pullDialog(repoController) }
    @objc func quickPullAction(_ s: Any?) { RepoActions.quickPull(repoController) }
    @objc func pushAction(_ s: Any?) { RepoActions.pushDialog(repoController) }
    @objc func quickPushAction(_ s: Any?) { RepoActions.quickPush(repoController) }
    @objc func stashAction(_ s: Any?) { repoController.map { RepoActions.stashDialog($0) } }
    @objc func quickStashAction(_ s: Any?) { repoController.map(RepoActions.quickStash) }
    @objc func checkoutAction(_ s: Any?) { repoController.map(RepoActions.checkoutPicker) }
    @objc func newBranchAction(_ s: Any?) { RepoActions.newBranch(repoController, at: nil) }
    @objc func newTagAction(_ s: Any?) { repoController.map { RepoActions.newTag($0, at: nil) } }
    @objc func mergeAction(_ s: Any?) { repoController.map { HistoryActions.mergeDialog($0, ref: nil) } }
    @objc func rebaseAction(_ s: Any?) { repoController.map { HistoryActions.rebaseDialog($0, onto: nil) } }
    @objc func addRemoteAction(_ s: Any?) { repoController.map(RepoActions.addRemote) }
    @objc func publishAction(_ s: Any?) { repoController.map(RepoActions.publish) }
    @objc func focusCommit(_ s: Any?) { repoController?.view = .localChanges; repoController?.focusCommitToken += 1 }
    @objc func operationHistory(_ s: Any?) { repoController.map { Sheets.present(OperationHistoryView(controller: $0), on: window) } }
    @objc func undo(_ s: Any?) { repoController.map { RepoActions.undo($0) } }
    @objc func redo(_ s: Any?) { repoController.map { RepoActions.undo($0, redo: true) } }
    private var contextGroup: UUID? { model.scope ?? (repoController == nil ? model.homeGroup : nil) }
    @objc func fetchGroupAction(_ s: Any?) { contextGroup.map { GroupActions.run($0, pull: false) } ?? GroupActions.pickAndRun(pull: false) }
    @objc func pullGroupAction(_ s: Any?) { contextGroup.map { GroupActions.run($0, pull: true) } ?? GroupActions.pickAndRun(pull: true) }
    @objc func groupDashboardAction(_ s: Any?) { contextGroup.map { GroupActions.dashboard($0) } ?? GroupActions.pickAndRun(pull: nil) }
}

@MainActor
enum AppActions {
    /// Add Existing Repository (REPO-01): pick folders; git repos join the library, other folders get scanned.
    static func addExisting() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a folder that contains a git repository"
        guard panel.runModal() == .OK else { return }
        addExisting(panel.urls)
    }

    static func addExisting(_ urls: [URL]) {
        Task {
            let git = await AppModel.shared.git()
            var added: [UUID] = []
            for picked in urls {
                // The .git folder itself means its working copy.
                let folder = picked.lastPathComponent == ".git" ? picked.deletingLastPathComponent() : picked
                switch await RepoScanner.check(folder, git: git) {
                case .repository(let top):
                    AppModel.shared.updateLibrary { added.append($0.add(path: top.path)) }
                case .notRepository(let nested) where !nested.isEmpty:
                    Sheets.present(ScanSheet(results: ScanResults(root: folder, found: nested)), on: AppDelegate.shared.current?.window)
                case .notRepository:
                    if let id = await offerInit(folder, git: git) { added.append(id) }
                case .unsupported(let why):
                    alert("“\(folder.lastPathComponent)” can't be added", why)
                }
            }
            guard !added.isEmpty else { return }
            let home = AppDelegate.shared.home()
            home.model.homeGroup = nil
            home.model.homeSelection = Set(added)
        }
    }

    /// No repository and none inside: offer `git init` in place.
    private static func offerInit(_ folder: URL, git: GitRunner) async -> UUID? {
        let a = NSAlert()
        a.messageText = "“\(folder.lastPathComponent)” isn't a git repository"
        a.informativeText = "There's no repository in this folder or the folders inside it. Create one here? Your files aren't changed or committed."
        a.addButton(withTitle: "Create Repository")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            try await RepoCreation.initialize(at: folder, branch: nil, readme: false, gitignore: nil, initialCommit: false, git: git)
        } catch {
            alert("Couldn't create a repository", (error as? GitError)?.stderr ?? error.localizedDescription)
            return nil
        }
        var id: UUID?
        AppModel.shared.updateLibrary { id = $0.add(path: folder.path) }
        return id
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    static func clone(_ url: String?) { Sheets.present(CloneDialog(url: url ?? ""), on: AppDelegate.shared.current?.window) }
    static func initRepo(_ path: String?) { Sheets.present(InitDialog(), on: AppDelegate.shared.current?.window) }

    static func newGroup(with repos: [UUID]) {
        guard let name = RepoActions.prompt("New Group", value: "", placeholder: "Work/Payments  (/ nests)", action: "Create Group") else { return }
        AppModel.shared.updateLibrary { lib in
            let id = lib.addGroup(name)
            lib.addMembers(repos, to: id)
        }
    }
}

extension AppDelegate {
    @objc func installCLI(_ sender: Any?) {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spoon").path
        let a = NSAlert()
        a.messageText = "Install the spoon command line tool"
        a.informativeText = "Run this in Terminal:\n\nsudo ln -sf '\(helper)' /usr/local/bin/spoon"
        a.addButton(withTitle: "Copy Command")
        a.addButton(withTitle: "Close")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("sudo ln -sf '\(helper)' /usr/local/bin/spoon", forType: .string)
        }
    }
}
