import AppKit
import SwiftUI
import SpoonKit

// M4 UI: in-progress bar, conflict panel, merge editor, and the history-rewriting dialogs (§5.11, §5.12, §6.12).

extension RepoController {
    /// Runs a sequencer operation; a stop (conflicts or an edit stop) switches to Local Changes.
    func rewrite(_ title: String, _ body: @escaping @Sendable (Repository) async throws -> OperationResult) {
        let box = ResultBox()
        perform(title, { repo, _ in box.value = try await body(repo) }) { [weak self] in
            guard let self, box.value == .stopped else { return }
            self.view = .localChanges
            // Edit stop: nothing conflicted, the user is meant to amend.
            if self.repo.operationInProgress == .rebase {
                Task {
                    if let s = try? await self.repo.status(background: false), s.conflicts.isEmpty { self.local.amend = true }
                }
            }
        }
    }
}

final class ResultBox: @unchecked Sendable { var value: OperationResult? }

/// "Merging feature into main — 3 conflicted files  [Continue] [Abort]" (MRG-03).
struct OperationBar: View {
    let controller: RepoController
    @State private var sides = ("", "")
    @State private var subject = ""

    var body: some View {
        if let op = controller.operation {
            let conflicts = controller.status.conflicts.count
            HStack(spacing: 10) {
                Image(systemName: conflicts > 0 ? "exclamationmark.triangle.fill" : "arrow.triangle.branch").foregroundStyle(.orange)
                Text(text(op, conflicts)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if conflicts > 0 {
                    Button("Show Conflicts") { controller.view = .localChanges }
                }
                Button("Continue") { controller.rewrite("Continue \(op.title.lowercased())") { try await $0.continueOperation() } }
                    .disabled(conflicts > 0)
                    .keyboardShortcut(.defaultAction)
                if [.rebase, .cherryPick, .revert].contains(op) {
                    Button("Skip") { controller.rewrite("Skip") { try await $0.skipStep() } }
                }
                Button(op == .bisect ? "Reset" : "Abort", role: .destructive) {
                    controller.perform("Abort \(op.title.lowercased())") { repo, _ in try await repo.abortOperation() }
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.15))
            .overlay(alignment: .bottom) { Divider() }
            .task(id: "\(op)\(controller.status.branch.oid ?? "")\(conflicts)") {
                sides = await controller.repo.conflictSides()
                let r = try? await controller.repo.git.run(["log", "-1", "--format=%s", "REBASE_HEAD"], in: controller.repo.workTree, background: true, check: false)
                subject = r?.status == 0 ? r!.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
        }
    }

    func text(_ op: RepoOperation, _ conflicts: Int) -> String {
        let files = conflicts > 0 ? " — \(conflicts) conflicted file\(conflicts == 1 ? "" : "s")" : " — all conflicts resolved"
        switch op {
        case .merge: return "Merging \(sides.1) into \(sides.0)" + files
        case .rebase:
            let p = controller.repo.rebaseProgress.map { " \($0.step)/\($0.total)" } ?? ""
            let stop = conflicts == 0 && !subject.isEmpty ? " — stopped to edit; amend, then Continue" : files
            return "Rebasing \(sides.1)\(p)" + (subject.isEmpty ? "" : ": \(subject)") + stop
        case .cherryPick: return "Cherry-picking \(sides.1)" + files
        case .revert: return "Reverting: \(sides.1)" + files
        case .bisect: return "Bisecting"
        }
    }
}

/// Selected conflicted file in Local Changes (CONF-01, CONF-06).
struct ConflictPanel: View {
    let controller: RepoController
    let entry: StatusEntry
    @State private var sides = ("Yours", "Theirs")

    /// DU = deleted by us, UD = deleted by them.
    var deletedBy: String? {
        switch (entry.index, entry.worktree) {
        case ("D", "U"): "you"
        case ("U", "D"): "them"
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
            Text(entry.path).font(.system(size: 14, weight: .semibold))
            if let who = deletedBy {
                Text("Deleted by \(who), changed on the other side.").foregroundStyle(.secondary)
                HStack {
                    Button("Keep File") { run("Keep \(entry.path)") { try await $0.resolveDeleted(entry.path, keep: true) } }
                    Button("Delete File") { run("Delete \(entry.path)") { try await $0.resolveDeleted(entry.path, keep: false) } }
                }
            } else {
                Text("Both sides changed this file.").foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    Label("Yours: \(sides.0)", systemImage: "person").foregroundStyle(.blue)
                    Label("Theirs: \(sides.1)", systemImage: "arrow.triangle.branch").foregroundStyle(.purple)
                }
                .font(.system(size: 12))
                HStack {
                    Button("Take Yours") { RepoActions.resolve(controller, [entry.path], ours: true) }
                    Button("Take Theirs") { RepoActions.resolve(controller, [entry.path], ours: false) }
                    Button("Merge in Spoon…") { MergeEditor.present(controller, path: entry.path, sides: sides) }
                        .keyboardShortcut(.defaultAction)
                    Button("Merge in FileMerge") { external() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.path) {
            let s = await controller.repo.conflictSides()
            sides = (s.ours, s.theirs)
        }
    }

    func run(_ title: String, _ body: @escaping @Sendable (Repository) async throws -> Void) {
        controller.perform(title) { repo, _ in try await body(repo) }
    }

    // ponytail: FileMerge via `git mergetool -t opendiff` only; add the CONF-08 tool list when someone asks.
    func external() {
        let path = entry.path
        controller.perform("Merge in FileMerge") { repo, _ in
            _ = try await repo.git.run(["mergetool", "--no-prompt", "-t", "opendiff", "--", path], in: repo.workTree)
        }
    }
}

// MARK: Merge editor (CONF-02..05)

@MainActor @Observable
final class MergeEditorModel {
    enum Choice: Equatable { case yours, theirs, yoursThenTheirs, theirsThenYours }
    let path: String
    let sides: (String, String)
    var segments: [ConflictSegment] = []
    var choices: [Int: Choice] = [:]
    var autoResolved: Set<Int> = []
    var result = ""
    var showBase = false
    var current = 0
    var error: String?
    @ObservationIgnored var history: [[Int: Choice]] = []
    @ObservationIgnored var future: [[Int: Choice]] = []

    init(path: String, sides: (String, String)) { self.path = path; self.sides = sides }

    var conflictIndices: [Int] { segments.indices.filter { segments[$0].isConflict } }
    var resolvedCount: Int { conflictIndices.count { choices[$0] != nil } }
    var unresolved: Bool { result.contains("<<<<<<< ") }

    func load(_ segs: [ConflictSegment]) {
        segments = segs
        // Identical or whitespace-only differences resolve themselves; they're listed for review.
        for i in conflictIndices {
            guard case .conflict(let o, _, let t) = segs[i] else { continue }
            let norm = { (l: [String]) in l.joined().filter { !$0.isWhitespace } }
            if o == t || norm(o) == norm(t) { choices[i] = .yours; autoResolved.insert(i) }
        }
        render()
    }

    func pick(_ i: Int, _ c: Choice?) {
        history.append(choices)
        future = []
        choices[i] = c
        render()
    }

    func pickAll(_ c: Choice) {
        history.append(choices)
        future = []
        for i in conflictIndices { choices[i] = c }
        render()
    }

    func undo() {
        guard let prev = history.popLast() else { return }
        future.append(choices)
        choices = prev
        render()
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(choices)
        choices = next
        render()
    }

    /// Rebuilds the result from the picks. Unresolved chunks keep markers; ponytail: picks overwrite hand edits in the result.
    func render() {
        var out = ""
        for (i, s) in segments.enumerated() {
            switch s {
            case .common(let lines): out += lines.joined()
            case .conflict(let o, _, let t):
                switch choices[i] {
                case .yours?: out += o.joined()
                case .theirs?: out += t.joined()
                case .yoursThenTheirs?: out += (o + t).joined()
                case .theirsThenYours?: out += (t + o).joined()
                case nil:
                    out += "<<<<<<< Yours: \(sides.0)\n" + o.joined() + (o.last?.hasSuffix("\n") == false ? "\n" : "")
                        + "=======\n" + t.joined() + (t.last?.hasSuffix("\n") == false ? "\n" : "") + ">>>>>>> Theirs: \(sides.1)\n"
                }
            }
        }
        result = out
    }
}

struct MergeEditor: View {
    let controller: RepoController
    @State var model: MergeEditorModel
    @Environment(\.dismissSheet) private var dismiss

    static func present(_ c: RepoController, path: String, sides: (String, String)) {
        let model = MergeEditorModel(path: path, sides: sides)
        Task {
            do {
                model.load(try await c.repo.conflictSegments(path))
                Sheets.present(MergeEditor(controller: c, model: model), on: c.window)
            } catch {
                c.present(error, title: "Merge \(path)", context: .other)
            }
        }
    }

    var body: some View {
        let conflicts = model.conflictIndices
        VStack(spacing: 0) {
            HStack {
                Text(model.path).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Conflict \(conflicts.isEmpty ? 0 : model.current + 1) of \(conflicts.count)").foregroundStyle(.secondary)
                Button { model.current = max(model.current - 1, 0) } label: { Image(systemName: "chevron.left") }
                Button { model.current = min(model.current + 1, max(conflicts.count - 1, 0)) } label: { Image(systemName: "chevron.right") }
                Toggle("Base", isOn: $model.showBase).toggleStyle(.button)
            }
            .padding(10)
            Divider()
            VSplitView {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.segments.enumerated()), id: \.offset) { i, s in
                                segment(i, s).id(i)
                            }
                        }
                    }
                    .onChange(of: model.current) { _, n in
                        if n < conflicts.count { withAnimation { proxy.scrollTo(conflicts[n], anchor: .top) } }
                    }
                }
                .frame(minHeight: 200)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
                    TextEditor(text: $model.result).font(.system(size: 12, design: .monospaced))
                }
                .frame(minHeight: 160)
            }
            Divider()
            HStack {
                Text("Resolved \(model.resolvedCount) of \(conflicts.count)"
                     + (model.autoResolved.isEmpty ? "" : " · \(model.autoResolved.count) auto-resolved (whitespace/identical)"))
                    .foregroundStyle(.secondary)
                Button("Take Theirs All") { model.pickAll(.theirs) }
                Button("Take Yours All") { model.pickAll(.yours) }
                Button("Undo") { model.undo() }.keyboardShortcut("z", modifiers: [.command, .option])
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .option, .shift])
                Spacer()
                if let e = model.error { Text(e).foregroundStyle(.red).lineLimit(1) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & Stage") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.unresolved && !NSEvent.modifierFlags.contains(.option))
                    .help("Every chunk must be resolved; hold ⌥ to save anyway")
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 640, idealHeight: 760)
    }

    @ViewBuilder func segment(_ i: Int, _ s: ConflictSegment) -> some View {
        let mono = Font.system(size: 12, design: .monospaced)
        switch s {
        case .common(let lines):
            // Context only: first and last three lines of long agreed regions.
            let shown = lines.count > 8 ? Array(lines.prefix(3)) + ["⋯ \(lines.count - 6) unchanged lines\n"] + Array(lines.suffix(3)) : lines
            Text(shown.joined().trimmingCharacters(in: .newlines)).font(mono).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 2)
        case .conflict(let o, let b, let t):
            let choice = model.choices[i]
            let isCurrent = model.conflictIndices.firstIndex(of: i) == model.current
            HStack(alignment: .top, spacing: 1) {
                side("Theirs: \(model.sides.1)", t, .purple, picked: [.theirs, .yoursThenTheirs, .theirsThenYours].contains(choice)) {
                    model.pick(i, choice == .yours ? .yoursThenTheirs : choice == .theirs ? nil : .theirs)
                }
                if model.showBase { side("Base", b, .gray, picked: false, action: nil) }
                side("Yours: \(model.sides.0)", o, .blue, picked: [.yours, .yoursThenTheirs, .theirsThenYours].contains(choice)) {
                    model.pick(i, choice == .theirs ? .theirsThenYours : choice == .yours ? nil : .yours)
                }
            }
            .overlay(alignment: .leading) { Rectangle().fill(choice == nil ? Color.orange : Color.green).frame(width: 3) }
            .background(isCurrent ? Color.accentColor.opacity(0.08) : .clear)
            .padding(.vertical, 4)
            .help(model.autoResolved.contains(i) ? "Auto-resolved: the sides differ only in whitespace" : "")
        }
    }

    func side(_ title: String, _ lines: [String], _ color: Color, picked: Bool, action: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let action {
                    Toggle(isOn: Binding(get: { picked }, set: { _ in action() })) { Text(title).font(.system(size: 11, weight: .semibold)) }
                } else {
                    Text(title).font(.system(size: 11, weight: .semibold))
                }
                Spacer()
            }
            .foregroundStyle(color)
            Text(lines.joined().trimmingCharacters(in: .newlines).isEmpty ? "(nothing)" : lines.joined().trimmingCharacters(in: .newlines))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(color.opacity(picked ? 0.18 : 0.07))
    }

    func save() {
        let path = model.path, content = model.result
        dismiss()
        controller.perform("Resolve \(path)") { repo, _ in try await repo.resolveConflict(path, content: content) }
    }
}

