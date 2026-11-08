import AppKit
import SwiftUI
import SpoonKit

/// Local Changes view state (§5.9): file lists, the diff of the selected file, and the commit box.
@MainActor @Observable
final class LocalChangesModel {
    var selection: Set<String> = []   // "u:path" / "s:path" / "c:path"
    var diff: FileDiff?
    var diffIsStaged = false
    var diffIsUntracked = false
    var lineSelection = IndexSet()
    var filter = ""
    var showIgnored = false
    var diffSearch = ""

    var subject = ""
    var body = ""
    var amend = false { didSet { if amend != oldValue { amendChanged() } } }
    var signOff = false
    var skipHooks = false
    var hookOutput = ""
    var committing = false
    @ObservationIgnored weak var controller: RepoController?
    @ObservationIgnored private var draftBeforeAmend: (String, String)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(controller: RepoController) {
        self.controller = controller
        if let draft = UserDefaults.standard.dictionary(forKey: draftKey) as? [String: String] {
            subject = draft["subject"] ?? ""
            body = draft["body"] ?? ""
        }
    }

    private var draftKey: String { "draft:\(controller?.repo.workTree.path ?? "")" }

    /// Drafts are kept per repo and survive restarts and rebases (CMT-03).
    func saveDraft() {
        UserDefaults.standard.set(["subject": subject, "body": body], forKey: draftKey)
    }

    var message: String { body.isEmpty ? subject : "\(subject)\n\n\(body)" }

    static func key(_ e: StatusEntry, staged: Bool) -> String {
        (e.kind == .unmerged ? "c:" : staged ? "s:" : "u:") + e.path
    }

    func entries(for keys: Set<String>, staged: Bool) -> [StatusEntry] {
        guard let s = controller?.status else { return [] }
        let list = staged ? s.staged : s.unstaged + s.conflicts
        return list.filter { keys.contains(Self.key($0, staged: staged)) }
    }

    var selectedUnstaged: [StatusEntry] { entries(for: selection, staged: false) }
    var selectedStaged: [StatusEntry] { entries(for: selection, staged: true) }

    /// Shows the diff of the single selected file.
    func reload() {
        guard let controller, selection.count == 1, let key = selection.first else {
            diff = nil
            return
        }
        let staged = key.hasPrefix("s:")
        let path = String(key.dropFirst(2))
        let entry = (staged ? controller.status.staged : controller.status.unstaged + controller.status.conflicts).first { $0.path == path }
        guard let entry else { diff = nil; selection = []; return }
        let options = DiffOptions(ignoreWhitespace: AppModel.shared.settings.ignoreWhitespace, context: AppModel.shared.settings.diffContext)
        loadTask?.cancel()
        loadTask = Task {
            let repo = controller.repo
            var file: FileDiff?
            if entry.kind == .untracked {
                let size = (try? FileManager.default.attributesOfItem(atPath: repo.workTree.appendingPathComponent(path).path)[.size] as? Int) ?? 0
                if size > 5_000_000 {
                    // Large untracked files aren't diffed by default (STG-10).
                    file = FileDiff(oldPath: path, newPath: path, status: .added, isBinary: true)
                } else {
                    file = try? await repo.diffUntracked(path, options: options)
                }
            } else {
                file = try? await repo.diffWorkingCopy(staged: staged, paths: [entry.originalPath, path].compactMap { $0 }, options: options)
                    .first { $0.path == path } ?? nil
            }
            guard !Task.isCancelled else { return }
            if diff?.path != file?.path { lineSelection = [] }
            diff = file ?? FileDiff(oldPath: path, newPath: path, status: entry.kind == .untracked ? .added : .modified)
            diffIsStaged = staged
            diffIsUntracked = entry.kind == .untracked
        }
    }

    // MARK: File actions

    func stage(_ entries: [StatusEntry]) {
        guard let controller, !entries.isEmpty else { return }
        let next = neighbour(after: entries, staged: false)
        controller.perform("Stage", { repo, _ in try await repo.stage(entries.map(\.path)) }) { [weak self] in
            if let next { self?.selection = [next] } else { self?.selection = [] }
            self?.reload()
        }
    }

    func unstage(_ entries: [StatusEntry]) {
        guard let controller, !entries.isEmpty else { return }
        let next = neighbour(after: entries, staged: true)
        controller.perform("Unstage", { repo, _ in try await repo.unstage(entries.map { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }.flatMap { $0 }) }) { [weak self] in
            if let next { self?.selection = [next] } else { self?.selection = [] }
            self?.reload()
        }
    }

