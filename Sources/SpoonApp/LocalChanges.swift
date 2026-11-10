import AppKit
import SwiftUI
import SpoonKit

/// Local Changes view state (§5.9): one list of changes vs HEAD, the selected file's diff, and the commit box.
/// No staging step: checkboxes pick what goes into the next commit, and the index is rebuilt at commit time.
@MainActor @Observable
final class LocalChangesModel {
    var selection: Set<String> = []   // paths
    var diff: FileDiff?
    var diffIsUntracked = false
    /// Paths left out of the next commit. Everything else is in, so new files start checked.
    var excluded: Set<String> = []
    /// Changed lines left out of the next commit, per path. Valid only for `partialBase[path]`.
    var excludedLines: [String: Set<LineRef>] = [:]
    @ObservationIgnored var partialBase: [String: FileDiff] = [:]
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

    var message: String {
        let s = subject.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedSubject : subject
        return body.isEmpty ? s : "\(s)\n\n\(body)"
    }

    var changes: [StatusEntry] { controller?.status.changes ?? [] }
    var included: [StatusEntry] { changes.filter { !excluded.contains($0.path) } }
    func entries(_ paths: Set<String>) -> [StatusEntry] { changes.filter { paths.contains($0.path) } }

    /// During a merge or cherry-pick every change belongs to the commit, so the checkboxes are locked on.
    var selectionLocked: Bool { controller?.operation != nil }

    func isIncluded(_ path: String) -> Bool { selectionLocked || !excluded.contains(path) }
    func isPartial(_ path: String) -> Bool { !selectionLocked && !excluded.contains(path) && !(excludedLines[path] ?? []).isEmpty }

    func setIncluded(_ paths: [String], _ on: Bool) {
        for p in paths {
            excludedLines[p] = nil
            if on { excluded.remove(p) } else { excluded.insert(p) }
        }
    }

    /// GitHub Desktop-style placeholder, used as the subject when it's left empty with one file checked.
    var suggestedSubject: String {
        guard included.count == 1, let e = included.first else { return "" }
        let name = URL(fileURLWithPath: e.path).lastPathComponent
        switch e.kind == .untracked ? "A" : e.index != "." ? e.index : e.worktree {
        case "A": return "Create \(name)"
        case "D": return "Delete \(name)"
        case "R": return "Rename \(URL(fileURLWithPath: e.originalPath ?? e.path).lastPathComponent) to \(name)"
        default: return "Update \(name)"
        }
    }

    /// Drops checkbox state for files that are gone and line state for files whose diff changed underneath it.
    func prune() {
        let paths = Set(changes.map(\.path))
        excluded.formIntersection(paths)
        for p in excludedLines.keys where !paths.contains(p) { excludedLines[p] = nil; partialBase[p] = nil }
    }

