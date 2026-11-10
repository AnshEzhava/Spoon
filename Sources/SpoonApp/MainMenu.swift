import AppKit

/// Real menus with key equivalents for everything (§5.1, §9). Actions travel the responder chain
/// to the key window's `TabWindowController` (the window delegate) or the app delegate.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Spoon", [
            item("About Spoon", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            item("Install Command Line Tool…", #selector(AppDelegate.installCLI(_:))),
            .separator(),
            item("Hide Spoon", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Spoon", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("New Tab", #selector(AppDelegate.newTab(_:)), "t"),
            item("Open Repository…", #selector(AppDelegate.openRepository(_:)), "o"),
            item("Add Existing Repository…", #selector(AppDelegate.addExistingRepository(_:)), "o", [.command, .option]),
            item("Clone…", #selector(AppDelegate.cloneRepository(_:)), "n", [.command, .shift]),
            item("New Repository…", #selector(AppDelegate.initRepository(_:)), "n", [.command, .shift, .control]),
            .separator(),
            item("Reopen Closed Tab", #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift]),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            item("Operation History…", #selector(TabWindowController.operationHistory(_:)), "z", [.command, .option]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(TabWindowController.performFind(_:)), "f"),
        ]))
        main.addItem(submenu("View", [
            item("Back", #selector(TabWindowController.showHomeTab(_:)), "["),
            item("Home", #selector(AppDelegate.showHome(_:)), "0", [.command, .shift]),
            item("Local Changes", #selector(TabWindowController.showLocalChanges(_:)), "1"),
            item("All Commits", #selector(TabWindowController.showAllCommits(_:)), "2"),
            item("Reveal HEAD", #selector(TabWindowController.revealHead(_:)), "0"),
            .separator(),
            item("Commit", #selector(TabWindowController.detailsCommit(_:)), "1", [.command, .option]),
            item("Changes", #selector(TabWindowController.detailsChanges(_:)), "2", [.command, .option]),
            item("File Tree", #selector(TabWindowController.detailsTree(_:)), "3", [.command, .option]),
            item("Hide / Show Details", #selector(TabWindowController.toggleDetails(_:)), "d", [.command, .shift]),
            item("Vertical Layout", #selector(TabWindowController.toggleLayout(_:)), "l", [.command, .option]),
            .separator(),
            item("Show Current Branch Only", #selector(TabWindowController.toggleCurrentBranchOnly(_:)), "a", [.command, .shift]),
            item("Hide Remote Branches", #selector(TabWindowController.toggleHideRemotes(_:))),
            item("Hide Tags", #selector(TabWindowController.toggleHideTags(_:))),
            item("First Parent Only", #selector(TabWindowController.toggleFirstParent(_:))),
            .separator(),
            item("Refresh", #selector(TabWindowController.refresh(_:)), "r"),
            item("Toggle Repository Sidebar", #selector(TabWindowController.toggleRepoSidebar(_:)), "s", [.command, .option]),
            item("Quick Launch…", #selector(AppDelegate.showQuickLaunch(_:)), "p"),
            item("Activity", #selector(AppDelegate.showActivity(_:)), "a", [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        main.addItem(submenu("Repository", [
            item("Fetch…", #selector(TabWindowController.fetchAction(_:)), "f", [.command, .shift]),
            item("Quick Fetch", #selector(TabWindowController.quickFetchAction(_:)), "f", [.command, .shift, .option]),
            item("Pull…", #selector(TabWindowController.pullAction(_:)), "l", [.command, .shift]),
            item("Quick Pull", #selector(TabWindowController.quickPullAction(_:)), "l", [.command, .shift, .option]),
            item("Push…", #selector(TabWindowController.pushAction(_:)), "p", [.command, .shift]),
            item("Quick Push", #selector(TabWindowController.quickPushAction(_:)), "p", [.command, .shift, .option]),
            .separator(),
            item("Commit…", #selector(TabWindowController.focusCommit(_:)), "c", [.command, .shift]),
            item("Stash…", #selector(TabWindowController.stashAction(_:)), "h", [.command, .shift]),
            item("Quick Stash", #selector(TabWindowController.quickStashAction(_:)), "h", [.command, .shift, .option]),
            .separator(),
            item("Checkout Branch…", #selector(TabWindowController.checkoutAction(_:)), "b"),
            item("New Branch…", #selector(TabWindowController.newBranchAction(_:)), "b", [.command, .shift]),
            item("New Tag…", #selector(TabWindowController.newTagAction(_:)), "g", [.command, .shift]),
            item("Merge…", #selector(TabWindowController.mergeAction(_:)), "m", [.command, .shift]),
            item("Rebase…", #selector(TabWindowController.rebaseAction(_:)), "e", [.command, .shift]),
            item("Add Remote…", #selector(TabWindowController.addRemoteAction(_:))),
            item("Publish to GitHub…", #selector(TabWindowController.publishAction(_:))),
            .separator(),
            item("Show in Finder", #selector(TabWindowController.showInFinder(_:)), "o", [.command, .control]),
            item("Open in Terminal", #selector(TabWindowController.openInTerminal(_:)), "t", [.command, .control]),
            item("Open in Editor", #selector(TabWindowController.openInEditor(_:)), "e", [.command, .control]),
            item("Copy Path", #selector(TabWindowController.copyRepoPath(_:))),
        ]))
        main.addItem(submenu("Groups", [
            item("Fetch Current Group", #selector(TabWindowController.fetchGroupAction(_:)), "f", [.command, .shift, .control]),
            item("Pull Current Group", #selector(TabWindowController.pullGroupAction(_:)), "l", [.command, .shift, .control]),
            item("Open Group Dashboard", #selector(TabWindowController.groupDashboardAction(_:)), "d", [.command, .shift, .control]),
        ]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu("Help", [])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    static func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    /// Every enabled leaf command, for Quick Launch (§5.14).
    static func commands(_ menu: NSMenu? = NSApp.mainMenu, path: [String] = []) -> [(title: String, path: String, item: NSMenuItem)] {
        guard let menu else { return [] }
        var out: [(String, String, NSMenuItem)] = []
        for i in menu.items where !i.isSeparatorItem && !i.isHidden {
            if let sub = i.submenu {
                out += commands(sub, path: path + [i.title])
            } else if i.action != nil {
                out.append((i.title, path.dropFirst().joined(separator: " ▸ "), i))
            }
        }
        return out
    }
}

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: key)
        self.handler = handler
        target = self
    }

    @objc private func run() { handler?() }
}
