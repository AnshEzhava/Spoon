import AppKit
import SwiftUI
import SpoonKit

/// History context menu (HIST-12).
@MainActor
enum CommitMenu {
    static func build(_ menu: NSMenu, commit: Commit, selection: [Commit], controller c: RepoController) {
        for ref in c.refsBySHA[commit.sha, default: []] where ref.kind != .tag && !ref.isHead {
            menu.addItem(ActionItem("Checkout \(ref.shortName)") { RepoActions.checkout(c, ref: ref) })
        }
        menu.addItem(ActionItem("Checkout Commit…") { RepoActions.checkoutCommit(c, commit.sha) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("New Branch Here…") { RepoActions.newBranch(c, at: commit.sha) })
        menu.addItem(ActionItem("New Tag Here…") { RepoActions.newTag(c, at: commit.sha) })
        menu.addItem(.separator())
        let head = c.currentBranch ?? "HEAD"
        let picks = selection.filter { $0.sha != c.headSHA }
        if !picks.isEmpty {
            menu.addItem(ActionItem(picks.count > 1 ? "Cherry-pick \(picks.count) Commits…" : "Cherry-pick…") {
                Sheets.present(CherryPickDialog(controller: c, commits: picks), on: c.window)
            })
        }
        menu.addItem(ActionItem(selection.count > 1 ? "Revert \(selection.count) Commits…" : "Revert…") {
            Sheets.present(CherryPickDialog(controller: c, commits: selection, revert: true), on: c.window)
        })
        if selection.count == 1 {
            if commit.sha != c.headSHA {
                menu.addItem(ActionItem("Merge into \(head)…") { HistoryActions.merge(c, commit.sha) })
                menu.addItem(ActionItem("Rebase \(head) onto Here…") { HistoryActions.rebase(c, commit.sha) })
                menu.addItem(ActionItem("Reset \(head) to Here…") { Sheets.present(ResetDialog(controller: c, commit: commit), on: c.window) })
            }
            let rewrite = NSMenu()
            rewrite.addItem(ActionItem("Rebase \(head) from Here Interactively…") { HistoryActions.interactiveRebase(c, from: commit) })
            rewrite.addItem(.separator())
            rewrite.addItem(ActionItem("Reword…") { HistoryActions.reword(c, commit) })
            rewrite.addItem(ActionItem("Edit") { HistoryActions.quick(c, commit, .edit) })
            rewrite.addItem(ActionItem("Squash into Parent") { HistoryActions.quick(c, commit, .squashIntoParent) })
            rewrite.addItem(ActionItem("Fixup into Parent") { HistoryActions.quick(c, commit, .fixupIntoParent) })
            rewrite.addItem(ActionItem("Move Up") { HistoryActions.quick(c, commit, .moveUp) })
            rewrite.addItem(ActionItem("Move Down") { HistoryActions.quick(c, commit, .moveDown) })
            rewrite.addItem(ActionItem("Drop…") { HistoryActions.quick(c, commit, .drop) })
            if !c.status.staged.isEmpty {
                rewrite.addItem(.separator())
                rewrite.addItem(ActionItem("Amend Staged Changes into This Commit") {
                    let sha = commit.sha
                    c.rewrite("Amend staged into \(commit.shortSHA)") { try await $0.amendStaged(into: sha) }
                })
            }
            let item = NSMenuItem(title: "Interactive Rebase", action: nil, keyEquivalent: "")
            item.submenu = rewrite
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let shas = selection.map(\.sha)
        menu.addItem(ActionItem(shas.count > 1 ? "Copy \(shas.count) SHAs" : "Copy SHA") { copy(shas.joined(separator: "\n")) })
        menu.addItem(ActionItem("Copy Short SHA") { copy(selection.map(\.shortSHA).joined(separator: "\n")) })
        menu.addItem(ActionItem("Copy Subject") { copy(selection.map(\.subject).joined(separator: "\n")) })
        menu.addItem(ActionItem("Copy Info") {
            copy(selection.map { "\($0.shortSHA) \($0.subject) (\($0.authorName), \(Format.date($0.authorDate)))" }
                .joined(separator: "\n"))
        })
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Sidebar branch/tag context menu (BR-*, TAG-*).
struct RefMenu: View {
    let controller: RepoController
    let ref: Ref

    var body: some View {
        let c = controller
        switch ref.kind {
        case .localBranch:
            if !ref.isHead { Button("Checkout \(ref.shortName)") { RepoActions.checkout(c, ref: ref) } }
            if ref.behind > 0 && ref.ahead == 0 { Button("Fast-forward to \(upstreamName)") { RepoActions.fastForward(c, ref) } }
            if !c.remotes.isEmpty { Button("Push…") { RepoActions.pushDialog(c) } }
            Divider()
            Button("New Branch from \(ref.shortName)…") { RepoActions.newBranch(c, at: ref.shortName) }
            Button("New Tag Here…") { RepoActions.newTag(c, at: ref.target) }
            if !ref.isHead {
                Divider()
                Button("Merge \(ref.shortName) into \(c.currentBranch ?? "HEAD")…") { HistoryActions.merge(c, ref.shortName) }
                Button("Rebase \(c.currentBranch ?? "HEAD") onto \(ref.shortName)…") { HistoryActions.rebase(c, ref.shortName) }
            }
            Divider()
            Menu("Upstream") {
                ForEach(c.remoteBranches) { r in Button(r.shortName) { RepoActions.setUpstream(c, ref, to: r) } }
                if ref.upstream != nil { Divider(); Button("Unset Upstream") { RepoActions.setUpstream(c, ref, to: nil) } }
            }
            Button("Rename…") { RepoActions.rename(c, ref) }
            Button("Delete…") { RepoActions.delete(c, [ref]) }.disabled(ref.isHead || ref.worktreePath != nil)
        case .remoteBranch:
            Button("Checkout \(ref.shortName)") { RepoActions.checkout(c, ref: ref) }
            Button("New Branch from \(ref.shortName)…") { RepoActions.newBranch(c, at: ref.shortName) }
            Button("Merge \(ref.shortName) into \(c.currentBranch ?? "HEAD")…") { HistoryActions.merge(c, ref.shortName) }
            Button("Rebase \(c.currentBranch ?? "HEAD") onto \(ref.shortName)…") { HistoryActions.rebase(c, ref.shortName) }
            Divider()
            Button("Delete from \(ref.remoteName ?? "remote")…") { RepoActions.delete(c, [ref]) }
        case .tag:
            Button("Checkout Tag…") { RepoActions.checkoutCommit(c, ref.target) }
            Button("New Branch Here…") { RepoActions.newBranch(c, at: ref.shortName) }
            ForEach(c.remotes) { r in Button("Push to \(r.name)") { RepoActions.pushTag(c, ref, remote: r.name) } }
            Divider()
            Button("Delete…") { RepoActions.delete(c, [ref]) }
        default:
            EmptyView()
        }
        Divider()
        Button("Copy Name") { CommitMenu.copy(ref.shortName) }
    }

    var upstreamName: String { ref.upstream.map { String($0.dropFirst("refs/remotes/".count)) } ?? "" }
}

struct StashMenu: View {
    let controller: RepoController
    let stash: Stash

    var body: some View {
        Button("Apply") { RepoActions.applyStash(controller, stash, pop: false) }
        Button("Pop") { RepoActions.applyStash(controller, stash, pop: true) }
        Button("New Branch from Stash…") { RepoActions.branchFromStash(controller, stash) }
        Button("Rename…") { RepoActions.renameStash(controller, stash) }
        Divider()
        Button("Drop…") { RepoActions.dropStash(controller, stash) }
        Divider()
        Button("Copy Message") { CommitMenu.copy(stash.message) }
    }
}

/// History-rewriting actions (§6.12).
@MainActor
enum HistoryActions {
    /// No ref given (menu/⌘⇧M): pick a branch first.
    static func mergeDialog(_ c: RepoController, ref: Ref?) {
        if let ref { return merge(c, ref.shortName) }
        pickBranch(c, title: "Merge into \(c.currentBranch ?? "HEAD")") { merge(c, $0) }
    }
    static func rebaseDialog(_ c: RepoController, onto: Ref?) {
        if let onto { return rebase(c, onto.shortName) }
        pickBranch(c, title: "Rebase \(c.currentBranch ?? "HEAD") onto") { rebase(c, $0) }
    }
    static func merge(_ c: RepoController, _ ref: String) { Sheets.present(MergeDialog(controller: c, ref: ref), on: c.window) }
    static func rebase(_ c: RepoController, _ onto: String) { Sheets.present(RebaseDialog(controller: c, onto: onto), on: c.window) }

    static func pickBranch(_ c: RepoController, title: String, _ then: @escaping (String) -> Void) {
        let names = (c.localBranches.filter { !$0.isHead } + c.remoteBranches).map(\.shortName)
        guard !names.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = title
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: names)
        a.accessoryView = popup
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, let name = popup.titleOfSelectedItem else { return }
        then(name)
    }

    static func interactiveRebase(_ c: RepoController, from commit: Commit) {
        let base = commit.parents.first
        Sheets.present(InteractiveRebaseView(controller: c, base: base, baseTitle: base.map { String($0.prefix(7)) } ?? "root"), on: c.window)
    }

    static func quick(_ c: RepoController, _ commit: Commit, _ action: Repository.QuickAction) {
        let sha = commit.sha
        if case .drop = action {
            let a = NSAlert()
            a.messageText = "Drop \(commit.shortSHA) \(commit.subject)?"
            a.informativeText = "The commit is removed from \(c.currentBranch ?? "the branch"). ⌘Z undoes it."
            a.addButton(withTitle: "Drop")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        c.rewrite("Rewrite \(commit.shortSHA)") { try await $0.quickRewrite(sha, action) }
    }

    static func reword(_ c: RepoController, _ commit: Commit) {
        Task {
            let d = try? await c.repo.details(commit.sha)
            let current = d.map { $0.body.isEmpty ? $0.commit.subject : "\($0.commit.subject)\n\n\($0.body)" } ?? commit.subject
            guard let message = RepoActions.prompt("Reword \(commit.shortSHA)", value: current, action: "Reword") else { return }
            quick(c, commit, .reword(message))
        }
    }

    static func predictConflicts(_ c: RepoController, ours: String, theirs: String) async -> String {
        guard let paths = await c.repo.predictConflicts(ours: ours, theirs: theirs) else { return "" }
        if paths.isEmpty { return "✓ No conflicts expected" }
        return "⚠ \(paths.count) file\(paths.count == 1 ? "" : "s") will conflict: " + paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? "…" : "")
    }
}

extension RepoActions {
    static func notYet(_ feature: String) {
        let a = NSAlert()
        a.messageText = "\(feature) isn't available yet"
        a.informativeText = "It's coming in a later Spoon milestone."
        a.runModal()
    }
}
