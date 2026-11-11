import AppKit
import SwiftUI
import SpoonKit

/// Last-used dialog options, remembered per repo (§5.13).
@MainActor
enum DialogMemory {
    static func get<T: Codable>(_ c: RepoController?, _ key: String, _ fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: "dlg:\(c?.repo.workTree.path ?? ""):\(key)"),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return v
    }
    static func set<T: Codable>(_ c: RepoController?, _ key: String, _ value: T) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "dlg:\(c?.repo.workTree.path ?? ""):\(key)")
    }
}

struct LocalChangesPicker: View {
    @Binding var mode: LocalChangesMode
    var body: some View {
        Picker("Local changes:", selection: $mode) {
            ForEach(LocalChangesMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.radioGroup)
    }
}

struct FetchDialog: View {
    let controller: RepoController
    @State private var remote = "--all"
    @State private var prune = true
    @State private var tags = false

    var body: some View {
        Dialog(title: "Fetch", subtitle: "Download new commits and refs without changing your branches.",
               command: "git fetch --progress\(prune ? " --prune" : "")\(tags ? " --tags" : "") \(remote)", action: "Fetch", onConfirm: run) {
            Picker("Remote:", selection: $remote) {
                Text("All remotes").tag("--all")
                ForEach(controller.remotes) { Text($0.name).tag($0.name) }
            }
            Toggle("Prune deleted remote branches", isOn: $prune)
            Toggle("Fetch all tags", isOn: $tags)
        }
        .onAppear {
            prune = DialogMemory.get(controller, "fetch.prune", true)
            tags = DialogMemory.get(controller, "fetch.tags", false)
        }
    }

    func run() {
        DialogMemory.set(controller, "fetch.prune", prune)
        DialogMemory.set(controller, "fetch.tags", tags)
        let r = remote == "--all" ? nil : remote, p = prune, t = tags
        controller.perform("Fetch", context: .fetch) { repo, out in try await repo.fetch(remote: r, prune: p, tags: t, output: out) }
    }
}

struct PullDialog: View {
    let controller: RepoController
    @State private var remote = ""
    @State private var branch = ""
    @State private var strategy: PullStrategy = .ffOnly
    @State private var mode: LocalChangesMode = .keep
    @State private var prediction = ""

