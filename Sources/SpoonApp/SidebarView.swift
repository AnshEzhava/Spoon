import AppKit
import SwiftUI
import SpoonKit

/// Repository sidebar (§5.6): views, then tags, stashes and worktrees. Branches live in the toolbar branch control.
struct SidebarView: View {
    @Bindable var controller: RepoController
    @State private var filter = ""
    @State private var selection: String?
    @AppStorage("sidebar.collapsed") private var collapsedRaw = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    viewRow("Local Changes", "tray.full", .localChanges, count: controller.changeCount)
                    viewRow("All Commits", "point.3.connected.trianglepath.dotted", .history, count: nil)
                }
                if let op = controller.operation {
                    Section { Label("\(op.title) in progress", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                section("Tags", "TAGS", refs: controller.tags.sorted { $0.date > $1.date }, prefix: "refs/tags/", icon: "tag")
                if !controller.stashes.isEmpty {
                    Section(isExpanded: expanded("STASHES")) {
                        ForEach(controller.stashes.filter { filter.isEmpty || $0.message.localizedCaseInsensitiveContains(filter) }) { s in
                            HStack {
                                Label(s.message, systemImage: "archivebox").lineLimit(1)
                                Spacer()
                                Text(Format.age(Date(timeIntervalSince1970: TimeInterval(s.date)))).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag("stash:\(s.sha)")
                            .contextMenu { StashMenu(controller: controller, stash: s) }
                        }
                    } header: { Text("Stashes (\(controller.stashes.count))") }
                }
                WorktreeSections(controller: controller, expanded: expanded)
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, sel in handle(sel) }
            .onChange(of: controller.view) { _, v in
                let tag = v == .localChanges ? "view:local" : "view:history"
                if selection?.hasPrefix("view:") == true || selection == nil { selection = tag }
            }
            .onAppear { selection = controller.view == .localChanges ? "view:local" : "view:history" }
            Divider()
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(6)
        }
    }

    func viewRow(_ title: String, _ icon: String, _ view: RepoView, count: Int?) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if let count, count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .tag(view == .localChanges ? "view:local" : "view:history")
    }

    func expanded(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedRaw.split(separator: "\n").contains(Substring(key)) },
            set: { open in
                var set = Set(collapsedRaw.split(separator: "\n").map(String.init))
                if open { set.remove(key) } else { set.insert(key) }
                collapsedRaw = set.sorted().joined(separator: "\n")
            })
    }

    @ViewBuilder
    func section(_ title: String, _ key: String, refs: [Ref], prefix: String, icon: String = "arrow.triangle.branch") -> some View {
        let shown = filter.isEmpty ? refs : refs.filter { $0.shortName.localizedCaseInsensitiveContains(filter) }
        if !refs.isEmpty {
            Section(isExpanded: expanded(key)) {
                RefTree(nodes: RefNode.tree(shown, prefix: prefix), controller: controller, icon: icon)
            } header: {
                Text(title)
            }
        }
    }

    func handle(_ sel: String?) {
        guard let sel else { return }
        if sel == "view:local" { controller.view = .localChanges }
        else if sel == "view:history" { controller.view = .history }
        else if sel.hasPrefix("ref:"), let ref = controller.refs.first(where: { "ref:\($0.name)" == sel }) { controller.reveal(ref) }
        else if sel.hasPrefix("stash:") { controller.view = .history; controller.select(String(sel.dropFirst(6))) }
    }
}

/// Folder tree from `/` in ref names.
struct RefNode: Identifiable {
    var id: String
    var name: String
    var ref: Ref?
    var children: [RefNode]?

    static func tree(_ refs: [Ref], prefix: String) -> [RefNode] {
        final class Folder { var folders: [String: Folder] = [:]; var order: [String] = []; var refs: [Ref] = [] }
        let root = Folder()
        for ref in refs {
            var parts = String(ref.name.dropFirst(prefix.count)).split(separator: "/").map(String.init)
            parts.removeLast()
            var f = root
            for p in parts {
                if f.folders[p] == nil { f.folders[p] = Folder(); f.order.append(p) }
                f = f.folders[p]!
            }
            f.refs.append(ref)
        }
        func build(_ f: Folder, path: String) -> [RefNode] {
            let folders = f.order.sorted().map { name in
                RefNode(id: "folder:\(prefix)\(path)\(name)", name: name, ref: nil, children: build(f.folders[name]!, path: "\(path)\(name)/"))
            }
            let leaves = f.refs.map { RefNode(id: "ref:\($0.name)", name: $0.name.split(separator: "/").last.map(String.init) ?? $0.name, ref: $0, children: nil) }
            return folders + leaves
        }
        return build(root, path: "")
    }
}

