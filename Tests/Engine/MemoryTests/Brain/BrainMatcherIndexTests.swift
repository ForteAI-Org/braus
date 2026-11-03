import Foundation
@testable import Memory
import PerceptionCore
import Testing

struct BrainMatcherIndexTests {
    private func anchor(_ key: String, _ label: String = "", x: Double = 0.2,
                        y: Double = 0.2, size: Double = 0.02,
                        source: LabelSource? = nil, aliases: [String] = [],
                        kind: ElementKind = .control) -> ObjectAnchor {
        ObjectAnchor(anchorKey: key, kind: kind, label: label, labelSource: source, aliases: aliases,
                     boundsTypical: rect(x, y, size), firstSeen: .distantPast, lastSeen: .distantPast)
    }

    private func rect(_ x: Double, _ y: Double = 0.2, _ size: Double = 0.02) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: size, height: size)
    }

    private func group(_ keys: [String], size: Double = 0.04,
                       kind: ElementKind = .control) -> SiblingGroup {
        SiblingGroup(axis: .row, memberAnchors: keys, sharedKind: kind,
                     cellSize: NormalizedSize(width: size, height: size), lastSeen: .distantPast)
    }

    private func compare(_ brain: UIBrain, _ detection: BrainDetection,
                         claimed: Set<String> = [], allow: Bool = true) {
        let expected = ReferenceMatcher.match(detection, in: brain, excluding: claimed,
                                              admitsWeakMatch: { _ in allow })
        let index = BrainIndex(brain)
        #expect(BrainMatcher.match(detection, in: brain, index: index, excluding: claimed,
                                   admitsWeakMatch: { _ in allow }) == expected)
        #expect(BrainMatcher.match(detection, in: brain, excluding: claimed,
                                   admitsWeakMatch: { _ in allow }) == expected)
    }

    @Test func sameCascadeAndAmbiguities() {
        let objects = [anchor("a", " Café ", aliases: ["Start", "START"]),
                       anchor("b", "Café", x: 0.22), anchor("c", "Named", x: 0.7, source: .llm),
                       anchor("d", "", x: 0.5), anchor("e", "Other", x: 0.5, kind: .icon),
                       anchor("f", "Large", size: 0.2), anchor("g", "", x: 0.5, source: .user)]
        let brain = UIBrain(objects: objects, groups: [group(["missing", "d", "g"]), group(["a", "b"])])
        for kind: ElementKind in [.control, .icon, .text] {
            for label in ["", "Café", "CAFÉ", " start ", "Named", "Other", "Large", "Unknown"] {
                for x in [0.1, 0.2, 0.21, 0.3, 0.5, 0.7, 0.9] {
                    for size in [0.0, 0.009, 0.02, 0.044, 0.045, 0.2] {
                        compare(brain, BrainDetection(kind: kind, label: label, bounds: rect(x, 0.2, size)))
                    }
                }
            }
        }
        #expect(BrainMatcher.match(BrainDetection(kind: .control, label: "Café", bounds: rect(0.21)),
                                   in: brain) == .ambiguous(["a", "b"]))
    }

    @Test func cellEdgesAndVariableTolerance() {
        for cellSize in [0.0, 0.019, 0.04, 0.1, 0.4, 1.0] {
            let tolerance = max(cellSize * 0.8, 0.015)
            for x in [-0.03125, 0.0, 0.03125, 0.0625, 0.5, 1.0] {
                let brain = UIBrain(objects: [anchor("a", x: x)], groups: [group(["a"], size: cellSize)])
                for delta in [-tolerance, (-tolerance).nextDown, 0, tolerance.nextDown,
                              tolerance, tolerance.nextUp] {
                    for y in [0.2, 0.21] {
                        compare(brain, BrainDetection(kind: .control, label: "", bounds: rect(x + delta, y)))
                    }
                }
            }
        }
    }

    @Test func groupOrderIsPreserved() {
        let objects = [anchor("a"), anchor("b"), anchor("c")]
        for keys in [["b", "a"], ["a", "a"], ["missing", "c"]] {
            let brain = UIBrain(objects: objects, groups: [group(keys), group(["c", "b", "a"])])
            let detection = BrainDetection(kind: .control, label: "", bounds: rect(0.2))
            compare(brain, detection)
            let expected: BrainMatcher.Match = keys == ["missing", "c"] ? .found("c") : .ambiguous(keys)
            #expect(BrainMatcher.match(detection, in: brain) == expected)
        }
        // Duplicate keys resolve to the last object for ordinal slots, as before.
        compare(UIBrain(objects: [anchor("a", x: 0.8), anchor("a")], groups: [group(["a"])]),
                BrainDetection(kind: .control, label: "", bounds: rect(0.2)))
    }

    @Test func claimedAndWeakMatchesUnchanged() {
        let brain = UIBrain(objects: [anchor("a", "Named", source: .llm, aliases: ["Alias"]),
                                     anchor("b"), anchor("c", "Conflict", source: .user)],
                            groups: [group(["c", "b", "a"])])
        for claimed: Set<String> in [[], ["a"], ["b"], ["a", "b", "c"]] {
            for allow in [false, true] {
                for label in ["", "Named", "alias", "Conflict", "Unknown"] {
                    compare(brain, BrainDetection(kind: .control, label: label, bounds: rect(0.2)),
                            claimed: claimed, allow: allow)
                }
            }
        }
    }

    @Test func generatedSnapshotsAndAdmissionOrder() {
        var seed: UInt64 = 731
        func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        for _ in 0..<20 {
            let objects = (0..<40).map { i in
                anchor("k\(i)", ["", "Open", "Close"][next(3)],
                       x: Double(next(32)) / 32, y: Double(next(32)) / 32,
                       size: [0.0, 0.01, 0.02, 0.04][next(4)],
                       source: next(4) == 0 ? .llm : .user, aliases: ["Alias\(next(3))"],
                       kind: next(3) == 0 ? .icon : .control)
            }
            let groups = (0..<20).map { _ in
                group((0..<6).map { _ in "k\(next(42))" },
                      size: [0.01, 0.04, 0.12, 0.4][next(4)], kind: next(3) == 0 ? .icon : .control)
            }
            let brain = UIBrain(objects: objects, groups: groups)
            let index = BrainIndex(brain)
            for _ in 0..<60 {
                let detection = BrainDetection(kind: next(3) == 0 ? .icon : .control,
                                               label: ["", "Open", "Close", "Alias1", "Other"][next(5)],
                                               bounds: rect(Double(next(32)) / 32, Double(next(32)) / 32))
                let claimed: Set<String> = ["k\(next(40))"]
                var oldCalls: [String] = []
                var newCalls: [String] = []
                let old = ReferenceMatcher.match(detection, in: brain, excluding: claimed, admitsWeakMatch: {
                    oldCalls.append($0.anchorKey)
                    return oldCalls.count % 2 == 0
                })
                let new = BrainMatcher.match(detection, in: brain, index: index, excluding: claimed,
                                             admitsWeakMatch: {
                    newCalls.append($0.anchorKey)
                    return newCalls.count % 2 == 0
                })
                #expect(new == old)
                #expect(newCalls == oldCalls)
            }
        }
    }

    @Test func spatialCandidatesContainEveryOrdinalHit() {
        let objects = (0..<64).map { i in
            anchor("k\(i)", x: Double(i % 8) / 8 - 0.25, y: Double(i / 8) / 8 - 0.25)
        }
        let groups = [0.0, 0.04, 0.12, 0.4, 1.0].map { size in
            group(objects.reversed().map(\.anchorKey), size: size)
        }
        let brain = UIBrain(objects: objects, groups: groups)
        let index = BrainIndex(brain)
        for step in -8...40 {
            let bounds = rect(Double(step) / 32, Double(32 - step) / 32)
            let detection = BrainDetection(kind: .control, label: "", bounds: bounds)
            let candidates = index.spatial(in: brain).candidates(for: detection, recording: nil)
            let actual = candidates.filter {
                BrainMatcher.distance(objects[$0.anchor].boundsTypical, bounds) <= $0.tolerance
            }.map { "\($0.group):\($0.anchor)" }
            var expected: [String] = []
            for (g, group) in groups.enumerated() {
                for key in group.memberAnchors {
                    if let i = index.indexByKey[key],
                       BrainMatcher.distance(objects[i].boundsTypical, bounds)
                        <= max(group.cellSize.maxSide * 0.8, 0.015) {
                        expected.append("\(g):\(i)")
                    }
                }
            }
            #expect(actual == expected)
        }
    }

    @Test func unrepresentableGeometryPreservesResults() {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1e30] {
            for cellSize in [0.04, .infinity, .nan, .greatestFiniteMagnitude] {
                let brain = UIBrain(objects: [anchor("a", x: value), anchor("b")],
                                    groups: [group(["a", "b"], size: cellSize)])
                for x in [0.2, value] {
                    compare(brain, BrainDetection(kind: .control, label: "", bounds: rect(x)))
                }
            }
        }
    }

    @Test func normalizationOncePerAnchor() {
        for source: LabelSource? in [nil, .llm] {
            let brain = UIBrain(
                objects: [anchor("a", "", source: source, aliases: ["Alias", "ALIAS", ""])],
                groups: [group(["a"])]
            )
            var normalizations = 0
            let index = BrainIndex(brain, recording: { if $0 == .normalization { normalizations += 1 } })
            #expect(normalizations == 4)
            for _ in 0..<20 {
                _ = BrainMatcher.match(BrainDetection(kind: .control, label: "Unknown", bounds: rect(0.2)),
                                       in: brain, index: index, recording: {
                    if $0 == .normalization { normalizations += 1 }
                })
            }
            #expect(normalizations == 24)
        }
    }

    @Test func distantGroupsDoNotGrowCandidateWork() {
        func work(_ count: Int) -> Int {
            let objects = [anchor("local")] + (0..<count).map { anchor("far\($0)", x: 0.8, y: 0.8) }
            let brain = UIBrain(objects: objects,
                                groups: objects.reversed().map { group([$0.anchorKey]) })
            let index = BrainIndex(brain)
            var candidates = 0
            var probes = 0
            let detection = BrainDetection(kind: .control, label: "", bounds: rect(0.2))
            let result = BrainMatcher.match(detection, in: brain, index: index, recording: {
                if $0 == .ordinalCandidate { candidates += 1 }
                if $0 == .spatialProbe { probes += 1 }
            })
            #expect(result == ReferenceMatcher.match(detection, in: brain))
            #expect(result == .found("local"))
            #expect(probes == 25)
            return candidates
        }
        #expect(work(0) == 1)
        #expect(work(5000) == 1)
    }
}