// MARK: Dialogs

struct MergeDialog: View {
    let controller: RepoController
    let ref: String
    @State private var type = MergeType.default
    @State private var message = ""
    @State private var prediction = ""

    var body: some View {
        let into = controller.currentBranch ?? "HEAD"
        Dialog(title: "Merge", subtitle: "Merge \(ref) into \(into).",
               command: "git merge " + (type == .default ? "" : "--\(type.rawValue) ") + ref,
               action: "Merge", onConfirm: run) {
            LabeledContent("Merge:") { Text(ref).font(.system(.body, design: .monospaced)) }
            LabeledContent("Into:") { Text(into).font(.system(.body, design: .monospaced)) }
            Picker("Type:", selection: $type) { ForEach(MergeType.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.radioGroup)
            if type != .ffOnly && type != .squash {
                TextField("Message:", text: $message, prompt: Text("Merge branch '\(ref)'"), axis: .vertical).lineLimit(1...4)
            }
            if !prediction.isEmpty { LabeledContent("") { Text(prediction).font(.system(size: 11)) } }
        }
        .task { prediction = await HistoryActions.predictConflicts(controller, ours: "HEAD", theirs: ref) }
    }

    func run() {
        let r = ref, t = type, m = message
        controller.rewrite("Merge \(r)") { try await $0.merge(r, type: t, message: m.isEmpty ? nil : m) }
    }
}

struct RebaseDialog: View {
    let controller: RepoController
    let onto: String
    @State private var backup = true
    @State private var updateRefs = false
    @State private var autostash = false
    @State private var prediction = ""

