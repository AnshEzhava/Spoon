import AppKit
import SwiftUI
import SpoonKit

/// One drawn row of a diff (§5.10). Lines are rows, which keeps staging, side-by-side alignment and huge files simple.
struct DiffRow {
    enum Kind { case fileHeader, hunk, line, info }
    var kind: Kind
    var text = ""
    var left: DiffLine?
    var right: DiffLine?
    var leftMarks: [NSRange] = []
    var rightMarks: [NSRange] = []
    var file = 0
    var hunk = 0
    /// Indices into hunk.lines of `left` / `right` (used by line staging).
    var leftIndex: Int?
    var rightIndex: Int?
}

enum DiffRows {
    static let maxLineLength = 2000

    static func build(_ files: [FileDiff], sideBySide: Bool, fileHeaders: Bool) -> [DiffRow] {
        var rows: [DiffRow] = []
        for (fi, file) in files.enumerated() {
            if fileHeaders { rows.append(DiffRow(kind: .fileHeader, text: title(file), file: fi)) }
            if file.isBinary { rows.append(DiffRow(kind: .info, text: "Binary file changed", file: fi)); continue }
            if file.hunks.isEmpty {
                let info = file.oldMode != file.newMode && file.oldMode != nil && file.newMode != nil
                    ? "Mode changed \(file.oldMode!) → \(file.newMode!)" : file.status == .renamed ? "Renamed without changes" : "No content changes"
                rows.append(DiffRow(kind: .info, text: info, file: fi))
            }
            for (hi, hunk) in file.hunks.enumerated() {
                rows.append(DiffRow(kind: .hunk, text: hunk.header, file: fi, hunk: hi))
                let lines = hunk.lines
                var i = 0
                while i < lines.count {
                    let line = lines[i]
                    if line.kind == .context || line.kind == .noNewline {
                        var row = DiffRow(kind: .line, left: line, file: fi, hunk: hi, leftIndex: i)
                        if sideBySide { row.right = line; row.rightIndex = i }
                        rows.append(row)
                        i += 1
                        continue
                    }
                    // A change block: deletions then additions.
                    var dels: [Int] = [], adds: [Int] = []
                    while i < lines.count, lines[i].kind == .deleted { dels.append(i); i += 1 }
                    while i < lines.count, lines[i].kind == .added { adds.append(i); i += 1 }
                    while i < lines.count, lines[i].kind == .noNewline {
                        if adds.isEmpty { dels.append(i) } else { adds.append(i) }
                        i += 1
                    }
                    var marks: [Int: [NSRange]] = [:]
                    for (d, a) in zip(dels, adds) where lines[d].kind == .deleted && lines[a].kind == .added {
                        let (l, r) = intraline(lines[d].text, lines[a].text)
                        marks[d] = l
                        marks[a] = r
                    }
                    if sideBySide {
                        for k in 0..<max(dels.count, adds.count) {
                            var row = DiffRow(kind: .line, file: fi, hunk: hi)
                            if k < dels.count { row.left = lines[dels[k]]; row.leftMarks = marks[dels[k]] ?? []; row.leftIndex = dels[k] }
                            if k < adds.count { row.right = lines[adds[k]]; row.rightMarks = marks[adds[k]] ?? []; row.rightIndex = adds[k] }
                            rows.append(row)
                        }
                    } else {
                        for idx in dels + adds {
                            rows.append(DiffRow(kind: .line, left: lines[idx], leftMarks: marks[idx] ?? [], file: fi, hunk: hi, leftIndex: idx))
                        }
                    }
                }
            }
        }
        return rows
    }

    static func title(_ f: FileDiff) -> String {
        var t = f.status == .renamed || f.status == .copied ? "\(f.oldPath) → \(f.newPath)" : f.path
        if let o = f.oldMode, let n = f.newMode, o != n { t += "   \(o) → \(n)" }
        return t
    }

    /// Changed span inside a pair of lines: strip the common prefix and suffix (DIFF-01).
    static func intraline(_ a: String, _ b: String) -> ([NSRange], [NSRange]) {
        let x = Array(a.utf16), y = Array(b.utf16)
        var p = 0
        while p < x.count, p < y.count, x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p, s < y.count - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        let l = NSRange(location: p, length: x.count - p - s), r = NSRange(location: p, length: y.count - p - s)
        // A near-total rewrite reads better without word marks.
        if Double(max(l.length, r.length)) > 0.7 * Double(max(x.count, y.count)) { return ([], []) }
        return (l.length > 0 ? [l] : [], r.length > 0 ? [r] : [])
    }
}