    /// Shows the single selected file's diff against HEAD.
    func reload() {
        prune()
        guard let controller, selection.count == 1, let path = selection.first else {
            diff = nil
            return
        }
        let entry = (controller.status.changes + controller.status.conflicts).first { $0.path == path }
        guard let entry else { diff = nil; selection = []; return }
        let options = diffOptions
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
            } else if entry.kind == .unmerged {
                file = try? await repo.diffWorkingCopy(staged: false, paths: [path], options: options).first
            } else {
                file = try? await repo.diffAgainstHead(paths: [entry.originalPath, path].compactMap { $0 }, options: options)
                    .first { $0.path == path } ?? nil
            }
            guard !Task.isCancelled else { return }
            let shown = file ?? FileDiff(oldPath: path, newPath: path, status: entry.kind == .untracked ? .added : .modified)
            if partialBase[path].map({ $0.hunks != shown.hunks }) ?? false { excludedLines[path] = nil }
            partialBase[path] = shown
            diff = shown
            diffIsUntracked = entry.kind == .untracked
        }
    }

    var diffOptions: DiffOptions {
        DiffOptions(ignoreWhitespace: AppModel.shared.settings.ignoreWhitespace, context: AppModel.shared.settings.diffContext)
    }

    /// Toggles changed lines in or out of the next commit (STG-03). Checking a line of an unchecked file
    /// checks the file with only that line.
    func toggleLines(_ refs: Set<LineRef>) {
        guard let file = diff, !refs.isEmpty, !selectionLocked else { return }
        let path = file.path
        var out = excluded.contains(path) ? PatchBuilder.lines(of: file, hunks: Array(file.hunks.indices)) : excludedLines[path] ?? []
        excluded.remove(path)
        if refs.isSubset(of: out) { out.subtract(refs) } else { out.formUnion(refs) }
        let all = PatchBuilder.lines(of: file, hunks: Array(file.hunks.indices))
        if out == all { excluded.insert(path); out = [] }
        excludedLines[path] = out.isEmpty ? nil : out
    }

    // MARK: File actions

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
            controller.perform("Discard", { repo, _ in
                // Back to HEAD: drop any staged copy first so `restore --worktree` doesn't restore it.
                try await repo.unstage(entries.filter { $0.kind != .untracked }.map(\.path))
                try await repo.discard(entries)
            }) { [weak self] in self?.selection = []; self?.reload() }
        }
    }

    /// Discards lines from the working tree (STG-04). Undoable.
    func discardLines(_ refs: Set<LineRef>) {
        guard let controller, let file = diff, !refs.isEmpty else { return }
        let untracked = diffIsUntracked, options = diffOptions
        controller.perform("Discard lines", { repo, _ in
            // The index may hold anything; make it HEAD for this file so the worktree diff equals the HEAD diff.
            try await repo.unstage([file.path])
            if untracked { try await repo.intentToAdd(file.path) }
            let target = try await repo.diffWorkingCopy(staged: false, paths: [file.path], options: options).first ?? file
            guard target.hunks == file.hunks else { throw GitError(args: ["apply"], status: 1, stderr: "error: \(file.path) changed on disk. Review it and try again.") }
            try await repo.applyPartial(target, lines: refs, discard: true)
        }) { [weak self] in
            self?.excludedLines[file.path] = nil
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
        if subject.trimmingCharacters(in: .whitespaces).isEmpty && suggestedSubject.isEmpty { return "Enter a summary" }
        if included.isEmpty && !amend && !selectionLocked { return "Select at least one file to commit" }
        return nil
    }

    /// Last commit made here, for the "Undo" row while it's still HEAD.
    var lastCommit: (sha: String, subject: String)?

    func commit(push: Bool = false) {
        guard let controller, disabledReason == nil else { NSSound.beep(); return }
        let message = self.message
        let options = CommitOptions(amend: amend, signOff: signOff, noVerify: skipHooks)
        let locked = selectionLocked
        // Renames are excluded by both names so the old path's deletion stays out too.
        let leaveOut = locked ? [] : changes.filter { excluded.contains($0.path) }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        let partial: [(FileDiff, Set<LineRef>)] = locked ? [] : excludedLines.compactMap { path, out in
            guard !excluded.contains(path), let base = partialBase[path] else { return nil }
            return (base, PatchBuilder.lines(of: base, hunks: Array(base.hunks.indices)).subtracting(out))
        }
        let diffOptions = self.diffOptions
        hookOutput = ""
        committing = true
        let append: Repository.Output = { [weak self] text in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hookOutput += text } }
        }
        controller.perform(amend ? "Amend" : "Commit", { [weak self] repo, _ in
            let sha = try await repo.commitSelected(excluding: leaveOut, partial: partial, message: message,
                                                    options: options, diffOptions: diffOptions, output: append)
            await MainActor.run { self?.lastCommit = (sha, String(message.split(separator: "\n").first ?? "")) }
        }) { [weak self] in
            guard let self else { return }
            RecentMessages.add(message)
            self.subject = ""
            self.body = ""
            self.amend = false
            self.draftBeforeAmend = nil
            self.skipHooks = false  // one commit only (CMT-12)
            self.excluded = []
            self.excludedLines = [:]
            self.saveDraft()
            if push || AppModel.shared.settings.pushAfterCommit { RepoActions.quickPush(controller) }
        }
        Task { @MainActor in
            while controller.busy != nil { try? await Task.sleep(for: .milliseconds(100)) }
            committing = false
        }
    }
}

