import AppKit
import SwiftUI
import SpoonKit

/// State of the commit details pane (§5.8).
@MainActor @Observable
final class DetailsModel {
    enum Tab: Int, CaseIterable { case commit, changes, tree }
    var tab: Tab = .commit
    var sha: String?
    var details: CommitDetails?
    var files: [FileDiff] = []
    var selectedPath: String?
    var parent = 1
    var loading = false
    var error: String?
    var fileFilter = ""
    var diffSearch = ""
    var treeFiles: [String]?
    var treeFilter = ""
    var treeSelection: String?
    var treeRows: [DiffRow] = []
    var compareTo: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        sha = nil
        details = nil
        files = []
        selectedPath = nil
    }

    func load(sha: String, in c: RepoController, keepFile: Bool = false) {
        task?.cancel()
        if self.sha != sha { parent = 1; compareTo = nil }
        self.sha = sha
        loading = true
        error = nil
        treeFiles = nil
        treeRows = []
        let parent = self.parent, compare = compareTo
        let options = DiffOptions(ignoreWhitespace: AppModel.shared.settings.ignoreWhitespace, context: AppModel.shared.settings.diffContext)
        let previousPath = selectedPath
        task = Task {
            do {
                async let d = c.repo.details(sha)
                async let f = compare != nil
                    ? c.repo.diff(from: compare!, to: sha, options: options)
                    : c.repo.diff(commit: sha, parent: parent, options: options)
                let (details, files) = try await (d, f)
                guard !Task.isCancelled else { return }
                self.details = details
                self.files = files
                selectedPath = keepFile && files.contains(where: { $0.path == previousPath }) ? previousPath : files.first?.path
                loading = false
                if tab == .tree { loadTree(c) }
            } catch is CancellationError {
            } catch {
                self.error = "\(error)"
                loading = false
            }
        }
    }

    func loadTree(_ c: RepoController) {
        guard let sha, treeFiles == nil else { return }
        Task {
            treeFiles = (try? await c.repo.files(at: sha)) ?? []
        }
    }

    func showTreeFile(_ path: String, _ c: RepoController) {
        guard let sha else { return }
        treeSelection = path
        Task {
            let data = (try? await c.repo.show(path: path, at: sha)) ?? Data()
            guard treeSelection == path else { return }
            if data.prefix(8000).contains(0) {
                treeRows = [DiffRow(kind: .info, text: "Binary file (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")]
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            treeRows = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { i, line in
                DiffRow(kind: .line, left: DiffLine(kind: .context, text: String(line), oldLine: nil, newLine: i + 1))
            }
        }
    }

    var selectedFile: FileDiff? { files.first { $0.path == selectedPath } ?? files.first }
    var filteredFiles: [FileDiff] {
        fileFilter.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(fileFilter) }
    }
}

struct DetailsView: View {
    @Bindable var controller: RepoController
    var details: DetailsModel { controller.details }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: Bindable(details).tab) {
                    Text("Commit").tag(DetailsModel.Tab.commit)
                    Text("Changes").tag(DetailsModel.Tab.changes)
                    Text("File Tree").tag(DetailsModel.Tab.tree)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: details.tab) { _, tab in if tab == .tree { details.loadTree(controller) } }
            }
            .padding(6)
            Divider()
            if details.sha == nil {
                ContentUnavailableView("No commit selected", systemImage: "point.3.connected.trianglepath.dotted")
            } else if let error = details.error {
                ContentUnavailableView("Couldn't load commit", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                switch details.tab {
                case .commit: CommitTab(controller: controller)
                case .changes: ChangesTab(controller: controller, model: details)
                case .tree: FileTreeTab(controller: controller, model: details)
                }
            }
        }
    }
}

struct CommitTab: View {
    let controller: RepoController
    var model: DetailsModel { controller.details }

