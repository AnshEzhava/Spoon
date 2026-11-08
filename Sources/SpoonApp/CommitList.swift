import AppKit
import SpoonKit

/// The commit list: a view-based NSTableView over flat arrays with a fixed row height (§4.1, §5.7).
@MainActor
final class CommitListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let controller: RepoController
    let table = NSTableView()
    let scroll = NSScrollView()
    let findBar = FindBar()
    private var findMatches: [Int] = []
    private var findIndex = 0
    private var syncingSelection = false

    init(controller: RepoController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let columns: [(String, CGFloat, CGFloat)] = [("graph", 60, 24), ("subject", 520, 120), ("author", 140, 60), ("sha", 64, 50), ("date", 130, 80)]
        for (id, width, min) in columns {
            let col = NSTableColumn(identifier: .init(id))
            col.width = width
            col.minWidth = min
            col.title = id.capitalized
            col.resizingMask = .userResizingMask
            table.addTableColumn(col)
        }
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setAccessibilityLabel("Commits")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false

        let stack = NSStackView(views: [findBar, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        findBar.isHidden = true
        findBar.onChange = { [weak self] in self?.updateFind() }
        findBar.onNext = { [weak self] forward in self?.stepFind(forward) }
        findBar.onClose = { [weak self] in self?.closeFind() }
        view = stack

        controller.onSelect = { [weak self] in self?.syncSelectionFromModel() }
        controller.onHistoryReset = { [weak self] in self?.table.reloadData(); self?.syncSelectionFromModel() }
        controller.onHistoryAppend = { [weak self] _ in
            guard let self else { return }
            table.noteNumberOfRowsChanged()
            updateGraphWidth()
            syncSelectionFromModel()
            if !findBar.isHidden { updateFind() }
        }
    }

    /// The subject column takes whatever the fixed columns leave.
    override func viewDidLayout() {
        super.viewDidLayout()
        fitSubject()
    }

    private func fitSubject() {
        guard let subject = table.tableColumn(withIdentifier: .init("subject")) else { return }
        let others = table.tableColumns.filter { $0 !== subject && !$0.isHidden }.reduce(0) { $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(table.tableColumns.count) + 4
        let w = max(scroll.contentSize.width - others - spacing, subject.minWidth)
        if abs(subject.width - w) > 0.5 { subject.width = w }
    }

    private func updateGraphWidth() {
        let maxLanes = controller.rows.prefix(300).map(\.width).max() ?? 1
        let width = min(CGFloat(maxLanes) * GraphCell.laneWidth + 8, 160)
        if let col = table.tableColumn(withIdentifier: .init("graph")), abs(col.width - width) > 1 { col.width = width; fitSubject() }
    }

    func syncSelectionFromModel() {
        guard let sha = controller.selectedSHA, let row = controller.indexBySHA[sha] else { return }
        if table.selectedRow != row {
            syncingSelection = true
            table.selectRowIndexes([row], byExtendingSelection: false)
            syncingSelection = false
            table.scrollRowToVisible(row)
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { controller.commits.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column?.identifier.rawValue, row < controller.commits.count else { return nil }
        let commit = controller.commits[row]
        let isHead = commit.sha == controller.headSHA
        switch id {
        case "graph":
            let cell = (tableView.makeView(withIdentifier: .init("graph"), owner: nil) as? GraphCell) ?? GraphCell()
            cell.identifier = .init("graph")
            cell.row = controller.rows[row]
            cell.isMerge = commit.isMerge
            cell.isHead = isHead
            cell.needsDisplay = true
            return cell
        case "subject":
            let cell = (tableView.makeView(withIdentifier: .init("subject"), owner: nil) as? SubjectCell) ?? SubjectCell()
            cell.identifier = .init("subject")
            cell.configure(subject: commit.subject, refs: controller.refsBySHA[commit.sha] ?? [], rowColor: controller.rows[row].color,
                           bold: isHead, unpushed: controller.isUnpushed(row), unpulled: controller.isUnpulled(row),
                           highlight: findBar.isHidden ? nil : findBar.query)
            cell.setAccessibilityLabel(accessibilityText(row))
            return cell
        default:
            let cell = (tableView.makeView(withIdentifier: .init(id), owner: nil) as? NSTableCellView) ?? makeTextCell(id)
            let text: String
            switch id {
            case "author": text = commit.authorName
            case "sha": text = commit.shortSHA
            default: text = Format.date(commit.authorDate)
            }
            cell.textField?.stringValue = text
            cell.textField?.font = isHead ? .boldSystemFont(ofSize: 12) : (id == "author" ? .systemFont(ofSize: 12) : Theme.digitsFont)
            return cell
        }
    }

    private func makeTextCell(_ id: String) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init(id)
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func accessibilityText(_ row: Int) -> String {
        let c = controller.commits[row]
        let refs = (controller.refsBySHA[c.sha] ?? []).map(\.shortName).joined(separator: ", ")
        return "Commit by \(c.authorName), \(Format.date(c.authorDate)): \(c.subject)." + (refs.isEmpty ? "" : " Branches \(refs).")
            + (controller.isUnpushed(row) ? " Not pushed." : "")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let row = table.selectedRow
        controller.select(row >= 0 && row < controller.commits.count ? controller.commits[row].sha : nil)
    }

    var selectedCommits: [Commit] {
        table.selectedRowIndexes.compactMap { $0 < controller.commits.count ? controller.commits[$0] : nil }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < controller.commits.count else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        CommitMenu.build(menu, commit: controller.commits[row], selection: selectedCommits, controller: controller)
    }

    @objc func copy(_ sender: Any?) {
        let shas = selectedCommits.map(\.sha).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shas, forType: .string)
    }

    // MARK: Find in list (SRCH-01)

    func showFind() {
        findBar.isHidden = false
        view.window?.makeFirstResponder(findBar.field)
        updateFind()
    }

    func closeFind() {
        findBar.isHidden = true
        findMatches = []
        table.reloadData()
        view.window?.makeFirstResponder(table)
    }

    private func updateFind() {
        let q = findBar.query.lowercased()
        findMatches = q.isEmpty ? [] : controller.commits.indices.filter { i in
            let c = controller.commits[i]
            return c.sha.hasPrefix(q) || c.subject.lowercased().contains(q) || c.authorName.lowercased().contains(q)
                || c.authorEmail.lowercased().contains(q)
        }
        findIndex = 0
        findBar.setCount(findMatches.isEmpty ? (q.isEmpty ? "" : "No matches") : "\(findMatches.count) matches")
        table.reloadData()
        if let first = findMatches.first(where: { $0 >= max(table.selectedRow, 0) }) ?? findMatches.first {
            findIndex = findMatches.firstIndex(of: first) ?? 0
            selectRow(first)
        }
    }

    func stepFind(_ forward: Bool) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + (forward ? 1 : findMatches.count - 1)) % findMatches.count
        findBar.setCount("\(findIndex + 1) of \(findMatches.count)")
        selectRow(findMatches[findIndex])
    }

    private func selectRow(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}

/// Draws one row's lane segments (§4.5): pass-through lines, incoming edges, outgoing edges and the node.
final class GraphCell: NSView {
    static let laneWidth: CGFloat = 14
    var row: GraphRow?
    var isMerge = false
    var isHead = false

    override var isFlipped: Bool { true }
    // NSView stopped clipping by default in macOS 14; lanes past the capped column width would paint over the subject.
    override var clipsToBounds: Bool { get { true } set {} }

    private func x(_ lane: Int) -> CGFloat { CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2 + 2 }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let h = bounds.height, mid = h / 2
        func stroke(_ color: Int, _ build: (NSBezierPath) -> Void) {
            let p = NSBezierPath()
            p.lineWidth = 2
            p.lineCapStyle = .round
            build(p)
            Theme.lane(color).setStroke()
            p.stroke()
        }
        for e in row.through {
            stroke(e.color) { $0.move(to: NSPoint(x: x(e.from), y: 0)); $0.line(to: NSPoint(x: x(e.from), y: h)) }
        }
        for e in row.incoming {
            stroke(e.color) { p in
                p.move(to: NSPoint(x: x(e.from), y: 0))
                if e.from == e.to { p.line(to: NSPoint(x: x(e.to), y: mid)) } else {
                    p.curve(to: NSPoint(x: x(e.to), y: mid), controlPoint1: NSPoint(x: x(e.from), y: mid * 0.8),
                            controlPoint2: NSPoint(x: x(e.to), y: mid * 0.4))
                }
            }
        }
        for e in row.outgoing {
            stroke(e.color) { p in
                p.move(to: NSPoint(x: x(e.from), y: mid))
                if e.from == e.to { p.line(to: NSPoint(x: x(e.to), y: h)) } else {
                    p.curve(to: NSPoint(x: x(e.to), y: h), controlPoint1: NSPoint(x: x(e.from), y: mid + mid * 0.6),
                            controlPoint2: NSPoint(x: x(e.to), y: mid + mid * 0.2))
                }
            }
        }
        let r: CGFloat = isMerge ? 3.5 : 4.5
        let node = NSRect(x: x(row.lane) - r, y: mid - r, width: r * 2, height: r * 2)
        let color = Theme.lane(row.color)
        let circle = NSBezierPath(ovalIn: node)
        if isMerge {
            NSColor.textBackgroundColor.setFill()
            circle.fill()
            circle.lineWidth = 2
            color.setStroke()
            circle.stroke()
        } else {
            color.setFill()
            circle.fill()
        }
        if isHead {
            let ring = NSBezierPath(ovalIn: node.insetBy(dx: -2.5, dy: -2.5))
            ring.lineWidth = 1.5
            color.setStroke()
            ring.stroke()
        }
    }
}

/// Ref pills + subject, drawn directly (§5.7.1).
final class SubjectCell: NSView {
    private var subject = ""
    private var pills: [(String, NSColor, String?)] = []
    private var bold = false
    private var unpushed = false
    private var unpulled = false
    private var highlight: String?

    override var isFlipped: Bool { true }

    func configure(subject: String, refs: [Ref], rowColor: Int, bold: Bool, unpushed: Bool, unpulled: Bool, highlight: String?) {
        self.subject = subject
        self.bold = bold
        self.unpushed = unpushed
        self.unpulled = unpulled
        self.highlight = highlight?.isEmpty == false ? highlight : nil
        // Compact labels: `main` + `origin/main` at the same commit render as one pill "main ⇄ origin" (HIST-13).
        let locals = refs.filter { $0.kind == .localBranch }
        var used = Set<String>()
        var out: [(String, NSColor, String?)] = []
        let color = Theme.lane(rowColor)
        for l in locals.sorted(by: { $0.isHead && !$1.isHead }) {
            var label = l.shortName
            if let up = l.upstream, let remote = refs.first(where: { $0.name == up }) {
                label += " ⇄ \(remote.remoteName ?? "")"
                used.insert(remote.name)
            }
            out.append((label, color, l.isHead ? "checkmark" : nil))
        }
        for r in refs where r.kind == .remoteBranch && !used.contains(r.name) { out.append((r.shortName, color, "cloud")) }
        for t in refs where t.kind == .tag { out.append((t.shortName, .systemGray, "tag")) }
        pills = out
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let mid = bounds.height / 2
        if unpushed || unpulled {
            let dot = NSRect(x: x, y: mid - 3, width: 6, height: 6)
            let p = NSBezierPath(ovalIn: dot)
            if unpushed { NSColor.controlAccentColor.setFill(); p.fill() } else {
                NSColor.secondaryLabelColor.setStroke(); p.lineWidth = 1; p.stroke()
            }
        }
        x += 10
        let pillFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let maxPills = 4
        for (i, pill) in pills.enumerated() {
            if i == maxPills {
                drawPill("+\(pills.count - maxPills)", color: .systemGray, icon: nil, x: &x, font: pillFont)
                break
            }
            drawPill(pill.0, color: pill.1, icon: pill.2, x: &x, font: pillFont)
        }
        let font = bold ? NSFont.boldSystemFont(ofSize: 13) : Theme.rowFont
        let text = NSMutableAttributedString(string: subject, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let q = highlight {
            var search = subject.startIndex..<subject.endIndex
            while let r = subject.range(of: q, options: .caseInsensitive, range: search) {
                text.addAttribute(.backgroundColor, value: Theme.searchMatch, range: NSRange(r, in: subject))
                search = r.upperBound..<subject.endIndex
            }
        }
        let size = text.size()
        text.draw(with: NSRect(x: x, y: mid - size.height / 2, width: max(bounds.width - x, 0), height: size.height),
                  options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    private func drawPill(_ label: String, color: NSColor, icon: String?, x: inout CGFloat, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let size = (label as NSString).size(withAttributes: attrs)
        let iconWidth: CGFloat = icon == nil ? 0 : 12
        let rect = NSRect(x: x, y: (bounds.height - 16) / 2, width: size.width + 10 + iconWidth, height: 16)
        guard rect.maxX < bounds.width - 40 else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        color.withAlphaComponent(0.15).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = 1
        path.stroke()
        if let icon, let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) {
            img.isTemplate = true
            let tinted = img.tinted(.labelColor)
            tinted.draw(in: NSRect(x: rect.minX + 4, y: rect.midY - 4, width: 9, height: 8))
        }
        (label as NSString).draw(at: NSPoint(x: rect.minX + 5 + iconWidth, y: rect.midY - size.height / 2), withAttributes: attrs)
        x = rect.maxX + 4
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return img
    }
}

/// ⌘F bar over the list: query, match count, ‹ › (SRCH-01).
final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    var onChange: (() -> Void)?
    var onNext: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var query: String { field.stringValue }

    init() {
        super.init(frame: .zero)
        field.placeholderString = "Search SHA, author, message"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        count.textColor = .secondaryLabelColor
        count.font = Theme.secondaryFont
        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous match")!, target: self, action: #selector(prevMatch))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next match")!, target: self, action: #selector(nextMatch))
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        for b in [prev, next, done] { b.bezelStyle = .accessoryBarAction }
        let stack = NSStackView(views: [field, count, prev, next, done])
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setCount(_ s: String) { count.stringValue = s }
    @objc private func changed() { onChange?() }
    @objc private func prevMatch() { onNext?(false) }
    @objc private func nextMatch() { onNext?(true) }
    @objc private func close() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onNext?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?(); return true
        default: return false
        }
    }
}
