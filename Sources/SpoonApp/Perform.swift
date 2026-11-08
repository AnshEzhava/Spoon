import AppKit
import SwiftUI
import SpoonKit

/// Running repository operations: busy state, activity entry, progress, refresh, and error sheets (§5.3, §5.13, §5.16).
extension RepoController {
    enum Context { case push, pull, fetch, checkout(retry: (LocalChangesMode) -> Void), other }

    /// Runs `body` as a named operation. Network operations can be cancelled from the status control.
    func perform(_ title: String, background: Bool = false, context: Context = .other,
                 _ body: @escaping @Sendable (Repository, @escaping Repository.Output) async throws -> Void,
                 then: (@MainActor () -> Void)? = nil) {
        guard background || busy == nil else { NSSound.beep(); return }
        let activity = AppModel.shared.activity
        var task: Task<Void, Never>?
        let opID = activity.begin(title, repo: repo.workTree, background: background) { task?.cancel() }
        if !background { busy = title }
        let repo = self.repo
        let progress: Repository.Output = { [weak self] text in
            guard let p = GitProgress.parse(text) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.busy != nil { self?.busy = "\(title)… \(p)" } } }
        }
        task = Task { [weak self] in
            var failed = false
            do {
                try await CurrentOperation.$id.withValue(opID) { try await body(repo, progress) }
            } catch is CancellationError {
                failed = true
            } catch {
                failed = true
                if !background { self?.present(error, title: title, context: context) }
            }
            activity.end(opID, failed: failed)
            guard let self else { return }
            if !background { self.busy = nil }
            self.refresh(state: true)
            if !failed { then?() }
        }
        currentTask = task
    }

    func cancelCurrent() { currentTask?.cancel() }

    func present(_ error: Error, title: String, context: Context) {
        let stderr = (error as? GitError)?.stderr ?? "\(error)"
        let command = (error as? GitError).map { "git " + $0.args.joined(separator: " ") } ?? ""
        let failure = (error as? UndoError).map { GitFailure(kind: .other, summary: $0.description, fixes: []) } ?? GitFailure.classify(stderr)
        var fixes: [(String, () -> Void)] = []
        for fix in failure.fixes {
            switch (fix, context) {
            case (.pullThenPush, _):
                fixes.append((fix.rawValue, { [weak self] in
                    guard let self else { return }
                    RepoActions.quickPull(self, then: { RepoActions.quickPush(self) })
                }))
            case (.forceWithLease, _):
                fixes.append((fix.rawValue, { [weak self] in self.map { RepoActions.pushDialog($0, force: true) } }))
            case (.removeLock, _):
                fixes.append((fix.rawValue, { [weak self] in
                    self?.perform("Remove index.lock") { repo, _ in
                        if try await !repo.removeStaleLock() { throw GitError(args: [], status: 1, stderr: "A git process is still running") }
                    }
                }))
            case (.stashAndRetry, .checkout(let retry)):
                fixes.append((fix.rawValue, { retry(.stash) }))
            case (.pullRebase, _):
                fixes.append((fix.rawValue, { [weak self] in self.map { RepoActions.quickPull($0, strategy: .rebase) } }))
            default: break
            }
        }
        if failure.kind == .locked || isLocked, !fixes.contains(where: { $0.0 == GitFailure.Fix.removeLock.rawValue }) {
            fixes.append((GitFailure.Fix.removeLock.rawValue, { [weak self] in
                self?.perform("Remove index.lock") { repo, _ in _ = try await repo.removeStaleLock() }
            }))
        }
        Sheets.present(ErrorSheet(title: title, summary: failure.summary, output: stderr, command: command, fixes: fixes), on: window)
    }

    var window: NSWindow? {
        NSApp.windows.first { ($0.windowController as? TabWindowController)?.repoController === self }
    }
}

/// Plain-language summary, suggested fixes, and the full git output (§5.13).
struct ErrorSheet: View {
    let title: String
    let summary: String
    let output: String
    let command: String
    let fixes: [(String, () -> Void)]
    @Environment(\.dismissSheet) private var dismiss
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(title) failed").font(.system(size: 14, weight: .bold))
                    Text(summary).font(.system(size: 13))
                }
            }
            DisclosureGroup("Details", isExpanded: $showDetails) {
                ScrollView {
                    Text((command.isEmpty ? "" : "$ \(command)\n") + output)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor))
            }
            HStack {
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("$ \(command)\n\(output)", forType: .string)
                }
                Spacer()
                ForEach(Array(fixes.enumerated()), id: \.offset) { _, fix in
                    Button(fix.0) { dismiss(); fix.1() }
                }
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: Sheet presentation

private struct DismissSheetKey: EnvironmentKey { static let defaultValue: @MainActor () -> Void = {} }
extension EnvironmentValues {
    var dismissSheet: @MainActor () -> Void {
        get { self[DismissSheetKey.self] }
        set { self[DismissSheetKey.self] = newValue }
    }
}

@MainActor
enum Sheets {
    /// Presents a SwiftUI view as a document-modal sheet; it only blocks its own window (§5.1 "Feel").
    static func present<V: View>(_ view: V, on window: NSWindow?) {
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let dismiss: @MainActor () -> Void = { [weak sheet] in
            guard let sheet else { return }
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
        }
        let host = NSHostingController(rootView: view.environment(\.dismissSheet, dismiss))
        sheet.contentViewController = host
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            window.beginSheet(sheet)
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
    }
}

/// Common dialog layout: icon, bold title, one-line description, labeled fields, "Show command", Cancel + verb button (§5.13).
struct Dialog<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var command: String = ""
    let action: String
    var disabled = false
    var destructive = false
    var onConfirm: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismissSheet) private var dismiss
    @State private var showCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .bold))
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            Form { content }
                .formStyle(.columns)
            if !command.isEmpty {
                DisclosureGroup("Show command", isExpanded: $showCommand) {
                    Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                }
                .font(.system(size: 11))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action, role: destructive ? .destructive : nil) { dismiss(); onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
