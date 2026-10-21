//
//  BrainMatcher.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore

/// BrainMatcher finds the anchor a detection is, by a cascade from cheap to rich, unique-accept
/// throughout: two near-equal candidates mean no match, because near-identical siblings break naive
/// matching. Label and kind within position tolerance; then a model-named anchor's positional claim;
/// then a unique label application-wide (the object moved); then a group ordinal slot. No match
/// means the ingest creates a new anchor, never a forced merge.
public enum BrainMatcher {

    /// Match is the cascade's answer. `ambiguous` carries the tied candidates so an ingest can mark
    /// them present (they are on screen) without picking one.
    public enum Match: Sendable, Equatable {
        case found(String)
        case ambiguous([String])
        case none
    }

    /// Objects cannot differ wildly in size: a wide logo-and-text composite must never merge with a
    /// narrow switch sharing its row's name (measured). A factor of 2.2 tolerates window resizes.
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

    /// Matches one detection. `index` must be built from this exact brain; nil builds one. `claimed`
    /// hides anchors already taken in this scene from every tier, which is how an ingest keeps its
    /// each-anchor-claimable-once rule.
    ///
    /// `admitsWeakMatch` decides whether a candidate may be bound on weaker evidence than an exact
    /// one: by a model-named anchor's positional claim or a group ordinal slot, when the detection's
    /// normalized label is empty or is neither the anchor's label nor one of its aliases (binding
    /// would adopt or append it). An exact candidate (the same kind and a normalized label the
    /// anchor already holds) never asks. A refused candidate is invisible to the tier that asked, so
    /// the cascade goes on and may end in a new anchor. The default admits every candidate.
    public static func match(
        _ detection    : BrainDetection,
        in brain       : UIBrain,
        index prebuilt : BrainIndex? = nil,
        excluding claimed: Set<String> = [],
        admitsWeakMatch: (ObjectAnchor) -> Bool = { _ in true }
    ) -> Match {
        let index = prebuilt ?? BrainIndex(brain)
        func alive(_ i: Int) -> ObjectAnchor? {
            claimed.isEmpty || !claimed.contains(brain.objects[i].anchorKey) ? brain.objects[i] : nil
        }
        let bounds = detection.bounds
        // Tolerance scales with the element: rows sit about two heights apart and must not be spanned.
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
        // A model-assigned name sticks to its position even when captions churn; only those few
        // anchors get positional pull, because giving it to every anchor poisoned aliases across screens.
        let modelNamedNear = (index.modelNamedByKind[detection.kind] ?? []).compactMap(alive).filter { anchor in
            sizeCompatible(bounds, anchor.boundsTypical) && distance(anchor.boundsTypical, bounds) <= tolerance
                && admitted(anchor)
        }
        if modelNamedNear.count == 1 { return .found(modelNamedNear[0].anchorKey) }
        if modelNamedNear.count > 1 { return .ambiguous(modelNamedNear.map(\.anchorKey)) }
        if !normalizedLabel.isEmpty, byLabel.count == 1 { return .found(byLabel[0].anchorKey) }
        // Ordinal rescue, for unlabeled or jittered members only: a label that contradicts the slot's
        // member is another screen's object at the same place (measured), never a match.
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
