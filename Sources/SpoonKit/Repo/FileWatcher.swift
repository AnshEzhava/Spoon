import Foundation

/// What a burst of file events means for a repo (§4.6).
public struct RepoChange: Sendable, Equatable {
    /// HEAD, index, refs, packed-refs, FETCH_HEAD, MERGE_HEAD or rebase-* changed: reload refs and status.
    public var state = false
    /// Worktree paths (relative) whose status may have changed.
    public var paths: Set<String> = []
    /// Too many paths or dropped events: re-run full status.
    public var fullRescan = false

    public init() {}

    public var isEmpty: Bool { !state && paths.isEmpty && !fullRescan }

    public static func classify(_ eventPaths: [String], workTree: String, gitDir: String, commonDir: String,
                                burstLimit: Int = 500) -> RepoChange {
        var change = RepoChange()
        let work = workTree.hasSuffix("/") ? workTree : workTree + "/"
        for path in eventPaths {
            if let rel = relative(path, to: gitDir) ?? relative(path, to: commonDir) {
                if isStateFile(rel) { change.state = true }
                continue
            }
            if path.hasPrefix(work) {
                let rel = String(path.dropFirst(work.count))
                if rel == ".git" || rel.hasPrefix(".git/") { continue }
                change.paths.insert(rel)
            } else if path == workTree {
                change.fullRescan = true
            }
        }
        if change.paths.count > burstLimit {
            change.paths.removeAll()
            change.fullRescan = true
        }
        return change
    }

    static func relative(_ path: String, to dir: String) -> String? {
        let d = dir.hasSuffix("/") ? dir : dir + "/"
        if path == dir { return "" }
        return path.hasPrefix(d) ? String(path.dropFirst(d.count)) : nil
    }

    static func isStateFile(_ rel: String) -> Bool {
        if rel.hasPrefix("objects/") || rel.hasPrefix("logs/") || rel.hasPrefix("spoon/") { return false }
        if rel.hasSuffix(".lock") { return false }
        switch rel {
        case "HEAD", "index", "packed-refs", "FETCH_HEAD", "MERGE_HEAD", "ORIG_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG":
            return true
        default:
            return rel.hasPrefix("refs/") || rel.hasPrefix("rebase-") || rel.hasPrefix("worktrees/")
        }
    }
}

#if canImport(CoreServices)
import CoreServices

/// One FSEvents stream over a set of directories (§4.6). Events are delivered on `queue`
/// after a 150 ms latency; `NoDefer` makes the first event of a burst arrive immediately.
public final class FileWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler

    public init(paths: [String], latency: TimeInterval = 0.15, queue: DispatchQueue = .main, handler: @escaping Handler) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var paths: [String] = []
            var rescan = false
            let rescanMask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                                    kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            for i in 0..<count {
                paths.append(String(cString: cPaths[i]))
                if eventFlags[i] & rescanMask != 0 { rescan = true }
            }
            watcher.handler(paths, rescan)
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
#endif