extension LocalChangesModel: DiffViewDelegate {
    func diffView(_ view: DiffDocumentView, contextMenuFor rows: [Int]) -> NSMenu? {
        let refs = view.rows.lineRefs(IndexSet(rows))
        guard !refs.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionItem("Discard \(refs.count) Line\(refs.count == 1 ? "" : "s")…") { [weak self] in
            let a = NSAlert()
            a.messageText = "Discard \(refs.count) selected line\(refs.count == 1 ? "" : "s")?"
            a.informativeText = "Discarded changes can be restored with Undo (⌘Z)."
            a.addButton(withTitle: "Discard")
            a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            if a.runModal() == .alertFirstButtonReturn { self?.discardLines(refs) }
        })
        return menu
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
        if model.selection.count == 1, let path = model.selection.first,
           let entry = controller.status.conflicts.first(where: { $0.path == path }) {
            ConflictPanel(controller: controller, entry: entry)
        } else if let op = controller.operation, model.diff == nil {
            ContentUnavailableView("\(op.title) in progress", systemImage: "exclamationmark.triangle",
                                   description: Text("Resolve conflicts, then continue or abort."))
        } else if model.diff == nil {
            if controller.status.isClean {
                ContentUnavailableView {
                    Label("No local changes", systemImage: "checkmark.circle")
                } description: {
                    Text("There are no uncommitted changes in this repository.")
                } actions: {
                    if let h = controller.headRef, h.behind > 0 { Button("Pull ↓\(h.behind)") { RepoActions.quickPull(controller) } }
                    if let h = controller.headRef, h.ahead > 0 { Button("Push ↑\(h.ahead)") { RepoActions.quickPush(controller) } }
                }
            } else {
                ContentUnavailableView("Select a file to see its changes", systemImage: "doc.text")
            }
        } else {
            let file = model.diff!
            DiffPane(file: file, search: Bindable(model).diffSearch, reload: { model.reload() },
                     extraControls: model.selectionLocked || file.hunks.isEmpty ? nil : AnyView(
                        Text("Click lines to leave them out of the commit").font(.system(size: 11)).foregroundStyle(.tertiary)),
                     menuDelegate: model,
                     included: model.selectionLocked || file.hunks.isEmpty ? nil : includedLines(file),
                     onToggle: { model.toggleLines($0) })
        }
    }

    func includedLines(_ file: FileDiff) -> Set<LineRef> {
        if model.excluded.contains(file.path) { return [] }
        return PatchBuilder.lines(of: file, hunks: Array(file.hunks.indices)).subtracting(model.excludedLines[file.path] ?? [])
    }
}

struct FileLists: View {
    let controller: RepoController
    @Bindable var model: LocalChangesModel