    var body: some View {
        ScrollView {
            if let d = model.details {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 24) {
                        person("AUTHOR", d.commit.authorName, d.commit.authorEmail, d.commit.authorDate)
                        if d.commit.committerEmail != d.commit.authorEmail || d.commit.committerName != d.commit.authorName {
                            person("COMMITTER", d.commit.committerName, d.commit.committerEmail, d.commit.commitDate)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        let refs = controller.refsBySHA[d.commit.sha] ?? []
                        if !refs.isEmpty {
                            GridRow {
                                label("REFS")
                                HStack { ForEach(refs) { RefPill(ref: $0) } }
                            }
                        }
                        GridRow {
                            label("SHA")
                            Button(d.commit.sha) { copy(d.commit.sha) }
                                .buttonStyle(.link).font(.system(size: 12, design: .monospaced)).help("Click to copy")
                        }
                        if !d.commit.parents.isEmpty {
                            GridRow {
                                label(d.commit.parents.count > 1 ? "PARENTS" : "PARENT")
                                HStack {
                                    ForEach(d.commit.parents, id: \.self) { p in
                                        Button(String(p.prefix(7))) { controller.select(p) }
                                            .buttonStyle(.link).font(.system(size: 12, design: .monospaced))
                                    }
                                }
                            }
                        }
                        let trailers = Self.coAuthors(d.body)
                        if !trailers.isEmpty {
                            GridRow {
                                label("CO-AUTHORS")
                                HStack { ForEach(trailers, id: \.self) { Text($0).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) } }
                            }
                        }
                    }
                    Text(linkified(d.commit.subject)).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    if !d.body.isEmpty {
                        Text(linkified(d.body)).font(.system(size: 12)).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                    Divider()
                    FileListView(files: model.files, selection: .constant(nil)) { file in
                        model.selectedPath = file.path
                        model.tab = .changes
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "spoon-commit", let sha = url.host { controller.select(sha); return .handled }
                    return .systemAction
                })
            } else if model.loading {
                ProgressView().padding(40)
            }
        }
    }

    func label(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    func person(_ title: String, _ name: String, _ email: String, _ date: Int64) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(name: name, email: email, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(name).font(.system(size: 13, weight: .medium))
                Text(email).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                Text(Format.full.string(from: Date(timeIntervalSince1970: TimeInterval(date)))).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func coAuthors(_ body: String) -> [String] {
        body.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.lowercased().hasPrefix("co-authored-by:") else { return nil }
            return String(l.dropFirst("co-authored-by:".count)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// SHAs that exist in the history become links (DET-10).
    func linkified(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let regex = try? NSRegularExpression(pattern: #"\b[0-9a-f]{7,40}\b"#) else { return out }
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            guard let full = controller.commits.first(where: { $0.sha.hasPrefix(token) })?.sha,
                  let r = Range(m.range, in: text), let ar = Range(r, in: out) else { continue }
            out[ar].link = URL(string: "spoon-commit://\(full)")
        }
        return out
    }
}

struct RefPill: View {
    let ref: Ref
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: ref.kind == .tag ? "tag" : ref.kind == .remoteBranch ? "cloud" : ref.isHead ? "checkmark" : "arrow.triangle.branch")
                .font(.system(size: 9, weight: .bold))
            Text(ref.shortName).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
    }
}

/// Status badge + path + `+a −d` stats (§5.8.1).
struct FileListView: View {
    let files: [FileDiff]
    @Binding var selection: String?
    var onOpen: ((FileDiff) -> Void)?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(files) { f in
                FileRow(file: f)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?(f) }
            }
        }
    }
}

