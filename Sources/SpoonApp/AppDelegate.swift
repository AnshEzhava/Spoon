import AppKit
import SwiftUI
import SpoonKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static private(set) var shared: AppDelegate!
    private var controllers: [TabWindowController] = []
    private var closedTabs: [String] = []
    private var quickLaunch: QuickLaunchPanel?
    private var activityWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var restoring = false
    let askpass = AskpassServer()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        DevHooks.install()
        NSWindow.allowsAutomaticWindowTabbing = true
        askpass.start()
        UNUserNotificationCenter.current().delegate = self
        restoreWindows()
        NSApp.activate()
        AutoFetch.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    /// Clicking a group-run notification opens that group's dashboard (§3.5).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo["group"] as? String).flatMap(UUID.init) else { return }
        await MainActor.run { GroupActions.dashboard(id) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveWindows()
        askpass.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `spoon://open?path=`, `spoon://clone?url=`, and folders dropped on the Dock icon (REPO-01, REPO-11).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                openRepo(path: url.path)
            } else if url.scheme == "spoon", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                switch comps.host {
                case "open": if let p = q["path"] { openRepo(path: p) }
                case "clone": AppActions.clone(q["url"])
                default: break
                }
            }
        }
    }

    // MARK: Windows and tabs

    var current: TabWindowController? {
        // The selected tab, even while the app is inactive and mainWindow still names the old one.
        let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.windowController is TabWindowController }
        return (w?.tabGroup?.selectedWindow ?? w)?.windowController as? TabWindowController
    }

    @discardableResult
    func makeController() -> TabWindowController {
        let c = TabWindowController()
        controllers.append(c)
        return c
    }

    @objc func newWindow(_ sender: Any?) {
        let c = makeController()
        c.window?.center()
        c.showWindow(nil)
    }

    @objc func newTab(_ sender: Any?) { newTab(in: current) }

    @discardableResult
    func newTab(in host: TabWindowController?) -> TabWindowController {
        let c = makeController()
        if let hostWindow = host?.window, let w = c.window {
            hostWindow.addTabbedWindow(w, ordered: .above)
            w.makeKeyAndOrderFront(nil)
        } else {
            c.window?.center()
            c.showWindow(nil)
        }
        return c
    }

    func closed(_ c: TabWindowController) {
        if !restoring, let p = c.tabPath { closedTabs.append(p) }
        controllers.removeAll { $0 === c }
        saveWindows()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let p = closedTabs.popLast() else { NSSound.beep(); return }
        openRepo(path: p, newTab: true)
    }

    /// Focuses an existing tab for the repo, else opens it in the current Home tab or a new tab.
    func openRepo(path: String, newTab: Bool = false) {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        let fromGroup = current?.model.homeGroup
        if let existing = controllers.first(where: { $0.tabPath == std }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let target: TabWindowController
        if !newTab, let c = current, c.repoController == nil { target = c } else if current != nil { target = self.newTab(in: current) } else {
            target = makeController()
            target.window?.center()
            target.showWindow(nil)
        }
        target.model.homeGroup = fromGroup // Back returns to the group the repo was opened from
        Task { await target.open(path: std) }
    }

    @objc func showHome(_ sender: Any?) { home() }

    /// Brings the Home tab forward, creating one if needed.
    @discardableResult
    func home() -> TabWindowController {
        if let home = controllers.first(where: { $0.repoController == nil }) {
            home.window?.makeKeyAndOrderFront(nil)
            return home
        }
        return newTab(in: current)
    }

    func selectTab(_ n: Int) {
        guard let tabs = current?.window?.tabbedWindows ?? current?.window.map({ [$0] }), n < tabs.count else { return }
        tabs[n].makeKeyAndOrderFront(nil)
    }

    private func saveWindows() {
        guard !restoring else { return }
        var seen = Set<ObjectIdentifier>()
        var state = WindowState()
        for c in controllers {
            guard let w = c.window, !seen.contains(ObjectIdentifier(w)) else { continue }
            let group = w.tabbedWindows ?? [w]
            group.forEach { seen.insert(ObjectIdentifier($0)) }
            let tabs = group.compactMap { ($0.windowController as? TabWindowController) }.map { $0.tabPath }
            state.windows.append(.init(tabs: tabs, selected: group.firstIndex(of: w.tabGroup?.selectedWindow ?? w) ?? 0))
        }
        try? AppModel.shared.stateStore.save(state)
    }

    func scheduleSave() { DispatchQueue.main.async { [weak self] in self?.saveWindows() } }

    private func restoreWindows() {
        let state = AppModel.shared.stateStore.load() ?? WindowState()
        guard !state.windows.isEmpty else { newWindow(nil); return }
        restoring = true
        for w in state.windows {
            var host: TabWindowController?
            for (i, path) in w.tabs.enumerated() {
                let c = host == nil ? makeController() : newTab(in: host)
                if host == nil { c.showWindow(nil) }
                host = host ?? c
                if let path { Task { await c.open(path: path); if i == w.selected { c.window?.makeKeyAndOrderFront(nil) } } }
            }
        }
        restoring = false
    }

    // MARK: Panels

    @objc func showQuickLaunch(_ sender: Any?) { showQuickLaunch(query: "") }

    func showQuickLaunch(query: String) {
        if quickLaunch == nil { quickLaunch = QuickLaunchPanel() }
        quickLaunch?.present(for: current, query: query)
    }

    @objc func showActivity(_ sender: Any?) {
        if activityWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ActivityView()))
            w.title = "Activity"
            w.setContentSize(NSSize(width: 860, height: 520))
            w.setFrameAutosaveName("Activity")
            activityWindow = w
        }
        activityWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Settings"
            w.styleMask.remove(.resizable)
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openRepository(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openRepo(path: url.path, newTab: current?.repoController != nil) }
    }

    @objc func addExistingRepository(_ sender: Any?) { AppActions.addExisting() }
    @objc func cloneRepository(_ sender: Any?) { AppActions.clone(nil) }
    @objc func initRepository(_ sender: Any?) { AppActions.initRepo(nil) }
}