    var body: some View {
        let branch = controller.currentBranch ?? "HEAD"
        Dialog(title: "Rebase", subtitle: "Replay \(branch)'s commits on top of \(onto). This rewrites history; ⌘Z undoes it.",
               command: "git rebase\(updateRefs ? " --update-refs" : "")\(autostash ? " --autostash" : "") \(onto)",
               action: "Rebase", onConfirm: run) {
            LabeledContent("Rebase:") { Text(branch).font(.system(.body, design: .monospaced)) }
            LabeledContent("Onto:") { Text(onto).font(.system(.body, design: .monospaced)) }
            Toggle("Create backup branch", isOn: $backup)
            Toggle("Update dependent branches", isOn: $updateRefs)
            Toggle("Autostash local changes", isOn: $autostash)
            if !prediction.isEmpty { LabeledContent("") { Text(prediction).font(.system(size: 11)) } }
        }
        .task { prediction = await HistoryActions.predictConflicts(controller, ours: onto, theirs: "HEAD") }
    }

    func run() {
        let o = onto, opts = RebaseOptions(backup: backup, updateRefs: updateRefs, autostash: autostash)
        controller.rewrite("Rebase onto \(o)") { try await $0.rebase(onto: o, options: opts) }
    }
}

struct CherryPickDialog: View {
    let controller: RepoController
    let commits: [Commit]
    var revert = false
    @State private var recordOrigin = false
    @State private var noCommit = false
    @State private var mainline = 1
    @State private var prediction = ""