struct FileRow: View {
    let file: FileDiff
    var body: some View {
        HStack(spacing: 6) {
            StatusBadge(letter: file.status.rawValue)
            let url = URL(fileURLWithPath: file.path)
            Text(url.lastPathComponent).font(.system(size: 12))
            Text(url.deletingLastPathComponent().relativePath == "." ? "" : url.deletingLastPathComponent().relativePath)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            if file.isBinary { Text("binary").font(.caption).foregroundStyle(.secondary) } else {
                Text("+\(file.additions)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.green)
                Text("−\(file.deletions)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ChangesTab: View {
    let controller: RepoController
    @Bindable var model: DetailsModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let d = model.details, d.commit.isMerge {
                    Picker("Diff against", selection: $model.parent) {
                        ForEach(1...d.commit.parents.count, id: \.self) { i in
                            Text("Parent \(i) (\(d.commit.parents[i - 1].prefix(7)))").tag(i)
                        }
                    }
                    .padding(6)
                    .onChange(of: model.parent) { _, _ in if let sha = model.sha { model.load(sha: sha, in: controller) } }
                }
                TextField("Filter files", text: $model.fileFilter).textFieldStyle(.roundedBorder).padding(6)
                List(model.filteredFiles, selection: $model.selectedPath) { f in
                    FileRow(file: f).tag(f.path)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
            DiffPane(file: model.selectedFile, search: $model.diffSearch, reload: {
                if let sha = model.sha { model.load(sha: sha, in: controller, keepFile: true) }
            })
        }
    }
}

struct FileTreeTab: View {
    let controller: RepoController
    @Bindable var model: DetailsModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Filter", text: $model.treeFilter).textFieldStyle(.roundedBorder).padding(6)
                if let files = model.treeFiles {
                    let shown = model.treeFilter.isEmpty ? files : files.filter { Fuzzy.score($0, model.treeFilter) != nil }
                    List(shown, id: \.self, selection: Binding(get: { model.treeSelection }, set: { p in
                        if let p { model.showTreeFile(p, controller) }
                    })) { path in
                        Text(path).font(.system(size: 12)).lineLimit(1).truncationMode(.head).tag(path)
                            .contextMenu {
                                Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([controller.repo.workTree.appendingPathComponent(path)])
                                }
                            }
                    }
                    .listStyle(.sidebar)
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
            }
            .frame(minWidth: 200, idealWidth: 280, maxWidth: 480)
            DiffTextView(rows: model.treeRows, sideBySide: false, scrollToken: model.treeSelection?.hashValue ?? 0)
        }
    }
}

/// Diff header with toggles (§5.10) above the virtualized diff view.
struct DiffPane: View {
    let file: FileDiff?
    @Binding var search: String
    var reload: () -> Void
    var extraControls: AnyView? = nil
    var selection: Binding<IndexSet>? = nil
    weak var menuDelegate: DiffViewDelegate? = nil
    @State private var jump = 0
    @State private var forceLarge: String?
    @Environment(\.self) private var env
    private var app: AppModel { AppModel.shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let file {
                    StatusBadge(letter: file.status.rawValue)
                    Text(DiffRows.title(file)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if let extraControls { extraControls }
                TextField("Find", text: $search).textFieldStyle(.roundedBorder).frame(width: 120)
                toggle("space", "Ignore whitespace", app.settings.ignoreWhitespace) { app.settings.ignoreWhitespace.toggle(); reload() }
                toggle("paragraphsign", "Show invisibles", app.settings.showInvisibles) { app.settings.showInvisibles.toggle() }
                Menu("±\(app.settings.diffContext == 100_000 ? "∞" : "\(app.settings.diffContext)")") {
                    ForEach([0, 1, 3, 5, 10, 25], id: \.self) { n in
                        Button("\(n) lines") { app.settings.diffContext = n; reload() }
                    }
                    Button("Entire file") { app.settings.diffContext = 100_000; reload() }
                }
                .fixedSize()
                .help("Context lines")
                toggle("rectangle.split.2x1", "Side by side", app.settings.diffSideBySide) { app.settings.diffSideBySide.toggle() }
                Button { jump -= 1 } label: { Image(systemName: "chevron.up") }.help("Previous change (⌘↑)").keyboardShortcut(.upArrow, modifiers: .command)
                Button { jump += 1 } label: { Image(systemName: "chevron.down") }.help("Next change (⌘↓)").keyboardShortcut(.downArrow, modifiers: .command)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 30)
            Divider()
            if let file {
                let lineCount = file.hunks.reduce(0) { $0 + $1.lines.count }
                if lineCount > 20_000 && forceLarge != file.path {
                    ContentUnavailableView {
                        Label("Large diff (\(lineCount) lines)", systemImage: "doc.text.magnifyingglass")
                    } actions: {
                        Button("Load diff anyway") { forceLarge = file.path }
                    }
                } else {
                    DiffTextView(rows: DiffRows.build([file], sideBySide: app.settings.diffSideBySide, fileHeaders: false),
                                 sideBySide: app.settings.diffSideBySide, showInvisibles: app.settings.showInvisibles,
                                 search: search, scrollToken: file.path.hashValue, jump: jump,
                                 menuDelegate: menuDelegate, selectionBinding: selection)
                }
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc")
            }
        }
    }

    func toggle(_ symbol: String, _ help: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Subsequence fuzzy matching with a contiguity bonus (Quick Launch, file filters).
enum Fuzzy {
    static func score(_ candidate: String, _ query: String) -> Int? { score(key(candidate), key(query)) }

    /// Lowercased scalars: several times cheaper to scan than `[Character]`.
    static func key(_ s: String) -> [Unicode.Scalar] { Array(s.lowercased().unicodeScalars) }

    static func score(_ c: [Unicode.Scalar], _ q: [Unicode.Scalar]) -> Int? {
        if q.isEmpty { return 0 }
        var score = 0, qi = 0, last = -2
        for i in c.indices where c[i] == q[qi] {
            score += i == last + 1 ? 5 : 1
            if i == 0 { score += 3 } else { switch c[i - 1] { case "/", " ", "-", "_", ".": score += 3; default: break } }
            last = i
            qi += 1
            if qi == q.count { return score - c.count / 10 }
        }
        return nil
    }

    static func matchedIndices(_ candidate: String, _ query: String) -> Set<Int> {
        let c = Array(candidate.lowercased()), q = Array(query.lowercased())
        var out = Set<Int>(), qi = 0
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] { out.insert(i); qi += 1 }
        return out
    }
}