protocol DiffViewDelegate: AnyObject {
    @MainActor func diffView(_ view: DiffDocumentView, contextMenuFor rows: [Int]) -> NSMenu?
}

/// Virtualized diff renderer: draws only the visible rows with Core Text (§4.1).
final class DiffDocumentView: NSView {
    var rows: [DiffRow] = [] { didSet { invalidateSize(); needsDisplay = true } }
    var sideBySide = false { didSet { invalidateSize(); needsDisplay = true } }
    var showInvisibles = false { didSet { needsDisplay = true } }
    var tabWidth = 4
    var font = Theme.codeFont { didSet { invalidateSize(); needsDisplay = true } }
    var selection: IndexSet = [] { didSet { needsDisplay = true; onSelectionChange?() } }
    var onSelectionChange: (() -> Void)?
    var searchQuery = "" { didSet { needsDisplay = true } }
    weak var delegate: DiffViewDelegate?

    private var anchor: Int?
    private(set) var lineHeight: CGFloat = 16
    private var charWidth: CGFloat = 7.2
    private let gutter: CGFloat = 40

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func invalidateSize() {
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 3
        charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let longest = sideBySide ? 0 : rows.lazy.map { ($0.left?.text.count ?? $0.text.count) }.max() ?? 0
        let textWidth = CGFloat(min(longest, DiffRows.maxLineLength) + 4) * charWidth
        let width = max(enclosingScrollView?.contentSize.width ?? 400, sideBySide ? 0 : gutter * 2 + 18 + textWidth)
        setFrameSize(NSSize(width: width, height: max(CGFloat(rows.count) * lineHeight, enclosingScrollView?.contentSize.height ?? 0)))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        invalidateSize()
    }

    func row(at point: NSPoint) -> Int? {
        let r = Int(point.y / lineHeight)
        return r >= 0 && r < rows.count ? r : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard !rows.isEmpty else { return }
        let first = max(Int(dirtyRect.minY / lineHeight), 0)
        let last = min(Int(dirtyRect.maxY / lineHeight), rows.count - 1)
        guard first <= last else { return }
        let numberAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                           .foregroundColor: NSColor.tertiaryLabelColor]
        for i in first...last {
            let row = rows[i]
            let y = CGFloat(i) * lineHeight
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: lineHeight)
            switch row.kind {
            case .fileHeader:
                NSColor.windowBackgroundColor.setFill(); rect.fill()
                NSColor.separatorColor.setFill(); NSRect(x: 0, y: y + lineHeight - 1, width: bounds.width, height: 1).fill()
                draw(row.text, at: NSPoint(x: 8, y: y), attrs: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            case .hunk:
                Theme.hunkHeader.setFill(); rect.fill()
                draw(row.text, at: NSPoint(x: 8, y: y), attrs: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            case .info:
                draw(row.text, at: NSPoint(x: 8, y: y), attrs: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            case .line:
                if sideBySide {
                    let half = bounds.width / 2
                    drawSide(row.left, marks: row.leftMarks, x: 0, width: half, y: y, old: true, numberAttrs: numberAttrs)
                    drawSide(row.right, marks: row.rightMarks, x: half, width: half, y: y, old: false, numberAttrs: numberAttrs)
                    NSColor.separatorColor.setFill(); NSRect(x: half, y: y, width: 1, height: lineHeight).fill()
                } else if let line = row.left {
                    background(line.kind).setFill(); rect.fill()
                    if let n = line.oldLine { drawNumber(n, x: 0, y: y, attrs: numberAttrs) }
                    if let n = line.newLine { drawNumber(n, x: gutter, y: y, attrs: numberAttrs) }
                    drawText(line, marks: row.leftMarks, x: gutter * 2, y: y, clip: bounds.width)
                }
            }
            if selection.contains(i) {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
                rect.fill()
                NSColor.controlAccentColor.setFill()
                NSRect(x: 0, y: y, width: 3, height: lineHeight).fill()
            }
        }
    }

    private func background(_ kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .added: Theme.addLine
        case .deleted: Theme.delLine
        default: .clear
        }
    }