    var body: some View {
        let verb = revert ? "Revert" : "Cherry-pick"
        let shas = commits.map(\.shortSHA).joined(separator: " ")
        Dialog(title: commits.count == 1 ? "\(verb) \(commits[0].shortSHA)" : "\(verb) \(commits.count) Commits",
               subtitle: revert ? "Create commits that undo these changes." : "Apply these commits on top of \(controller.currentBranch ?? "HEAD").",
               command: "git \(revert ? "revert" : "cherry-pick")\(recordOrigin ? " -x" : "")\(noCommit ? " --no-commit" : "")"
                + (commits.contains(where: \.isMerge) ? " -m \(mainline)" : "") + " \(shas)",
               action: verb, onConfirm: run) {
            LabeledContent("Commits:") {
                VStack(alignment: .leading) {
                    ForEach(commits.prefix(8)) { c in Text("\(c.shortSHA) \(c.subject)").lineLimit(1) }
                    if commits.count > 8 { Text("+\(commits.count - 8) more").foregroundStyle(.secondary) }
                }
            }
            if !revert { Toggle("Record origin (-x)", isOn: $recordOrigin) }
            Toggle("Apply without committing", isOn: $noCommit)
            if commits.contains(where: \.isMerge) {
                Picker("Mainline parent:", selection: $mainline) { Text("1 (the branch merged into)").tag(1); Text("2 (the merged branch)").tag(2) }
            }
            if !prediction.isEmpty { LabeledContent("") { Text(prediction).font(.system(size: 11)) } }
        }
        .task {
            // Single non-merge commit: replay its diff with merge-tree --merge-base.
            guard commits.count == 1, !commits[0].isMerge, let parent = commits[0].parents.first else { return }
            let c = commits[0]
            let (base, theirs) = revert ? (c.sha, parent) : (parent, c.sha)
            let r = try? await controller.repo.git.run(["merge-tree", "--write-tree", "--name-only", "--no-messages", "--merge-base=\(base)", "HEAD", theirs],
                                                      in: controller.repo.workTree, background: true, check: false)
            guard let r, r.status <= 1 else { return }
            let files = r.output.split(separator: "\n").dropFirst()
            prediction = r.status == 0 ? "✓ No conflicts expected" : "⚠ \(files.count) file\(files.count == 1 ? "" : "s") will conflict: " + files.prefix(3).joined(separator: ", ")
        }
    }