struct RefTree: View {
    let nodes: [RefNode]
    let controller: RepoController
    let icon: String

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup {
                    RefTree(nodes: children, controller: controller, icon: icon)
                } label: {
                    Label(node.name, systemImage: "folder")
                }
            } else if let ref = node.ref {
                RefRow(ref: ref, name: node.name, icon: icon, controller: controller).tag(node.id)
            }
        }
    }
}

struct RefRow: View {
    let ref: Ref
    let name: String
    let icon: String
    let controller: RepoController

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: ref.isHead ? "checkmark" : ref.worktreePath != nil && !ref.isHead ? "square.stack.3d.up" : icon)
                .foregroundStyle(ref.kind == .localBranch && ref.upstream == nil ? .tertiary : .secondary)
                .frame(width: 16)
            Text(name).fontWeight(ref.isHead ? .bold : .regular).lineLimit(1)
            if ref.upstreamGone {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help("Upstream '\(ref.upstream.map { String($0.dropFirst("refs/remotes/".count)) } ?? "")' no longer exists")
            }
            Spacer()
            if ref.ahead > 0 { Text("↑\(ref.ahead)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if ref.behind > 0 { Text("↓\(ref.behind)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .contextMenu { RefMenu(controller: controller, ref: ref) }
        .onTapGesture(count: 2) { controller.doubleClick(ref) }
        .simultaneousGesture(TapGesture().onEnded { controller.reveal(ref) })
        .accessibilityElement(children: .combine)
    }
}

/// Worktrees and submodules (WT-01, SUB-01).
private struct WorktreeSections: View {
    let controller: RepoController
    let expanded: (String) -> Binding<Bool>

    var body: some View {
        // The main worktree is this tab; list the others (WT-01).
        let worktrees = controller.worktrees.filter { $0.path != controller.repo.workTree.path }
        if !worktrees.isEmpty {
            Section(isExpanded: expanded("WORKTREES")) {
                ForEach(worktrees) { w in
                    HStack {
                        Label(w.name, systemImage: "square.stack.3d.up")
                        Spacer()
                        Text(w.branch ?? w.head.map { String($0.prefix(7)) } ?? "").font(.caption).foregroundStyle(.secondary)
                        if w.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    }
                    .help(w.path)
                    .onTapGesture(count: 2) { AppDelegate.shared.openRepo(path: w.path, newTab: true) }
                    .contextMenu { Button("Open in New Tab") { AppDelegate.shared.openRepo(path: w.path, newTab: true) } }
                }
            } header: { Text("Worktrees (\(worktrees.count))") }
        }
        if !controller.submodules.isEmpty {
            Section(isExpanded: expanded("SUBMODULES")) {
                ForEach(controller.submodules) { m in
                    let path = controller.repo.workTree.appendingPathComponent(m.path).path
                    HStack {
                        Label(m.path, systemImage: "shippingbox")
                        Spacer()
                        switch m.state {
                        case .changed: Text("changed").font(.caption).foregroundStyle(.orange)
                        case .uninitialized: Text("not initialized").font(.caption).foregroundStyle(.secondary)
                        case .conflict: Text("conflict").font(.caption).foregroundStyle(.red)
                        case .clean: EmptyView()
                        }
                    }
                    .onTapGesture(count: 2) { if m.state != .uninitialized { AppDelegate.shared.openRepo(path: path, newTab: true) } }
                    .contextMenu {
                        Button("Open in New Tab") { AppDelegate.shared.openRepo(path: path, newTab: true) }.disabled(m.state == .uninitialized)
                        Button(m.state == .uninitialized ? "Initialize & Update" : "Update") {
                            let p = m.path
                            controller.perform("Update \(p)") { repo, out in
                                _ = try await repo.write(["submodule", "update", "--init", "--recursive", "--", p], output: out)
                            }
                        }
                    }
                }
            } header: { Text("Submodules (\(controller.submodules.count))") }
        }
    }
}