// Frozen pre-index cascade used only as an offline equivalence reference.
private enum ReferenceMatcher {
    struct ReferenceIndex: Sendable {

        let byNormalizedLabel: [String: [Int]]
        let modelNamedByKind: [ElementKind: [Int]]
        let indexByKey: [String: Int]

        init(_ brain: UIBrain) {
            var byLabel: [String: [Int]] = [:]
            var modelNamed: [ElementKind: [Int]] = [:]
            var byKey: [String: Int] = Dictionary(minimumCapacity: brain.objects.count)
            for (index, object) in brain.objects.enumerated() {
                byKey[object.anchorKey] = index
                var normals: Set<String> = []
                let label = LabelText.normalize(object.label)
                if !label.isEmpty { normals.insert(label) }
                for alias in object.aliases {
                    let normal = LabelText.normalize(alias)
                    if !normal.isEmpty { normals.insert(normal) }
                }
                for normal in normals { byLabel[normal, default: []].append(index) }
                if object.labelSource == .llm { modelNamed[object.kind, default: []].append(index) }
            }
            byNormalizedLabel = byLabel
            modelNamedByKind  = modelNamed
            indexByKey        = byKey
        }

        func object(_ key: String, in brain: UIBrain) -> ObjectAnchor? {
            indexByKey[key].map { brain.objects[$0] }
        }
    }


