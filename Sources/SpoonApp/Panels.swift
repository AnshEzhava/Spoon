import AppKit
import SwiftUI
import SpoonKit

/// Activity Manager (§5.16): operations on the left, the exact git commands and output on the right.
struct ActivityView: View {
    enum Filter: String, CaseIterable { case all = "All", running = "Running", failed = "Failed", background = "Background" }
    @State private var filter = Filter.all
    @State private var selection: UUID?
    private let log = AppModel.shared.activity

    var body: some View {
        let ops = log.operations.filter {
            switch filter {
            case .all: !$0.background
            case .running: $0.isRunning
            case .failed: $0.failed
            case .background: $0.background
            }
        }
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().padding(8)
                List(ops, selection: $selection) { op in
                    HStack {
                        Image(systemName: op.isRunning ? "circle.dotted" : op.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(op.isRunning ? .secondary : op.failed ? Color.red : Color.green)
                        VStack(alignment: .leading) {
                            Text(op.title).lineLimit(1)
                            Text("\(URL(fileURLWithPath: op.repo).lastPathComponent) · \(op.start.formatted(date: .omitted, time: .standard)) · \(duration(op))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 300)
            detail(log.operations.first { $0.id == selection })
                .frame(minWidth: 360)
        }
        .frame(minWidth: 700, minHeight: 420)
    }

    @ViewBuilder func detail(_ op: ActivityLog.Operation?) -> some View {
        if let op {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(op.title).font(.headline)
                    Spacer()
                    if op.isRunning, let cancel = op.cancel { Button("Cancel") { cancel() } }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(transcript(op).characters), forType: .string)
                    }
                }
                .padding(8)
                Divider()
                ScrollView {
                    Text(transcript(op)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            ContentUnavailableView("Select an operation", systemImage: "list.bullet.rectangle")
        }
    }

    func transcript(_ op: ActivityLog.Operation) -> AttributedString {
        let mono = Font.system(size: 11, design: .monospaced)
        var s = AttributedString()
        for r in op.records {
            var cmd = AttributedString("$ \(r.commandLine)\n")
            cmd.font = mono.bold()
            s += cmd
            var out = AttributedString(String(r.stdout.prefix(4000)) + r.stderr + (r.status == 0 ? "" : "exit \(r.status)\n"))
            out.font = mono
            if r.status != 0 { out.foregroundColor = .red }
            s += out
        }
        if op.records.isEmpty {
            var empty = AttributedString(op.isRunning ? "Running…" : "No git commands recorded.")
            empty.foregroundColor = .secondary
            s += empty
        }
        return s
    }

    func duration(_ op: ActivityLog.Operation) -> String {
        let d = (op.end ?? Date()).timeIntervalSince(op.start)
        return d < 1 ? "\(Int(d * 1000)) ms" : String(format: "%.1f s", d)
    }
}

/// Settings window (§8). Every control writes straight to `settings.json`.
struct SettingsView: View {
    @Bindable private var model = AppModel.shared
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Form {
                Toggle("⌘1–9 selects tabs (instead of views)", isOn: $model.settings.cmdNumberSelectsTabs)
                Toggle("Vertical layout (details beside the commit list)", isOn: $model.settings.verticalLayout)
                TextField("Terminal:", text: $model.settings.terminalApp)
                TextField("Editor:", text: $model.settings.editorApp, prompt: Text("Default app"))
                LabeledContent("Source folders:") {
                    VStack(alignment: .leading) {
                        ForEach(model.settings.sourceFolders, id: \.self) { f in
                            HStack {
                                Text(f).lineLimit(1).truncationMode(.middle)
                                Button { model.settings.sourceFolders.removeAll { $0 == f } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                        Button("Add…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { model.settings.sourceFolders.append(u.path) }
                        }
                    }
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            GitSettings(model: model)
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }.tag("git")
            Form {
                Picker("Auto-fetch:", selection: $model.settings.autoFetchMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("Every \($0) minutes").tag($0) }
                }
            }
            .tabItem { Label("Fetch", systemImage: "arrow.down.circle") }.tag("fetch")
            Form {
                Stepper("Subject soft limit: \(model.settings.subjectSoftLimit)", value: $model.settings.subjectSoftLimit, in: 30...120)
                Stepper("Subject hard limit: \(model.settings.subjectHardLimit)", value: $model.settings.subjectHardLimit, in: 30...200)
                Toggle("Push after commit", isOn: $model.settings.pushAfterCommit)
            }
            .tabItem { Label("Commit", systemImage: "checkmark.circle") }.tag("commit")
            Form {
                Toggle("Side-by-side by default", isOn: $model.settings.diffSideBySide)
                Stepper("Context lines: \(model.settings.diffContext)", value: $model.settings.diffContext, in: 0...20)
                Toggle("Ignore whitespace", isOn: $model.settings.ignoreWhitespace)
                Toggle("Show invisibles", isOn: $model.settings.showInvisibles)
            }
            .tabItem { Label("Diff", systemImage: "plusminus") }.tag("diff")
            AccountsPane()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag("accounts")
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 380)
    }
}

private struct GitSettings: View {
    @Bindable var model: AppModel
    @State private var git = ""
    @State private var version = ""
    @State private var hooks = ""

    var body: some View {
        Form {
            LabeledContent("Git:") { Text("\(git)  \(version)").textSelection(.enabled) }
            LabeledContent("PATH:") {
                Text(LoginEnvironment.shared["PATH"] ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(4)
            }
            HStack {
                Button("Test Hooks Environment") { testHooks() }
                Spacer()
            }
            if !hooks.isEmpty { Text(hooks).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
            Picker("Commit order:", selection: $model.settings.commitOrder) {
                Text("Topological").tag(CommitOrder.topo)
                Text("Date").tag(CommitOrder.date)
            }
        }
        .task {
            let runner = await AppModel.shared.git()
            git = runner.gitPath
            version = (try? await runner.run(["--version"]))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// Runs the tools hooks usually need with the same environment git children get (§4.8).
    func testHooks() {
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "for t in git node npm npx python3 git-lfs; do printf '%-8s ' $t; command -v $t || echo 'not found'; done"]
            p.environment = LoginEnvironment.shared
            let pipe = Pipe()
            p.standardOutput = pipe
            try? p.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            await MainActor.run { hooks = out }
        }
    }
}