    var body: some View {
        Dialog(title: "Pull", subtitle: "Fetch and integrate \(remote)/\(branch) into \(controller.currentBranch ?? "HEAD").",
               command: "git pull \(strategy.flag)\(mode == .stash ? " --autostash" : "") \(remote) \(branch)",
               action: "Pull", disabled: remote.isEmpty || branch.isEmpty, onConfirm: run) {
            Picker("Remote:", selection: $remote) { ForEach(controller.remotes) { Text($0.name).tag($0.name) } }
            Picker("Branch:", selection: $branch) {
                ForEach(controller.remoteBranches.filter { $0.remoteName == remote }) { r in
                    let b = String(r.shortName.dropFirst(remote.count + 1))
                    Text(b).tag(b)
                }
            }
            LabeledContent("Into:") { Text(controller.currentBranch ?? "detached HEAD") }
            Picker("Strategy:", selection: $strategy) {
                ForEach(PullStrategy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            LocalChangesPicker(mode: $mode)
            if !prediction.isEmpty { LabeledContent("") { Text(prediction).font(.system(size: 11)) } }
        }
        .onAppear {
            let up = controller.upstream
            remote = up?.remoteName ?? controller.remotes.first?.name ?? ""
            branch = up.map { String($0.shortName.dropFirst(remote.count + 1)) } ?? controller.currentBranch ?? ""
            strategy = DialogMemory.get(controller, "pull.strategy", controller.defaultPullStrategy)
            predict()
        }
        .onChange(of: branch) { _, _ in predict() }
    }

    func predict() {
        let target = "refs/remotes/\(remote)/\(branch)"
        Task { prediction = await HistoryActions.predictConflicts(controller, ours: "HEAD", theirs: target) }
    }

    func run() {
        DialogMemory.set(controller, "pull.strategy", strategy)
        let r = remote, b = branch, s = strategy, m = mode
        controller.perform("Pull \(r)/\(b)", context: .pull) { repo, out in
            try await repo.pull(remote: r, branch: b, strategy: s, localChanges: m, output: out)
        }
    }
}

/// Publish to GitHub: create the repository with the signed-in account, add it as origin, push the current branch.
struct PublishDialog: View {
    let controller: RepoController
    @State private var name = ""
    @State private var about = ""
    @State private var isPrivate = true
    private let login = Accounts.login(for: AccountsPane.host)

    var body: some View {
        let branch = controller.currentBranch ?? ""
        let blocker = login == nil ? "Sign in to GitHub to publish this repository."
            : controller.headSHA == nil ? "Make a commit first: there's nothing to push yet."
            : branch.isEmpty ? "Check out a branch first: HEAD is detached." : nil
        Dialog(title: "Publish to GitHub",
               subtitle: blocker ?? "Create a repository on github.com as \(login!) and push \(branch) to it.",
               command: login == nil ? "" : "git remote add origin https://github.com/\(login!)/\(name).git && git push -u origin \(branch)",
               action: login == nil ? "Sign In…" : "Publish",
               disabled: login != nil && (blocker != nil || name.isEmpty),
               onConfirm: login == nil ? Self.openAccounts : run) {
            if login != nil {
                TextField("Name:", text: $name)
                TextField("Description:", text: $about, prompt: Text("Optional"))
                Toggle("Private", isOn: $isPrivate)
            }
        }
        .onAppear { name = controller.name }
    }

    static func openAccounts() {
        UserDefaults.standard.set("accounts", forKey: "settings.tab")
        AppDelegate.shared.showSettings(nil)
    }

    func run() {
        guard let branch = controller.currentBranch else { return }
        let n = name, d = about, p = isPrivate, host = AccountsPane.host
        controller.perform("Publish to GitHub", context: .push) { repo, out in
            guard let token = Accounts.credential(host: host)?.token else {
                throw GitHub.AuthError(description: "Couldn't read your GitHub token from the Keychain. Sign in again in Settings ▸ Accounts.")
            }
            let created = try await GitHub.createRepo(name: n, description: d, isPrivate: p, token: token)
            // Created but push failed → origin is already set, so a plain Push finishes the job.
            try await repo.addRemote("origin", url: created.cloneURL)
            try await repo.push([PushSpec(local: branch, remote: "origin", remoteBranch: branch)], options: PushOptions(setUpstream: true), output: out)
        }
    }
}

struct PushDialog: View {
    let controller: RepoController
    var force = false
    @State private var remote = ""
    @State private var branches: [String: Bool] = [:]
    @State private var targets: [String: String] = [:]
    @State private var setUpstream = true
    @State private var tags = false
    @State private var forceWithLease = false
    @State private var noVerify = false
    @State private var overwritten: [Commit] = []

    var body: some View {
        let selected = controller.localBranches.filter { branches[$0.shortName] == true }
        Dialog(title: "Push", subtitle: "Upload commits to \(remote). Pushing can't be undone.",
               command: "git push\(setUpstream ? " -u" : "")\(forceWithLease ? " --force-with-lease" : "")\(noVerify ? " --no-verify" : "")\(tags ? " --follow-tags" : "") \(remote) "
                + selected.map { "\($0.shortName):\(targets[$0.shortName] ?? $0.shortName)" }.joined(separator: " "),
               action: forceWithLease ? "Force Push" : "Push", disabled: selected.isEmpty || remote.isEmpty, destructive: forceWithLease, onConfirm: run) {
            Picker("Remote:", selection: $remote) { ForEach(controller.remotes) { Text($0.name).tag($0.name) } }
            LabeledContent("Branches:") {
                VStack(alignment: .leading) {
                    ForEach(controller.localBranches.filter { $0.isHead || $0.ahead > 0 || branches[$0.shortName] == true }) { b in
                        HStack {
                            Toggle(b.shortName, isOn: Binding(get: { branches[b.shortName] ?? false }, set: { branches[b.shortName] = $0 }))
                            Text("→ \(remote):").foregroundStyle(.secondary)
                            TextField("", text: Binding(get: { targets[b.shortName] ?? b.shortName }, set: { targets[b.shortName] = $0 }))
                                .frame(width: 140)
                            if b.ahead > 0 { Text("↑\(b.ahead)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }
                }
            }
            if let h = controller.headRef, h.behind > 0 {
                LabeledContent("") { Label("Remote is ahead by \(h.behind): pull first?", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Toggle("Set upstream", isOn: $setUpstream)
            Toggle("Push tags (annotated, following commits)", isOn: $tags)
            Toggle("Force with lease ⚠", isOn: $forceWithLease)
            if forceWithLease && !overwritten.isEmpty {
                LabeledContent("Overwrites:") {
                    VStack(alignment: .leading) {
                        ForEach(overwritten.prefix(8)) { c in Text("\(c.shortSHA) \(c.subject)").font(.system(size: 11)).lineLimit(1) }
                        if overwritten.count > 8 { Text("+\(overwritten.count - 8) more").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
            }
            Toggle("Skip pre-push hook", isOn: $noVerify)
        }
        .onAppear {
            remote = controller.upstream?.remoteName ?? controller.remotes.first?.name ?? ""
            if let b = controller.currentBranch { branches[b] = true }
            setUpstream = controller.upstream == nil
            forceWithLease = force
            loadOverwritten()
        }
        .onChange(of: forceWithLease) { _, _ in loadOverwritten() }
    }

    func loadOverwritten() {
        guard forceWithLease, let b = controller.currentBranch else { overwritten = []; return }
        let target = targets[b] ?? b
        Task { overwritten = await controller.repo.commitsOverwritten(remoteRef: "refs/remotes/\(remote)/\(target)", by: "refs/heads/\(b)") }
    }

    func run() {
        let specs = controller.localBranches.filter { branches[$0.shortName] == true }
            .map { PushSpec(local: $0.shortName, remote: remote, remoteBranch: targets[$0.shortName] ?? $0.shortName) }
        let opts = PushOptions(setUpstream: setUpstream, forceWithLease: forceWithLease, tags: tags, noVerify: noVerify)
        controller.perform("Push", context: .push) { repo, out in try await repo.push(specs, options: opts, output: out) }
    }
}

struct NewBranchDialog: View {
    let controller: RepoController
    let start: String
    @State private var name = ""
    @State private var checkout = true
    @State private var track = false
    @State private var mode: LocalChangesMode = .keep
    @State private var valid = false

    var sanitized: String {
        name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }

    var body: some View {
        Dialog(title: "New Branch", subtitle: "Create a branch at \(start.count == 40 ? String(start.prefix(7)) : start).",
               command: checkout ? "git switch -c \(sanitized)\(track ? " --track" : "") \(start)" : "git branch \(sanitized) \(start)",
               action: "Create Branch", disabled: !valid, onConfirm: run) {
            TextField("Name:", text: $name, prompt: Text("feature/name"))
            LabeledContent("Start at:") { Text(start.count == 40 ? String(start.prefix(7)) : start).font(.system(.body, design: .monospaced)) }
            Toggle("Check out", isOn: $checkout)
            if start.hasPrefix("refs/remotes/") || controller.remoteBranches.contains(where: { $0.shortName == start }) {
                Toggle("Track remote branch", isOn: $track)
            }
            if checkout { LocalChangesPicker(mode: $mode) }
            if !name.isEmpty && !valid { LabeledContent("") { Text("Not a valid branch name").foregroundStyle(.red).font(.system(size: 11)) } }
        }
        .onChange(of: name) { _, _ in
            let n = sanitized
            Task { valid = await controller.repo.validateBranchName(n) && !controller.localBranches.contains { $0.shortName == n } }
        }
    }

    func run() {
        let n = sanitized, s = start, co = checkout, t = track, m = mode
        controller.perform("Create branch \(n)") { repo, _ in try await repo.createBranch(n, at: s, checkout: co, track: t, localChanges: m) }
    }
}

struct RenameBranchDialog: View {
    let controller: RepoController
    let ref: Ref
    @State private var name = ""
    @State private var onRemote = false

    var body: some View {
        Dialog(title: "Rename Branch", subtitle: "Rename \(ref.shortName).", command: "git branch -m \(ref.shortName) \(name)",
               action: "Rename", disabled: name.isEmpty || name == ref.shortName, onConfirm: run) {
            TextField("New name:", text: $name)
            if let up = ref.upstream { Toggle("Also rename on remote (\(up.replacingOccurrences(of: "refs/remotes/", with: "")))", isOn: $onRemote) }
        }
        .onAppear { name = ref.shortName }
    }

    func run() {
        let old = ref.shortName, new = name.replacingOccurrences(of: " ", with: "-")
        let remote = onRemote ? ref.upstream.flatMap { u in controller.refs.first { $0.name == u }?.remoteName } : nil
        controller.perform("Rename \(old)") { repo, out in
            try await repo.renameBranch(old, to: new)
            if let remote {
                try await repo.push([PushSpec(local: new, remote: remote, remoteBranch: new)], options: PushOptions(setUpstream: true), output: out)
                try await repo.deleteRemoteBranch(remote: remote, branch: old)
            }
        }
    }
}

struct DeleteBranchDialog: View {
    let controller: RepoController
    let refs: [Ref]
    @State private var alsoRemote = false
    @State private var unmerged: [String: Int] = [:]

    var body: some View {
        let lost = unmerged.values.reduce(0, +)
        Dialog(title: refs.count == 1 ? "Delete Branch \(refs[0].shortName)" : "Delete \(refs.count) Branches",
               subtitle: "Local branch deletion can be undone with ⌘Z.",
               command: "git branch -D " + refs.map(\.shortName).joined(separator: " "),
               action: "Delete", destructive: true, onConfirm: run) {
            LabeledContent("Branches:") { Text(refs.map(\.shortName).joined(separator: ", ")) }
            if refs.contains(where: { $0.upstream != nil }) { Toggle("Also delete remote branch (can't be undone)", isOn: $alsoRemote) }
            if lost > 0 {
                LabeledContent("") {
                    Label("\(lost) commit\(lost == 1 ? "" : "s") will only be reachable via Undo", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .task {
            let main = controller.refs.first { ["refs/heads/main", "refs/heads/master"].contains($0.name) }?.name
            for r in refs { unmerged[r.shortName] = await controller.repo.unmergedCount(r.shortName, upstream: r.upstream, main: main) }
        }
    }

    func run() {
        let names = refs.map(\.shortName)
        let remotes: [(String, String)] = alsoRemote ? refs.compactMap { r in
            guard let up = r.upstream, let rr = controller.refs.first(where: { $0.name == up }), let remote = rr.remoteName else { return nil }
            return (remote, String(rr.shortName.dropFirst(remote.count + 1)))
        } : []
        controller.perform("Delete branch") { repo, _ in
            try await repo.deleteBranches(names, force: true)
            for (remote, branch) in remotes { try await repo.deleteRemoteBranch(remote: remote, branch: branch) }
        }
    }
}

struct StashDialog: View {
    let controller: RepoController
    var paths: [String] = []
    @State private var message = ""
    @State private var untracked = false
    @State private var keepIndex = false
    @State private var stagedOnly = false

    var body: some View {
        Dialog(title: paths.isEmpty ? "Stash" : "Stash \(paths.count) File\(paths.count == 1 ? "" : "s")",
               subtitle: "Save local changes and revert the working copy.",
               command: "git stash push" + (message.isEmpty ? "" : " -m \"\(message)\"") + (untracked ? " -u" : "") + (keepIndex ? " --keep-index" : "")
                + (stagedOnly ? " --staged" : "") + (paths.isEmpty ? "" : " -- " + paths.joined(separator: " ")),
               action: "Stash", onConfirm: run) {
            TextField("Message:", text: $message, prompt: Text("Optional"))
            Toggle("Include untracked files", isOn: $untracked)
            Toggle("Keep staged changes", isOn: $keepIndex)
            Toggle("Only staged changes", isOn: $stagedOnly)
        }
    }

    func run() {
        let m = message, u = untracked, k = keepIndex, s = stagedOnly, p = paths
        controller.perform("Stash") { repo, _ in try await repo.stash(message: m, includeUntracked: u, keepIndex: k, stagedOnly: s, paths: p) }
    }
}

struct NewTagDialog: View {
    let controller: RepoController
    let target: String
    @State private var name = ""
    @State private var annotated = true
    @State private var message = ""
    @State private var push = false
    @State private var remote = ""

    var body: some View {
        Dialog(title: "New Tag", subtitle: "Tag \(target.count == 40 ? String(target.prefix(7)) : target).",
               command: "git tag\(annotated ? " -a -m \"\(message.isEmpty ? name : message)\"" : "") \(name) \(target.prefix(12))" + (push ? " && git push \(remote) refs/tags/\(name)" : ""),
               action: "Create Tag", disabled: name.isEmpty, onConfirm: run) {
            TextField("Name:", text: $name, prompt: Text(suggestion ?? "v1.0.0"))
            Toggle("Annotated", isOn: $annotated)
            if annotated { TextField("Message:", text: $message, axis: .vertical).lineLimit(2...5) }
            if !controller.remotes.isEmpty {
                Toggle("Push to", isOn: $push)
                if push { Picker("Remote:", selection: $remote) { ForEach(controller.remotes) { Text($0.name).tag($0.name) } } }
            }
        }
        .onAppear { remote = controller.remotes.first?.name ?? ""; name = suggestion ?? "" }
    }

    /// Next semver patch after the highest version tag (TAG-06).
    var suggestion: String? {
        let versions = controller.tags.compactMap { t -> (String, [Int])? in
            let s = t.shortName.hasPrefix("v") ? String(t.shortName.dropFirst()) : t.shortName
            let parts = s.split(separator: ".").compactMap { Int($0) }
            return parts.count == 3 ? (t.shortName.hasPrefix("v") ? "v" : "", parts) : nil
        }
        guard let top = versions.max(by: { $0.1.lexicographicallyPrecedes($1.1) }) else { return nil }
        return "\(top.0)\(top.1[0]).\(top.1[1]).\(top.1[2] + 1)"
    }

    func run() {
        let n = name, t = target, m = annotated ? (message.isEmpty ? name : message) : nil, r = push ? remote : nil
        controller.perform("Create tag \(n)") { repo, _ in
            try await repo.createTag(n, at: t, message: m)
            if let r { try await repo.pushTags([n], remote: r) }
        }
    }
}

struct RemoteDialog: View {
    let controller: RepoController
    let remote: Remote?
    @State private var name = ""
    @State private var url = ""
    @State private var pushURL = ""
    @State private var test = ""
    @State private var fetchNow = true

    var body: some View {
        Dialog(title: remote == nil ? "Add Remote" : "Edit Remote \(remote!.name)", subtitle: "",
               command: remote == nil ? "git remote add \(name) \(url)" : "git remote set-url \(name) \(url)",
               action: remote == nil ? "Add Remote" : "Save", disabled: name.isEmpty || url.isEmpty, onConfirm: run) {
            TextField("Name:", text: $name, prompt: Text("origin"))
            TextField("Fetch URL:", text: $url, prompt: Text("git@github.com:owner/repo.git"))
            TextField("Push URL:", text: $pushURL, prompt: Text("Same as fetch URL"))
            HStack {
                Button(url.hasPrefix("http") ? "Switch to SSH" : "Switch to HTTPS") { url = Self.switchProtocol(url) }.disabled(url.isEmpty)
                Button("Test Connection") {
                    test = "Testing…"
                    let u = url
                    Task { let r = await controller.repo.testConnection(u); test = (r.ok ? "✓ " : "✗ ") + r.message }
                }
                .disabled(url.isEmpty)
                Text(test).font(.system(size: 11)).foregroundStyle(test.hasPrefix("✗") ? .red : .secondary)
            }
            if remote == nil { Toggle("Fetch now", isOn: $fetchNow) }
        }
        .onAppear {
            name = remote?.name ?? (controller.remotes.isEmpty ? "origin" : "")
            url = remote?.fetchURL ?? ""
            pushURL = remote.map { $0.pushURL == $0.fetchURL ? "" : $0.pushURL } ?? ""
        }
    }

    /// `git@host:o/r.git` ⇄ `https://host/o/r.git`
    static func switchProtocol(_ url: String) -> String {
        if url.hasPrefix("https://"), let u = URL(string: url), let host = u.host {
            return "git@\(host):\(u.path.dropFirst())"
        }
        if let at = url.firstIndex(of: "@"), let colon = url.firstIndex(of: ":"), at < colon {
            return "https://\(url[url.index(after: at)..<colon])/\(url[url.index(after: colon)...])"
        }
        return url
    }

    func run() {
        let n = name, u = url, p = pushURL, old = remote?.name, f = fetchNow
        controller.perform(old == nil ? "Add remote \(n)" : "Edit remote \(n)") { repo, out in
            if let old { try await repo.editRemote(old, newName: n, url: u, pushURL: p) } else {
                try await repo.addRemote(n, url: u, pushURL: p)
                if f { try await repo.fetch(remote: n, output: out) }
            }
        }
    }
}

struct CloneDialog: View {
    @State var url: String
    @State private var location = DialogMemory.get(nil, "clone.location", NSHomeDirectory() + "/Code")
    @State private var name = ""
    @State private var branch = ""
    @State private var recurse = false
    @State private var shallow = false
    @State private var depth = 1
    @State private var partial = false
    @State private var group: UUID?
    @State private var test = ""
    @State private var progress = ""
    @State private var running = false
    @State private var error: String?
    @State private var repos: [GitHub.Repo] = []
    @State private var reposStatus = ""
    @State private var filter = ""
    @State private var picked: String?
    private let login = Accounts.login(for: AccountsPane.host)
    @Environment(\.dismissSheet) private var dismiss

    var derivedName: String {
        var n = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        if n.hasSuffix(".git") { n.removeLast(4) }
        return n
    }

    var shownRepos: [GitHub.Repo] {
        guard !filter.isEmpty else { return repos }
        return repos.compactMap { r in Fuzzy.score(r.fullName, filter).map { (r, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Repository").font(.system(size: 14, weight: .bold))
            Form {
                LabeledContent("GitHub:") {
                    if login == nil {
                        Button("Sign in to browse your repositories…") { dismiss(); PublishDialog.openAccounts() }.buttonStyle(.link)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("", text: $filter, prompt: Text("Filter repositories"))
                            List(shownRepos, selection: $picked) { r in
                                HStack {
                                    Text(r.fullName)
                                    Spacer()
                                    if r.isPrivate { Image(systemName: "lock").foregroundStyle(.secondary) }
                                }
                            }
                            .listStyle(.bordered(alternatesRowBackgrounds: true))
                            .frame(height: 160)
                            if !reposStatus.isEmpty { Text(reposStatus).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                    }
                }
                TextField("URL:", text: $url, prompt: Text("https://github.com/owner/repo.git"))
                HStack {
                    Button(url.hasPrefix("http") ? "Switch to SSH" : "Switch to HTTPS") { url = RemoteDialog.switchProtocol(url) }.disabled(url.isEmpty)
                    Button("Test Connection") {
                        test = "Testing…"
                        let u = url
                        Task {
                            let git = await AppModel.shared.git()
                            let r = try? await git.run(["ls-remote", "--heads", u], check: false)
                            test = r?.status == 0 ? "✓ Connected" : "✗ " + GitFailure.classify(r?.errorOutput ?? "").summary
                        }
                    }
                    .disabled(url.isEmpty)
                    Text(test).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Location:", text: $location)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { location = u.path }
                    }
                }
                TextField("Name:", text: $name, prompt: Text(derivedName))
                TextField("Branch:", text: $branch, prompt: Text("Default branch"))
                Toggle("Recurse submodules", isOn: $recurse)
                HStack {
                    Toggle("Shallow, depth", isOn: $shallow)
                    TextField("", value: $depth, format: .number).frame(width: 50).disabled(!shallow)
                }
                Toggle("Partial clone (--filter=blob:none)", isOn: $partial)
                if !AppModel.shared.library.groups.isEmpty {
                    Picker("Add to group:", selection: $group) {
                        Text("None").tag(UUID?.none)
                        ForEach(AppModel.shared.library.groups) { g in Text(AppModel.shared.library.path(of: g)).tag(Optional(g.id)) }
                    }
                }
            }
            .formStyle(.columns)
            if running { ProgressView(progress.isEmpty ? "Cloning…" : progress).progressViewStyle(.linear) }
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 11)).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clone") { run() }.keyboardShortcut(.defaultAction).disabled(url.isEmpty || running)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: picked) {
            guard let r = repos.first(where: { $0.id == picked }) else { return }
            url = r.cloneURL
            test = ""
        }
        .task {
            guard login != nil else { return }
            guard let token = Accounts.credential(host: AccountsPane.host)?.token else {
                reposStatus = "Couldn't read your GitHub token from the Keychain. Sign in again in Settings ▸ Accounts."
                return
            }
            reposStatus = "Loading…"
            do {
                repos = try await GitHub.repos(token: token)
                reposStatus = repos.isEmpty ? "No repositories found." : ""
            } catch {
                reposStatus = "\(error)"
            }
        }
        .onAppear {
            if url.isEmpty, let s = NSPasteboard.general.string(forType: .string),
               s.hasPrefix("https://") || s.hasPrefix("git@") || s.hasPrefix("ssh://") { url = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    func run() {
        let dest = URL(fileURLWithPath: location).appendingPathComponent(name.isEmpty ? derivedName : name)
        DialogMemory.set(nil, "clone.location", location)
        running = true
        error = nil
        let u = url, b = branch, d = shallow ? depth : nil, p = partial, r = recurse, g = group
        Task {
            do {
                let git = await AppModel.shared.git()
                try await RepoCreation.clone(url: u, into: dest, branch: b, depth: d, partial: p, recurseSubmodules: r, git: git) { text in
                    if let pr = GitProgress.parse(text) { DispatchQueue.main.async { MainActor.assumeIsolated { progress = pr } } }
                }
                AppModel.shared.updateLibrary { lib in
                    let id = lib.add(path: dest.path)
                    if let g { lib.addMembers([id], to: g) }
                }
                dismiss()
                AppDelegate.shared.openRepo(path: dest.path)
            } catch {
                running = false
                self.error = (error as? GitError).map { GitFailure.classify($0.stderr).summary + "\n" + $0.stderr } ?? "\(error)"
            }
        }
    }
}

struct InitDialog: View {
    @State private var location = DialogMemory.get(nil, "clone.location", NSHomeDirectory() + "/Code")
    @State private var name = ""
    @State private var branch = "main"
    @State private var template = ""
    @State private var readme = true
    @State private var initialCommit = true
    @State private var error: String?
    @Environment(\.dismissSheet) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Repository").font(.system(size: 14, weight: .bold))
            Form {
                HStack {
                    TextField("Location:", text: $location)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { location = u.path }
                    }
                }
                TextField("Name:", text: $name, prompt: Text("my-project"))
                TextField("Initial branch:", text: $branch)
                Picker(".gitignore:", selection: $template) {
                    Text("None").tag("")
                    ForEach(RepoCreation.gitignoreTemplates.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }
                Toggle("README", isOn: $readme)
                Toggle("Initial commit", isOn: $initialCommit)
            }
            .formStyle(.columns)
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Repository") { run() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            let git = await AppModel.shared.git()
            if let b = try? await git.run(["config", "--get", "init.defaultBranch"], check: false), b.status == 0 {
                branch = b.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    func run() {
        let dest = URL(fileURLWithPath: location).appendingPathComponent(name)
        let b = branch, r = readme, ic = initialCommit, t = RepoCreation.gitignoreTemplates[template]
        Task {
            do {
                try await RepoCreation.initialize(at: dest, branch: b.isEmpty ? nil : b, readme: r, gitignore: t, initialCommit: ic, git: await AppModel.shared.git())
                AppModel.shared.updateLibrary { $0.add(path: dest.path) }
                dismiss()
                AppDelegate.shared.openRepo(path: dest.path)
            } catch {
                self.error = "\(error)"
            }
        }
    }
}

/// Operation History panel (UNDO-03): every journaled operation, with undo/redo.
struct OperationHistoryView: View {
    let controller: RepoController
    @State private var entries: [OpLogEntry] = []
    @State private var undoID: UUID?
    @State private var redoID: UUID?
    @Environment(\.dismissSheet) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Operation History").font(.system(size: 14, weight: .bold))
            List(entries.reversed()) { e in
                HStack {
                    Image(systemName: e.kind == .remote ? "icloud.and.arrow.up" : e.kind == .undo ? "arrow.uturn.backward" : e.kind == .redo ? "arrow.uturn.forward" : "circle.fill")
                        .foregroundStyle(e.kind == .remote ? .secondary : .primary).frame(width: 16)
                    VStack(alignment: .leading) {
                        Text(e.title)
                        Text(Format.age(e.ts) + (e.kind == .remote ? " · can't be undone" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.id == undoID { Text("⌘Z").font(.caption).foregroundStyle(.secondary) }
                    if e.id == redoID { Text("⇧⌘Z").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 300)
            HStack {
                Spacer()
                Button("Redo") { dismiss(); RepoActions.undo(controller, redo: true) }.disabled(redoID == nil)
                Button("Undo") { dismiss(); RepoActions.undo(controller) }.disabled(undoID == nil)
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            entries = await controller.repo.opLog()
            undoID = await controller.repo.undoCandidate()?.id
            redoID = await controller.repo.redoCandidate()?.id
        }
    }
}
