import AppKit

/// `make dev` only (SPOON_DEV=1): drive the app from scripts via a distributed notification.
///   snapshot <dir>      render every window to <dir>/window-N.png, current first (works off-screen)
///   menu <A ▸ B>        perform a menu item by title path
///   open <path>         open a repository
///   file <path>         select a Local Changes file
///   merge <branch>      open the merge dialog with <branch> picked
///   lines a-b           toggle diff rows in/out of the next commit
///   commit <subject>    commit the checked changes; undo performs ⌘Z
///   group <A/B>         show a group's dashboard; groupfetch / grouppull run it
///   return              press Return in the frontmost sheet
///   addexisting <path>  Add Existing Repository for <path>, skipping the folder picker
///   credtest            check git → SpoonAskpass → Keychain credentials with a throwaway account
@MainActor
enum DevHooks {
    static func install() {
        guard ProcessInfo.processInfo.environment["SPOON_DEV"] != nil else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init("app.spoon.dev"), object: nil, queue: .main) { note in
            let cmd = note.object as? String ?? ""
            MainActor.assumeIsolated { run(cmd) }
        }
        NSLog("Spoon dev hooks active")
    }

    static func run(_ cmd: String) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "snapshot":
            let current = AppDelegate.shared.current?.window
            let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }
                .map { $0.attachedSheet ?? $0 }.sorted { a, _ in a === current || a.sheetParent === current }
            for (i, w) in windows.enumerated() {
                guard let view = w.contentView?.superview ?? w.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg).appendingPathComponent("window-\(i).png"))
            }
        case "menu":
            var menu = NSApp.mainMenu
            var item: NSMenuItem?
            for title in arg.components(separatedBy: " ▸ ") {
                item = menu?.items.first { $0.title == title }
                menu = item?.submenu
            }
            // Untargeted items go to the current tab: the app is usually inactive while scripted, so there's no key window.
            if let item, let action = item.action {
                let tab = AppDelegate.shared.current
                let target: AnyObject? = item.target ?? (tab?.responds(to: action) == true ? tab : nil)
                NSApp.sendAction(action, to: target, from: item)
            } else { NSLog("Spoon dev: no menu item \(arg)") }
        case "select":
            guard let c = AppDelegate.shared.current?.repoController else { return }
            c.view = .history
            c.select(arg == "HEAD" ? c.headSHA : Int(arg).map { c.commits[$0].sha } ?? arg)
        case "view":
            AppDelegate.shared.current?.repoController?.view = arg == "local" ? .localChanges : .history
        case "tab":
            AppDelegate.shared.current?.repoController?.details.tab = arg == "changes" ? .changes : arg == "tree" ? .tree : .commit
        case "open":
            AppDelegate.shared.openRepo(path: arg)
        case "merge":
            guard let c = AppDelegate.shared.current?.repoController else { return }
            HistoryActions.mergeDialog(c, ref: c.refs.first { $0.shortName == arg })
        case "file":
            AppDelegate.shared.current?.repoController?.local.selection = [arg]
        case "lines":
            // Toggle diff rows N-M in/out of the next commit.
            guard let m = AppDelegate.shared.current?.repoController?.local, let d = m.diff else { return }
            let r = arg.split(separator: "-").compactMap { Int($0) }
            m.toggleLines(DiffRows.build([d], sideBySide: AppModel.shared.settings.diffSideBySide, fileHeaders: false).lineRefs(IndexSet(integersIn: r[0]...r.last!)))
        case "group", "groupfetch", "grouppull":
            guard let g = AppModel.shared.library.group(named: arg) else { NSLog("Spoon dev: no group \(arg)"); return }
            parts[0] == "group" ? GroupActions.dashboard(g.id) : GroupActions.run(g.id, pull: parts[0] == "grouppull")
        case "mergeeditor":
            guard let c = AppDelegate.shared.current?.repoController else { return }
            Task { let s = await c.repo.conflictSides(); MergeEditor.present(c, path: arg, sides: (s.ours, s.theirs)) }
        case "credtest":
            // Full credential chain against a throwaway Keychain item for host spoon.test.
            Task {
                try? Accounts.save(host: "spoon.test", login: "devtest", token: "dev-token")
                let git = await AppModel.shared.git()
                let r = try? await git.run(["credential", "fill"], input: Data("protocol=https\nhost=spoon.test\n\n".utf8), check: false)
                Accounts.remove(host: "spoon.test")
                NSLog("Spoon dev credtest: %@", r?.output.contains("password=dev-token") == true ? "PASS" : "FAIL \(r?.errorOutput ?? "")")
            }
        case "addexisting":
            AppActions.addExisting([URL(fileURLWithPath: arg)])
        case "return":
            // Presses Return in the frontmost sheet (its default button).
            guard let sheet = NSApp.windows.lazy.compactMap(\.attachedSheet).first,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
                                           context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return }
            sheet.sendEvent(e)
        case "commit":
            guard let m = AppDelegate.shared.current?.repoController?.local else { return }
            m.subject = arg
            m.commit(push: false)
        case "undo":
            AppDelegate.shared.current?.repoController.map { RepoActions.undo($0) }
        default:
            NSLog("Spoon dev: unknown command \(cmd)")
        }
    }
}
