import PerceptionCore

/// BrainSpatialIndex indexes ordinal occurrences by group kind and tolerance-sized cells.
/// Each level has a power-of-two cell side larger than its members' tolerances. Queries
/// include neighboring cells and restore original group/member order before exact checks.
/// Invalid or unrepresentable geometry uses exhaustive candidates to preserve prior behavior.
struct BrainSpatialIndex: Sendable {
    struct Entry: Sendable {
        let group: Int
        let anchor: Int
        let tolerance: Double
    }

    private struct Cell: Hashable, Sendable {
        let kind: ElementKind
        let level: Int
        let x: Int
        let y: Int
    }

    private let entries: [Entry]
    private let cells: [Cell: [Int]]
    private let levels: [ElementKind: Set<Int>]
    private let exhaustive: [ElementKind: [Int]]
    private let unindexed: [ElementKind: [Int]]

    init(_ brain: UIBrain, indexByKey: [String: Int], checking check: () throws -> Void) rethrows {
        try check()
        var entries: [Entry] = []
        var cells: [Cell: [Int]] = [:]
        var levels: [ElementKind: Set<Int>] = [:]
        var exhaustive: [ElementKind: [Int]] = [:]
        var unindexed: [ElementKind: [Int]] = [:]
        for (groupIndex, group) in brain.groups.enumerated() {
            try check()
            let tolerance = max(group.cellSize.maxSide * 0.8, 0.015)
            let level = tolerance.isFinite ? tolerance.exponent + 1 : 0
            let side = Self.side(at: level)
            for key in group.memberAnchors {
                try check()
                guard let anchor = indexByKey[key] else { continue }
                let id = entries.count
                entries.append(Entry(group: groupIndex, anchor: anchor, tolerance: tolerance))
                exhaustive[group.sharedKind, default: []].append(id)
                let bounds = brain.objects[anchor].boundsTypical
                guard tolerance.isFinite, side.isFinite,
                      let x = Self.coordinate(bounds.midX, side: side),
                      let y = Self.coordinate(bounds.midY, side: side) else {
                    unindexed[group.sharedKind, default: []].append(id)
                    continue
                }
                levels[group.sharedKind, default: []].insert(level)
                cells[Cell(kind: group.sharedKind, level: level, x: x, y: y), default: []].append(id)
            }
        }
        self.entries = entries
        self.cells = cells
        self.levels = levels
        self.exhaustive = exhaustive
        self.unindexed = unindexed
    }

    func candidates(for detection: BrainDetection, recording: ((BrainIndex.Work) -> Void)?) -> [Entry] {
        candidates(for: detection, recording: recording, checking: {})
    }

    func candidates(
        for detection: BrainDetection,
        recording: ((BrainIndex.Work) -> Void)?,
        checking check: () throws -> Void
    ) rethrows -> [Entry] {
        try check()
        var ids = unindexed[detection.kind] ?? []
        for level in levels[detection.kind] ?? [] {
            try check()
            let side = Self.side(at: level)
            guard let x = Self.coordinate(detection.bounds.midX, side: side),
                  let y = Self.coordinate(detection.bounds.midY, side: side) else {
                return try (exhaustive[detection.kind] ?? []).map { try check(); return entries[$0] }
            }
            // The extra cell on each side covers rounding at boundaries conservatively.
            for dx in -2...2 {
                for dy in -2...2 {
                    try check()
                    recording?(.spatialProbe)
                    let cell = Cell(
                        kind: detection.kind,
                        level: level,
                        x: x + dx,
                        y: y + dy
                    )
                    ids.append(contentsOf: cells[cell] ?? [])
                }
            }
        }
        return try ids.sorted().map { try check(); return entries[$0] }
    }

    private static func side(at level: Int) -> Double {
        Double(sign: .plus, exponent: level, significand: 1)
    }

    private static func coordinate(_ value: Double, side: Double) -> Int? {
        let scaled = (value / side).rounded(.down)
        guard scaled.isFinite, abs(scaled) < Double(Int.max / 4) else { return nil }
        return Int(scaled)
    }
}