    /// After staging, select the next file in the same list (§5.9).
    private func neighbour(after entries: [StatusEntry], staged: Bool) -> String? {
        guard let s = controller?.status else { return nil }
        let list = staged ? s.staged : s.unstaged
        let paths = Set(entries.map(\.path))
        guard let last = list.lastIndex(where: { paths.contains($0.path) }) else { return nil }
        let after = list[(last + 1)...].first { !paths.contains($0.path) } ?? list[..<last].last { !paths.contains($0.path) }
        return after.map { Self.key($0, staged: staged) }
    }

    func discard(_ entries: [StatusEntry]) {
        guard let controller, !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "Discard changes to \(entries[0].path)?" : "Discard changes to \(entries.count) files?"
        alert.informativeText = "Discarded changes can be restored with Undo (⌘Z)."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard let window = controller.window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            controller.perform("Discard", { repo, _ in try await repo.discard(entries) }) { [weak self] in self?.selection = []; self?.reload() }
        }
    }

    /// Selected diff rows → hunk/line refs.
    func lineRefs(_ rows: [DiffRow], _ selection: IndexSet) -> Set<LineRef> {
        var refs = Set<LineRef>()
        for i in selection where i < rows.count {
            let r = rows[i]
            for (line, idx) in [(r.left, r.leftIndex), (r.right, r.rightIndex)] {
                if let line, let idx, line.kind == .added || line.kind == .deleted { refs.insert(LineRef(hunk: r.hunk, line: idx)) }
            }
        }
        return refs
    }

    /// Hunk/line stage, unstage or discard (STG-03, STG-04).
    func applyLines(_ refs: Set<LineRef>, unstage: Bool = false, discard: Bool = false) {
        guard let controller, let file = diff, !refs.isEmpty else { return }
        let untracked = diffIsUntracked
        let title = discard ? "Discard lines" : unstage ? "Unstage lines" : "Stage lines"
        controller.perform(title, { repo, _ in
            var target = file
            if untracked {
                try await repo.intentToAdd(file.path)
                target = try await repo.diffWorkingCopy(staged: false, paths: [file.path]).first ?? file
            }
            try await repo.applyPartial(target, lines: refs, unstage: unstage, discard: discard)
        }) { [weak self] in
            self?.lineSelection = []
            self?.reload()
        }
    }

    func ignore(_ pattern: String, locally: Bool) {
        guard let controller else { return }
        let file = locally ? controller.repo.gitDir.appendingPathComponent("info/exclude") : controller.repo.workTree.appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += pattern + "\n"
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        controller.refresh(state: false)
    }

    // MARK: Commit (§5.9)

    private func amendChanged() {
        guard let controller else { return }
        if amend {
            draftBeforeAmend = (subject, body)
            Task {
                let msg = await controller.repo.headMessage()
                let parts = msg.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                subject = parts.first.map(String.init) ?? ""
                body = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
        } else if let d = draftBeforeAmend {
            (subject, body) = d
            draftBeforeAmend = nil
        }
    }

    var disabledReason: String? {
        guard let c = controller else { return "No repository" }
        if c.operation == .merge || !c.status.conflicts.isEmpty { return "Resolve conflicts first" }
        if subject.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a commit subject" }
        if c.status.staged.isEmpty && !amend { return "Stage changes to commit" }
        return nil
    }

    func commit(push: Bool = false) {
        guard let controller, disabledReason == nil else { NSSound.beep(); return }
        let message = self.message
        let options = CommitOptions(amend: amend, signOff: signOff, noVerify: skipHooks)
        hookOutput = ""
        committing = true
        let append: Repository.Output = { [weak self] text in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hookOutput += text } }
        }
        controller.perform(amend ? "Amend" : "Commit", { repo, _ in
            try await repo.commit(message: message, options: options, output: append)
        }) { [weak self] in
            guard let self else { return }
            RecentMessages.add(message)
            self.subject = ""
            self.body = ""
            self.amend = false
            self.draftBeforeAmend = nil
            self.skipHooks = false  // one commit only (CMT-12)
            self.saveDraft()
            if push || AppModel.shared.settings.pushAfterCommit { RepoActions.quickPush(controller) }
        }
        Task { @MainActor in
            while controller.busy != nil { try? await Task.sleep(for: .milliseconds(100)) }
            committing = false
        }
    }
}

