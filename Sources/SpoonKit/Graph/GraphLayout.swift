import Foundation

public struct GraphEdge: Sendable, Hashable {
    public var from: Int
    public var to: Int
    public var color: Int
}

/// What one commit-list row draws (§4.5). Lanes never shift sideways, so a row only needs:
/// lines passing straight through, edges arriving at the node from the top, and edges leaving it toward the bottom.
public struct GraphRow: Sendable, Hashable {
    public var lane: Int
    public var color: Int
    public var through: [GraphEdge] = []
    /// Top of row at `from` → node at `to`.
    public var incoming: [GraphEdge] = []
    /// Node at `from` → bottom of row at `to`.
    public var outgoing: [GraphEdge] = []
    public var width: Int = 1
}

/// Incremental straight-branch lane assignment, one top-down pass as rows stream in (§4.5).
/// - A commit takes the lane of a first-parent child (leftmost wins), so branches stay straight.
/// - Lane 0 is reserved for the main branch.
/// - Freed lanes are reused; existing lanes never move.
// ponytail: each row stores its own pass-through lanes (O(rows × active lanes) memory). Swap for the
// interval tree from §4.5 if linux.git-scale repos blow the memory budget.
public struct GraphLayout: Sendable {
    struct Slot: Sendable {
        var sha: String
        var color: Int
        var firstParent: Bool
        /// Reservation for the main tip; not drawn until the main branch actually appears.
        var visible: Bool
    }

    public static let paletteSize = 12
    private var slots: [Slot?] = []
    private var nextColor = 1
    /// `git log --first-parent` still prints every parent; merged-in parents never arrive, so they'd hold lanes open forever.
    private let firstParentOnly: Bool
    public private(set) var rows: [GraphRow] = []

    public init(mainTip: String? = nil, firstParentOnly: Bool = false) {
        self.firstParentOnly = firstParentOnly
        if let mainTip { slots = [Slot(sha: mainTip, color: 0, firstParent: true, visible: false)] }
    }

    public mutating func append(_ commits: [Commit]) {
        rows.reserveCapacity(rows.count + commits.count)
        for c in commits { rows.append(place(c)) }
    }

    /// Lays out one commit and returns its row.
    public mutating func place(_ c: Commit) -> GraphRow {
        let expecting = slots.indices.filter { slots[$0]?.sha == c.sha }
        let lane: Int
        let color: Int
        if let pick = expecting.first(where: { slots[$0]!.firstParent }) ?? expecting.first {
            lane = pick
            color = slots[pick]!.color
        } else {
            lane = freeLane()
            color = newColor()
        }
        var row = GraphRow(lane: lane, color: color)
        for (i, slot) in slots.enumerated() {
            guard let slot, slot.visible else { continue }
            if slot.sha == c.sha {
                row.incoming.append(GraphEdge(from: i, to: lane, color: slot.color))
            } else {
                row.through.append(GraphEdge(from: i, to: i, color: slot.color))
            }
        }
        for i in expecting { slots[i] = nil }

        if let first = c.parents.first {
            set(lane, Slot(sha: first, color: color, firstParent: true, visible: true))
            row.outgoing.append(GraphEdge(from: lane, to: lane, color: color))
        }
        for parent in c.parents.dropFirst() where !firstParentOnly {
            if let existing = slots.firstIndex(where: { $0?.sha == parent && $0?.visible == true }) {
                row.outgoing.append(GraphEdge(from: lane, to: existing, color: slots[existing]!.color))
            } else {
                let k = freeLane(after: lane)
                let col = newColor()
                set(k, Slot(sha: parent, color: col, firstParent: false, visible: true))
                row.outgoing.append(GraphEdge(from: lane, to: k, color: col))
            }
        }
        while let last = slots.last, last == nil { slots.removeLast() }
        let edges = row.through + row.incoming + row.outgoing
        row.width = max(lane, edges.map { max($0.from, $0.to) }.max() ?? 0) + 1
        return row
    }

    private mutating func set(_ i: Int, _ slot: Slot) {
        while slots.count <= i { slots.append(nil) }
        slots[i] = slot
    }

    private func freeLane(after lane: Int = -1) -> Int {
        let start = max(lane + 1, 0)
        if start < slots.count, let i = slots[start...].firstIndex(where: { $0 == nil }) { return i }
        if lane < 0 { return slots.count }
        return max(slots.count, start)
    }

    private mutating func newColor() -> Int {
        defer { nextColor = nextColor % (Self.paletteSize - 1) + 1 }
        return nextColor
    }
}