    var body: some View {
        let status = controller.status
        let match: (StatusEntry) -> Bool = { model.filter.isEmpty || $0.path.localizedCaseInsensitiveContains(model.filter) }
        let changes = status.changes
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder)
                Toggle(isOn: $model.showIgnored) { Image(systemName: "eye") }
                    .toggleStyle(.button).help("Show ignored files (⇧⌘.)")
                    .onChange(of: model.showIgnored) { _, _ in controller.showIgnored = model.showIgnored; controller.refresh(state: false) }
            }
            .padding(6)
            if !changes.isEmpty {
                HStack(spacing: 6) {
                    let on = model.selectionLocked || model.included.count == changes.count && model.excludedLines.isEmpty
                    let off = !model.selectionLocked && model.included.isEmpty
                    Checkbox(state: on ? .on : off ? .off : .mixed) { model.setIncluded(changes.map(\.path), !on) }
                        .disabled(model.selectionLocked)
                    Text("\(changes.count) changed file\(changes.count == 1 ? "" : "s")").font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
            List(selection: $model.selection) {
                if !status.conflicts.isEmpty {
                    Section("Conflicts (\(status.conflicts.count))") {
                        ForEach(status.conflicts.filter(match), id: \.path) { e in row(e).tag(e.path) }
                    }
                }
                ForEach(changes.filter(match), id: \.path) { e in row(e).tag(e.path) }
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
            .onKeyPress(.space) { toggle(model.selection); return .handled }
            .onKeyPress(.delete) { model.discard(model.entries(model.selection)); return .handled }
            .onDeleteCommand { model.discard(model.entries(model.selection)) }
        }
    }

    /// Space / double-click: check or uncheck the selected files together.
    func toggle(_ keys: Set<String>) {
        let paths = model.entries(keys).map(\.path)
        guard !paths.isEmpty, !model.selectionLocked else { return }
        model.setIncluded(paths, !paths.allSatisfy { model.isIncluded($0) && !model.isPartial($0) })
    }

    func row(_ e: StatusEntry) -> some View {
        let letter: Character = e.kind == .unmerged ? "!" : e.kind == .untracked ? "?" : e.index != "." ? e.index : e.worktree
        let url = URL(fileURLWithPath: e.path)
        return HStack(spacing: 6) {
            if e.kind != .unmerged {
                let on = model.isIncluded(e.path)
                Checkbox(state: model.isPartial(e.path) ? .mixed : on ? .on : .off) { model.setIncluded([e.path], !on || model.isPartial(e.path)) }
                    .disabled(model.selectionLocked)
                    .help(model.isPartial(e.path) ? "Some lines are left out of the commit" : "")
            }
            Text(url.lastPathComponent).lineLimit(1)
            Text(e.originalPath.map { "← \($0)" } ?? (url.deletingLastPathComponent().relativePath == "." ? "" : url.deletingLastPathComponent().relativePath))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            StatusBadge(letter: letter)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    func fileMenu(_ keys: Set<String>) -> some View {
        let changed = model.entries(keys)
        let conflicted = controller.status.conflicts.filter { keys.contains($0.path) }
        let all = changed + conflicted
        if !changed.isEmpty && !model.selectionLocked {
            let on = changed.allSatisfy { model.isIncluded($0.path) }
            Button(on ? "Leave Out of Commit" : "Include in Commit") { model.setIncluded(changed.map(\.path), !on) }
            Divider()
        }
        if !changed.isEmpty { Button("Discard Changes…") { model.discard(changed) } }
        if !all.isEmpty {
            Button("Stash \(all.count == 1 ? "This File" : "These Files")…") {
                RepoActions.stashDialog(controller, paths: Array(Set(all.map(\.path))))
            }
        }
        if !conflicted.isEmpty {
            Menu("Resolve") {
                Button("Use My Version") { RepoActions.resolve(controller, conflicted.map(\.path), ours: true) }
                Button("Use Their Version") { RepoActions.resolve(controller, conflicted.map(\.path), ours: false) }
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

/// Native checkbox with a mixed state, which SwiftUI's Toggle can't show.
struct Checkbox: NSViewRepresentable {
    var state: NSControl.StateValue
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.click))
        b.allowsMixedState = true
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) {
        b.state = state
        b.isEnabled = context.environment.isEnabled
        context.coordinator.action = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { nsView.intrinsicContentSize }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func click() { action() }
    }
}

struct CommitBox: View {
    let controller: RepoController
    @Bindable var model: LocalChangesModel
    @FocusState private var subjectFocused: Bool
    @State private var showHooks = false
    private var settings: Settings { AppModel.shared.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let last = model.lastCommit, last.sha == controller.headSHA, model.subject.isEmpty, !model.amend {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Committed \(last.subject)").lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button("Undo") { RepoActions.undo(controller); model.lastCommit = nil }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 11))
            }
            if controller.currentBranch == nil && controller.headSHA != nil {
                Label("Not on a branch. Commits made here won't belong to any branch.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if model.amend, let h = controller.headRef, h.upstream != nil, h.ahead == 0 {
                Label("This commit is already pushed. Amending it will require a force push.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                TextField(model.suggestedSubject.isEmpty ? "Summary (required)" : model.suggestedSubject, text: $model.subject)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($subjectFocused)
                    .onSubmit { model.commit() }
                let n = model.subject.count
                if n > settings.subjectSoftLimit - 10 {
                    Text("\(n)").font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(n > settings.subjectHardLimit ? .red : n > settings.subjectSoftLimit ? .orange : .secondary)
                }
            }
            TextField("Description", text: $model.body, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(5, reservesSpace: true)
            HStack(spacing: 8) {
                Menu {
                    Toggle("Amend Last Commit", isOn: $model.amend)
                    Toggle("Add Signed-off-by", isOn: $model.signOff)
                    Toggle("Skip Commit Hooks", isOn: $model.skipHooks)
                    Divider()
                    Menu("Insert Trailer") {
                        ForEach(["Co-authored-by", "Signed-off-by", "Fixes", "Refs"], id: \.self) { t in
                            Button(t) { model.body += (model.body.isEmpty || model.body.hasSuffix("\n") ? "" : "\n") + "\(t): " }
                        }
                    }
                    Menu("Recent Messages") {
                        ForEach(RecentMessages.all, id: \.self) { m in
                            Button(String(m.split(separator: "\n").first ?? "")) {
                                let parts = m.split(separator: "\n", maxSplits: 1)
                                model.subject = parts.first.map(String.init) ?? ""
                                model.body = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More commit options")
                if model.amend || model.signOff || model.skipHooks {
                    Text([model.amend ? "Amend" : nil, model.signOff ? "Sign-off" : nil, model.skipHooks ? "No hooks" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.hookOutput.isEmpty {
                    Button { showHooks.toggle() } label: { Label("Hook output", systemImage: showHooks ? "chevron.down" : "chevron.right") }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            Button {
                model.commit(push: NSEvent.modifierFlags.contains(.option))
            } label: {
                Text(commitTitle).frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.disabledReason != nil || model.committing)
            .help(model.disabledReason ?? "⌘Return to commit, ⌥⌘Return to commit and push")
            .background {
                Button("Commit and Push") { model.commit(push: true) }.keyboardShortcut(.return, modifiers: [.command, .option]).opacity(0).accessibilityHidden(true)
            }
            if showHooks && !model.hookOutput.isEmpty {
                ScrollView {
                    Text(model.hookOutput).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
            }
        }
        .padding(10)
        .onChange(of: model.subject) { _, _ in model.saveDraft() }
        .onChange(of: model.body) { _, _ in model.saveDraft() }
        .onChange(of: controller.focusCommitToken) { _, _ in subjectFocused = true }
    }

    private var commitTitle: AttributedString {
        let branch = controller.currentBranch.map { " to **\($0)**" } ?? ""
        let n = model.selectionLocked ? controller.status.changes.count : model.included.count
        let text = model.amend ? "Amend last commit" : n == 0 ? "Commit\(branch)" : "Commit \(n) file\(n == 1 ? "" : "s")\(branch)"
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