enum RecentMessages {
    static func add(_ m: String) {
        var list = all.filter { $0 != m }
        list.insert(m, at: 0)
        UserDefaults.standard.set(Array(list.prefix(20)), forKey: "recentMessages")
    }
    static var all: [String] { UserDefaults.standard.stringArray(forKey: "recentMessages") ?? [] }
}

struct LocalChangesView: View {
    let controller: RepoController
    var model: LocalChangesModel { controller.local }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                FileLists(controller: controller, model: model)
                Divider()
                CommitBox(controller: controller, model: model)
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 560, maxHeight: .infinity)
            diffPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.selection) { _, _ in model.reload() }
        .onChange(of: controller.status) { _, _ in model.reload() }
    }

    @ViewBuilder var diffPane: some View {
        if model.selection.count == 1, let key = model.selection.first, key.hasPrefix("c:"),
           let entry = controller.status.conflicts.first(where: { $0.path == String(key.dropFirst(2)) }) {
            ConflictPanel(controller: controller, entry: entry)
        } else if let op = controller.operation, model.diff == nil {
            ContentUnavailableView("\(op.title) in progress", systemImage: "exclamationmark.triangle",
                                   description: Text("Resolve conflicts, then continue or abort."))
        } else if model.diff == nil {
            if controller.status.isClean {
                ContentUnavailableView {
                    Label("Nothing to commit — working tree clean", systemImage: "checkmark.circle")
                } actions: {
                    if let h = controller.headRef, h.behind > 0 { Button("Pull ↓\(h.behind)") { RepoActions.quickPull(controller) } }
                    if let h = controller.headRef, h.ahead > 0 { Button("Push ↑\(h.ahead)") { RepoActions.quickPush(controller) } }
                }
            } else {
                ContentUnavailableView("Select a file to see its changes", systemImage: "doc.text")
            }
        } else {
            DiffPane(file: model.diff, search: Bindable(model).diffSearch, reload: { model.reload() },
                     extraControls: AnyView(LineActions(model: model)),
                     selection: Bindable(model).lineSelection)
        }
    }
}