    func run() {
        // Oldest first, whatever order they were selected in.
        let shas = commits.sorted { $0.commitDate < $1.commitDate }.map(\.sha)
        let x = recordOrigin, n = noCommit, m = commits.contains(where: \.isMerge) ? mainline : nil, rv = revert
        controller.rewrite(rv ? "Revert" : "Cherry-pick") { repo in
            rv ? try await repo.revert(shas.reversed(), noCommit: n, mainline: m) : try await repo.cherryPick(shas, recordOrigin: x, noCommit: n, mainline: m)
        }
    }
}

struct ResetDialog: View {
    let controller: RepoController
    let commit: Commit
    @State private var mode = ResetMode.mixed

    var body: some View {
        Dialog(title: "Reset \(controller.currentBranch ?? "HEAD") to \(commit.shortSHA)",
               subtitle: commit.subject, command: "git reset --\(mode.rawValue) \(commit.shortSHA)",
               action: "Reset", destructive: mode == .hard, onConfirm: run) {
            Picker("Mode:", selection: $mode) { ForEach(ResetMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.radioGroup)
        }
    }

    func run() {
        let sha = commit.sha, m = mode
        controller.perform("Reset to \(commit.shortSHA)") { repo, _ in try await repo.reset(to: sha, mode: m) }
    }
}

/// Interactive rebase sheet (§5.12, RB-02).
struct InteractiveRebaseView: View {
    let controller: RepoController
    /// Exclusive base; nil rebases from the root.
    let base: String?
    let baseTitle: String
    @State private var items: [RebaseItem] = []
    @State private var selection = Set<String>()
    @State private var backup = true
    @State private var updateRefs = false
    @State private var autostash = false
    @State private var error: String?
    @Environment(\.dismissSheet) private var dismiss