    typealias Match = BrainMatcher.Match

    static func sizeCompatible(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return true }
        let widthRatio  = max(lhs.width, rhs.width) / min(lhs.width, rhs.width)
        let heightRatio = max(lhs.height, rhs.height) / min(lhs.height, rhs.height)
        return widthRatio <= 2.2 && heightRatio <= 2.2
    }

    static func distance(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let dx = lhs.midX - rhs.midX, dy = lhs.midY - rhs.midY
        return (dx * dx + dy * dy).squareRoot()
    }

    static func match(
        _ detection    : BrainDetection,
        in brain       : UIBrain,
        index prebuilt : ReferenceIndex? = nil,
        excluding claimed: Set<String> = [],
        admitsWeakMatch: (ObjectAnchor) -> Bool = { _ in true }
    ) -> Match {
        let index = prebuilt ?? ReferenceIndex(brain)
        func alive(_ i: Int) -> ObjectAnchor? {
            claimed.isEmpty || !claimed.contains(brain.objects[i].anchorKey) ? brain.objects[i] : nil
        }
        let bounds = detection.bounds
        let tolerance = max(max(bounds.width, bounds.height) * 1.25, 0.02)
        let normalizedLabel = LabelText.normalize(detection.label)
        func admitted(_ anchor: ObjectAnchor) -> Bool {
            let exact = !normalizedLabel.isEmpty && anchor.kind == detection.kind
                && (LabelText.normalize(anchor.label) == normalizedLabel
                    || anchor.aliases.contains { LabelText.normalize($0) == normalizedLabel })
            return exact || admitsWeakMatch(anchor)
        }
        let byLabel = normalizedLabel.isEmpty
            ? []
            : (index.byNormalizedLabel[normalizedLabel] ?? []).compactMap(alive).filter { anchor in
                anchor.kind == detection.kind && sizeCompatible(bounds, anchor.boundsTypical)
            }
        if !normalizedLabel.isEmpty {
            let near = byLabel.filter { distance($0.boundsTypical, bounds) <= tolerance }
            if near.count == 1 { return .found(near[0].anchorKey) }
            if near.count > 1 { return .ambiguous(near.map(\.anchorKey)) }
        }
        let modelNamedNear = (index.modelNamedByKind[detection.kind] ?? []).compactMap(alive).filter { anchor in
            sizeCompatible(bounds, anchor.boundsTypical) && distance(anchor.boundsTypical, bounds) <= tolerance
                && admitted(anchor)
        }
        if modelNamedNear.count == 1 { return .found(modelNamedNear[0].anchorKey) }
        if modelNamedNear.count > 1 { return .ambiguous(modelNamedNear.map(\.anchorKey)) }
        if !normalizedLabel.isEmpty, byLabel.count == 1 { return .found(byLabel[0].anchorKey) }
        for group in brain.groups where group.sharedKind == detection.kind {
            let slotTolerance = max(group.cellSize.maxSide * 0.8, 0.015)
            let hits = group.memberAnchors.compactMap { key in index.indexByKey[key].flatMap(alive) }
                .filter { anchor in
                    guard distance(anchor.boundsTypical, bounds) <= slotTolerance,
                          sizeCompatible(bounds, anchor.boundsTypical) else { return false }
                    let anchorLabel = LabelText.normalize(anchor.label)
                    let agrees = normalizedLabel.isEmpty || anchorLabel.isEmpty || normalizedLabel == anchorLabel
                        || anchor.aliases.contains { LabelText.normalize($0) == normalizedLabel }
                    return agrees && admitted(anchor)
                }
            if hits.count == 1 { return .found(hits[0].anchorKey) }
            if hits.count > 1 { return .ambiguous(hits.map(\.anchorKey)) }
        }
        return .none
    }
}


extension BrainMatcherIndexTests {
    @Test func spatialConstructionWaitsForOrdinalRecoveryAndIsReused() {
        let brain = UIBrain(objects: [anchor("a", "Named"), anchor("b", x: 0.7)],
                            groups: [group(["a", "b"])])
        let index = BrainIndex(brain)
        #expect(!index.spatialIsBuilt)
        #expect(BrainMatcher.match(.init(kind: .control, label: "Named", bounds: rect(0.2)),
                                   in: brain, index: index) == .found("a"))
        #expect(!index.spatialIsBuilt)
        for _ in 0..<2 {
            #expect(BrainMatcher.match(.init(kind: .control, label: "", bounds: rect(0.7)),
                                       in: brain, index: index) == .found("b"))
            #expect(index.spatialIsBuilt)
        }
    }
}