/// Buttons for the current line/hunk selection, beside the diff header (STG-03/04).
struct LineActions: View {
    let model: LocalChangesModel
    var body: some View {
        if model.diff != nil {
            let rows = DiffRows.build([model.diff!], sideBySide: AppModel.shared.settings.diffSideBySide, fileHeaders: false)
            let refs = model.lineRefs(rows, model.lineSelection)
            if !refs.isEmpty {
                HStack(spacing: 4) {
                    if model.diffIsStaged {
                        Button("Unstage \(refs.count) Line\(refs.count == 1 ? "" : "s")") { model.applyLines(refs, unstage: true) }
                            .keyboardShortcut(.return, modifiers: [])
                    } else {
                        Button("Stage \(refs.count) Line\(refs.count == 1 ? "" : "s")") { model.applyLines(refs) }
                            .keyboardShortcut(.return, modifiers: [])
                        Button("Discard…") {
                            let a = NSAlert()
                            a.messageText = "Discard \(refs.count) selected line\(refs.count == 1 ? "" : "s")?"
                            a.informativeText = "Discarded changes can be restored with Undo (⌘Z)."
                            a.addButton(withTitle: "Discard")
                            a.addButton(withTitle: "Cancel")
                            if a.runModal() == .alertFirstButtonReturn { model.applyLines(refs, discard: true) }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("Click a hunk header or lines to stage them").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct FileLists: View {
    let controller: RepoController
    @Bindable var model: LocalChangesModel

    var body: some View {
        let status = controller.status
        let match: (StatusEntry) -> Bool = { model.filter.isEmpty || $0.path.localizedCaseInsensitiveContains(model.filter) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter files", text: $model.filter).textFieldStyle(.roundedBorder)
                Toggle(isOn: $model.showIgnored) { Image(systemName: "eye") }
                    .toggleStyle(.button).help("Show ignored files (⇧⌘.)")
                    .onChange(of: model.showIgnored) { _, _ in controller.showIgnored = model.showIgnored; controller.refresh(state: false) }
            }
            .padding(6)
            List(selection: $model.selection) {
                if !status.conflicts.isEmpty {
                    Section("Conflicts (\(status.conflicts.count))") {
                        ForEach(status.conflicts.filter(match), id: \.path) { e in
                            row(e, staged: false).tag(LocalChangesModel.key(e, staged: false))
                        }
                    }
                }
                Section {
                    ForEach(status.unstaged.filter(match), id: \.path) { e in
                        row(e, staged: false).tag(LocalChangesModel.key(e, staged: false))
                    }
                } header: {
                    HStack {
                        Text("Unstaged (\(status.unstaged.count))")
                        Spacer()
                        Button(model.selectedUnstaged.isEmpty || NSEvent.modifierFlags.contains(.option) ? "Stage All" : "Stage") {
                            let sel = model.selectedUnstaged
                            if sel.isEmpty || NSEvent.modifierFlags.contains(.option) {
                                controller.perform("Stage All", { repo, _ in try await repo.stageAll() })
                            } else { model.stage(sel) }
                        }
                        .buttonStyle(.borderless).disabled(status.unstaged.isEmpty)
                    }
                }
                Section {
                    ForEach(status.staged.filter(match), id: \.path) { e in
                        row(e, staged: true).tag(LocalChangesModel.key(e, staged: true))
                    }
                } header: {
                    HStack {
                        Text("Staged (\(status.staged.count))")
                        Spacer()
                        Button(model.selectedStaged.isEmpty || NSEvent.modifierFlags.contains(.option) ? "Unstage All" : "Unstage") {
                            let sel = model.selectedStaged
                            if sel.isEmpty || NSEvent.modifierFlags.contains(.option) {
                                controller.perform("Unstage All", { repo, _ in try await repo.unstageAll() })
                            } else { model.unstage(sel) }
                        }
                        .buttonStyle(.borderless).disabled(status.staged.isEmpty)
                    }
                }
                if model.showIgnored {
                    let ignored = status.entries.filter { $0.kind == .ignored }
                    if !ignored.isEmpty {
                        Section("Ignored (\(ignored.count))") {
                            ForEach(ignored, id: \.path) { e in Text(e.path).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: String.self) { keys in
                fileMenu(keys)
            } primaryAction: { keys in
                toggle(keys)
            }
            .onKeyPress(.return) { toggle(model.selection); return .handled }
            .onKeyPress(.delete) { model.discard(model.selectedUnstaged.filter { $0.kind != .unmerged }); return .handled }
            .onDeleteCommand { model.discard(model.selectedUnstaged.filter { $0.kind != .unmerged }) }
        }
    }

    func toggle(_ keys: Set<String>) {
        let u = model.entries(for: keys, staged: false).filter { $0.kind != .unmerged }
        let s = model.entries(for: keys, staged: true)
        if !u.isEmpty { model.stage(u) } else if !s.isEmpty { model.unstage(s) }
    }

    func row(_ e: StatusEntry, staged: Bool) -> some View {
        let letter: Character = e.kind == .unmerged ? "!" : e.kind == .untracked ? "?" : staged ? e.index : e.worktree
        let url = URL(fileURLWithPath: e.path)
        return HStack(spacing: 6) {
            StatusBadge(letter: letter == "." ? "M" : letter)
            Text(url.lastPathComponent).lineLimit(1)
            Text(e.originalPath.map { "← \($0)" } ?? (url.deletingLastPathComponent().relativePath == "." ? "" : url.deletingLastPathComponent().relativePath))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    func fileMenu(_ keys: Set<String>) -> some View {
        let unstaged = model.entries(for: keys, staged: false)
        let staged = model.entries(for: keys, staged: true)
        let all = unstaged + staged
        if !unstaged.isEmpty { Button("Stage") { model.stage(unstaged.filter { $0.kind != .unmerged }) } }
        if !staged.isEmpty { Button("Unstage") { model.unstage(staged) } }
        if !unstaged.isEmpty { Button("Discard…") { model.discard(unstaged.filter { $0.kind != .unmerged }) } }
        if !all.isEmpty {
            Button("Stash \(all.count == 1 ? "This File" : "These Files")…") {
                RepoActions.stashDialog(controller, paths: Array(Set(all.map(\.path))))
            }
        }
        if !unstaged.filter({ $0.kind == .unmerged }).isEmpty {
            Menu("Resolve") {
                Button("Take Yours") { RepoActions.resolve(controller, unstaged.map(\.path), ours: true) }
                Button("Take Theirs") { RepoActions.resolve(controller, unstaged.map(\.path), ours: false) }
            }
        }
        Divider()
        if let e = all.first {
            let url = controller.repo.workTree.appendingPathComponent(e.path)
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Open in Editor") { External.openEditor(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Menu("Ignore") {
                Button("Ignore \(url.lastPathComponent)") { model.ignore("/" + e.path, locally: false) }
                if !url.pathExtension.isEmpty { Button("Ignore *.\(url.pathExtension)") { model.ignore("*.\(url.pathExtension)", locally: false) } }
                let dir = url.deletingLastPathComponent().path.replacingOccurrences(of: controller.repo.workTree.path, with: "")
                if !dir.isEmpty { Button("Ignore folder \(dir)/") { model.ignore(dir + "/", locally: false) } }
                Divider()
                Button("Ignore Locally (.git/info/exclude)") { model.ignore("/" + e.path, locally: true) }
            }
            Divider()
            Button("Copy Path") { copy(url.path) }
            Button("Copy Relative Path") { copy(e.path) }
        }
    }

    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

struct CommitBox: View {
    let controller: RepoController
    @Bindable var model: LocalChangesModel
    @FocusState private var subjectFocused: Bool
    @State private var showHooks = false
    private var settings: Settings { AppModel.shared.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.currentBranch == nil && controller.headSHA != nil {
                Label("Detached HEAD — commits won't be on a branch", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if model.amend, let h = controller.headRef, h.upstream != nil, h.ahead == 0 {
                Label("HEAD is pushed — amending will require a force push", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                TextField("Commit subject", text: $model.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($subjectFocused)
                    .onSubmit { model.commit() }
                let n = model.subject.count
                if n > settings.subjectSoftLimit - 10 {
                    Text("\(n)").font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(n > settings.subjectHardLimit ? .red : n > settings.subjectSoftLimit ? .orange : .secondary)
                }
                Menu {
                    Section("Recent messages") {
                        ForEach(RecentMessages.all, id: \.self) { m in
                            Button(String(m.split(separator: "\n").first ?? "")) {
                                let parts = m.split(separator: "\n", maxSplits: 1)
                                model.subject = parts.first.map(String.init) ?? ""
                                model.body = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                            }
                        }
                    }
                    Menu("Insert Trailer") {
                        ForEach(["Signed-off-by", "Co-authored-by", "Fixes", "Refs"], id: \.self) { t in
                            Button(t) { model.body += (model.body.isEmpty || model.body.hasSuffix("\n") ? "" : "\n") + "\(t): " }
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            TextEditor(text: $model.body)
                .font(.system(size: 12))
                .frame(minHeight: 60, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if model.body.isEmpty { Text("Description").foregroundStyle(.tertiary).font(.system(size: 12)).padding(.leading, 5).allowsHitTesting(false) }
                }
            HStack(spacing: 10) {
                Toggle("Amend", isOn: $model.amend)
                Toggle("Sign-off", isOn: $model.signOff)
                Toggle("Skip hooks", isOn: $model.skipHooks).help("--no-verify, for the next commit only")
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            HStack {
                if !model.hookOutput.isEmpty {
                    Button { showHooks.toggle() } label: { Label("Hook output", systemImage: showHooks ? "chevron.down" : "chevron.right") }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
                Spacer()
                let count = controller.status.staged.count
                let title = model.amend ? "Amend" : "Commit \(count) File\(count == 1 ? "" : "s")"
                Button(NSEvent.modifierFlags.contains(.option) ? "\(title) and Push" : title) {
                    model.commit(push: NSEvent.modifierFlags.contains(.option))
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.disabledReason != nil || model.committing)
                .help(model.disabledReason ?? "⌘Return")
                Menu {
                    Button("Commit") { model.commit() }
                    Button("Commit and Push") { model.commit(push: true) }.keyboardShortcut(.return, modifiers: [.command, .option])
                } label: { EmptyView() }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.disabledReason != nil)
            }
            if showHooks && !model.hookOutput.isEmpty {
                ScrollView {
                    Text(model.hookOutput).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .padding(8)
        .onChange(of: model.subject) { _, _ in model.saveDraft() }
        .onChange(of: model.body) { _, _ in model.saveDraft() }
        .onChange(of: controller.focusCommitToken) { _, _ in subjectFocused = true }
        .onChange(of: model.hookOutput) { _, out in if !out.isEmpty && model.committing { showHooks = true } }
    }
}