    static let colors: [RebaseAction: Color] = [.pick: .green, .reword: .orange, .edit: .blue, .squash: .gray, .fixup: .gray, .drop: .red]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interactive Rebase: \(controller.currentBranch ?? "HEAD") onto \(baseTitle)").font(.system(size: 14, weight: .bold))
            Text("Newest at the bottom. Drag or ⌘↑/⌘↓ to reorder; P R E S F D set the action.").font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach($items) { $item in row($item) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 280)
            .onKeyPress(characters: .init(charactersIn: "presfd")) { press in
                guard let a = RebaseAction.allCases.first(where: { $0.key == press.characters.first }) else { return .ignored }
                for i in items.indices where selection.contains(items[i].id) { items[i].action = a }
                return .handled
            }
            HStack {
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.keyboardShortcut(.upArrow, modifiers: .command)
                Button { move(1) } label: { Image(systemName: "arrow.down") }.keyboardShortcut(.downArrow, modifiers: .command)
                Spacer()
                Toggle("Create backup branch", isOn: $backup)
                Toggle("Update dependent branches", isOn: $updateRefs)
                Toggle("Autostash", isOn: $autostash)
            }
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
            HStack {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Rebase") { start() }.keyboardShortcut(.defaultAction).disabled(items.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 480)
        .task {
            do { items = try await controller.repo.rebaseCandidates(base: base).map { RebaseItem(commit: $0) } } catch { self.error = "\(error)" }
        }
    }

    @ViewBuilder func row(_ item: Binding<RebaseItem>) -> some View {
        let it = item.wrappedValue
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("", selection: item.action) {
                    ForEach(RebaseAction.allCases, id: \.self) { a in
                        Label(a.rawValue.capitalized, systemImage: "circle.fill").tag(a)
                    }
                }
                .labelsHidden().frame(width: 110)
                Circle().fill(Self.colors[it.action] ?? .green).frame(width: 8, height: 8)
                if it.action == .squash || it.action == .fixup { Image(systemName: "arrow.turn.left.up").foregroundStyle(.secondary) }
                Text(it.commit.subject).strikethrough(it.action == .drop).lineLimit(1)
                    .foregroundStyle(it.action == .drop ? .secondary : .primary)
                Spacer()
                Text(it.commit.authorName).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).lineLimit(1)
                Text(it.commit.shortSHA).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                Text(Format.date(it.commit.authorDate)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            }
            if it.action == .reword {
                TextField("Message", text: Binding(get: { item.wrappedValue.message ?? it.commit.subject }, set: { item.wrappedValue.message = $0 }),
                          axis: .vertical)
                    .lineLimit(2...8).font(.system(size: 12)).padding(.leading, 120)
                    .task { if item.wrappedValue.message == nil, let d = try? await controller.repo.details(it.commit.sha) {
                        item.wrappedValue.message = d.body.isEmpty ? d.commit.subject : "\(d.commit.subject)\n\n\(d.body)"
                    } }
            }
        }
        .tag(it.id)
    }

    var summary: String {
        let counts = Dictionary(grouping: items, by: \.action).mapValues(\.count)
        return RebaseAction.allCases.compactMap { a in counts[a].map { "\($0) \(a.rawValue)" } }.joined(separator: " · ")
    }

    func move(_ delta: Int) {
        guard selection.count == 1, let i = items.firstIndex(where: { selection.contains($0.id) }), items.indices.contains(i + delta) else { return }
        items.swapAt(i, i + delta)
    }

    func start() {
        let b = base, list = items, opts = RebaseOptions(backup: backup, updateRefs: updateRefs, autostash: autostash)
        dismiss()
        controller.rewrite("Interactive rebase") { try await $0.interactiveRebase(base: b, items: list, options: opts) }
    }
}