    private func drawSide(_ line: DiffLine?, marks: [NSRange], x: CGFloat, width: CGFloat, y: CGFloat, old: Bool,
                          numberAttrs: [NSAttributedString.Key: Any]) {
        let rect = NSRect(x: x, y: y, width: width, height: lineHeight)
        guard let line else { Theme.filler.setFill(); rect.fill(); return }
        background(line.kind).setFill(); rect.fill()
        if let n = old ? line.oldLine : line.newLine { drawNumber(n, x: x, y: y, attrs: numberAttrs) }
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        drawText(line, marks: marks, x: x + gutter, y: y, clip: width)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawNumber(_ n: Int, x: CGFloat, y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let s = "\(n)" as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: x + gutter - size.width - 6, y: y + (lineHeight - size.height) / 2), withAttributes: attrs)
    }

    private func drawText(_ line: DiffLine, marks: [NSRange], x: CGFloat, y: CGFloat, clip: CGFloat) {
        let sign: String
        let color: NSColor
        switch line.kind {
        case .added: sign = "+"; color = .systemGreen
        case .deleted: sign = "−"; color = .systemRed
        case .noNewline: sign = ""; color = .secondaryLabelColor
        case .context: sign = ""; color = .labelColor
        }
        draw(sign, at: NSPoint(x: x, y: y), attrs: [.font: font, .foregroundColor: color])
        var text = line.text
        var truncated = false
        if text.utf16.count > DiffRows.maxLineLength {
            text = String(text.prefix(DiffRows.maxLineLength))
            truncated = true
        }
        let display = expandTabs(text)
        let attr = NSMutableAttributedString(string: display, attributes: [
            .font: font, .foregroundColor: line.kind == .noNewline ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        if !marks.isEmpty, display == text {
            let wordColor = line.kind == .added ? Theme.addWord : Theme.delWord
            for m in marks where NSMaxRange(m) <= attr.length { attr.addAttribute(.backgroundColor, value: wordColor, range: m) }
        }
        if !searchQuery.isEmpty {
            let ns = display as NSString
            var r = ns.range(of: searchQuery, options: .caseInsensitive)
            while r.location != NSNotFound {
                attr.addAttribute(.backgroundColor, value: Theme.searchMatch, range: r)
                let start = NSMaxRange(r)
                r = ns.range(of: searchQuery, options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
            }
        }
        if showInvisibles {
            let ns = attr.string as NSString
            for i in 0..<ns.length where ns.character(at: i) == 32 {
                attr.replaceCharacters(in: NSRange(location: i, length: 1), with: "·")
                attr.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: i, length: 1))
            }
        }
        if truncated { attr.append(NSAttributedString(string: " … (line truncated)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
        attr.draw(at: NSPoint(x: x + 14, y: y + 1))
    }

    private func expandTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var out = ""
        var col = 0
        for ch in s {
            if ch == "\t" {
                let n = tabWidth - col % tabWidth
                out += String(repeating: showInvisibles ? "→" : " ", count: 1) + String(repeating: " ", count: n - 1)
                col += n
            } else { out.append(ch); col += 1 }
        }
        return out
    }

    private func draw(_ s: String, at p: NSPoint, attrs: [NSAttributedString.Key: Any]) {
        (s as NSString).draw(at: NSPoint(x: p.x, y: p.y + 1), withAttributes: attrs)
    }

    // MARK: Selection (click, ⇧-click, drag; ↑↓ with ⇧ to extend)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let r = row(at: convert(event.locationInWindow, from: nil)) else { selection = []; return }
        if event.modifierFlags.contains(.shift), let a = anchor {
            selection = IndexSet(integersIn: min(a, r)...max(a, r)).filteredLines(rows)
        } else if event.modifierFlags.contains(.command) {
            var s = selection
            if s.contains(r) { s.remove(r) } else { s.insert(r) }
            selection = s.filteredLines(rows)
            anchor = r
        } else {
            anchor = r
            selection = rows[r].kind == .hunk ? hunkRows(r) : IndexSet(integer: r).filteredLines(rows)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = anchor, let r = row(at: convert(event.locationInWindow, from: nil)) else { return }
        selection = IndexSet(integersIn: min(a, r)...max(a, r)).filteredLines(rows)
        autoscroll(with: event)
    }

    func hunkRows(_ headerRow: Int) -> IndexSet {
        var set = IndexSet()
        var i = headerRow + 1
        while i < rows.count, rows[i].kind == .line, rows[i].hunk == rows[headerRow].hunk, rows[i].file == rows[headerRow].file {
            set.insert(i); i += 1
        }
        return set.filteredLines(rows)
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?, .downArrow?:
            let delta = event.specialKey == .upArrow ? -1 : 1
            let current = (delta < 0 ? selection.first : selection.last) ?? (delta < 0 ? rows.count : -1)
            var next = current + delta
            while next >= 0, next < rows.count, rows[next].kind != .line { next += delta }
            guard next >= 0, next < rows.count else { return }
            if event.modifierFlags.contains(.shift), let a = anchor {
                selection = IndexSet(integersIn: min(a, next)...max(a, next)).filteredLines(rows)
            } else {
                anchor = next
                selection = IndexSet(integer: next)
            }
            scrollToVisible(NSRect(x: 0, y: CGFloat(next) * lineHeight, width: 1, height: lineHeight))
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let r = row(at: convert(event.locationInWindow, from: nil)), !selection.contains(r) {
            selection = rows[r].kind == .hunk ? hunkRows(r) : IndexSet(integer: r)
            anchor = r
        }
        return delegate?.diffView(self, contextMenuFor: Array(selection))
    }

    @objc func copy(_ sender: Any?) {
        let text = selection.compactMap { i -> String? in
            let row = rows[i]
            return row.kind == .line ? (row.right ?? row.left)?.text : row.text
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Next/previous change block start (‹ ›, ⌘↑ / ⌘↓).
    func jumpToChange(forward: Bool) {
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let current = Int((forward ? visible.minY : visible.minY) / lineHeight)
        let indices = forward ? Array(stride(from: current + 1, to: rows.count, by: 1)) : Array(stride(from: current - 1, through: 0, by: -1))
        func isChange(_ i: Int) -> Bool {
            let r = rows[i]
            return r.kind == .line && ((r.left?.kind ?? .context) != .context || (r.right?.kind ?? .context) != .context)
        }
        for i in indices where isChange(i) && (i == 0 || !isChange(i - 1)) {
            scroll(NSPoint(x: 0, y: max(CGFloat(i - 3) * lineHeight, 0)))
            return
        }
    }
}

extension IndexSet {
    /// Only changed lines can be staged; context and headers are dropped from a selection.
    func filteredLines(_ rows: [DiffRow]) -> IndexSet {
        IndexSet(filter { i in
            let r = rows[i]
            guard r.kind == .line else { return false }
            return (r.left?.kind ?? .context) == .added || (r.left?.kind ?? .context) == .deleted
                || (r.right?.kind ?? .context) == .added || (r.right?.kind ?? .context) == .deleted
        })
    }
}

/// SwiftUI host for the AppKit diff view.
struct DiffTextView: NSViewRepresentable {
    let rows: [DiffRow]
    var sideBySide: Bool
    var showInvisibles = false
    var search = ""
    var scrollToken = 0
    var jump: Int = 0
    var onSelection: ((IndexSet) -> Void)?
    weak var menuDelegate: DiffViewDelegate?
    var selectionBinding: Binding<IndexSet>?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let doc = DiffDocumentView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.postsFrameChangedNotifications = true
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let doc = scroll.documentView as? DiffDocumentView else { return }
        let c = context.coordinator
        doc.delegate = menuDelegate
        doc.onSelectionChange = { [weak doc] in
            guard let doc else { return }
            onSelection?(doc.selection)
            selectionBinding?.wrappedValue = doc.selection
        }
        if c.lastToken != scrollToken || c.rowCount != rows.count {
            c.lastToken = scrollToken
            c.rowCount = rows.count
            doc.rows = rows
            doc.selection = []
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            doc.rows = rows  // same file re-rendered (e.g. after a refresh): keep scroll position
        }
        if doc.sideBySide != sideBySide { doc.sideBySide = sideBySide }
        if doc.showInvisibles != showInvisibles { doc.showInvisibles = showInvisibles }
        if doc.searchQuery != search { doc.searchQuery = search }
        if let sel = selectionBinding?.wrappedValue, sel != doc.selection { doc.selection = sel }
        if c.lastJump != jump {
            doc.jumpToChange(forward: jump > c.lastJump)
            c.lastJump = jump
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var lastToken = -1
        var rowCount = -1
        var lastJump = 0
        func observe(_ scroll: NSScrollView) {
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak scroll] _ in
                MainActor.assumeIsolated { (scroll?.documentView as? DiffDocumentView)?.invalidateSize() }
            }
        }
    }
}
