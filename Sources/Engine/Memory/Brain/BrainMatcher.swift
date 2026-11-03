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
        _ detection: BrainDetection,
        in brain: UIBrain,
        index prebuilt: BrainIndex? = nil,
        excluding claimed: Set<String> = [],
        admitsWeakMatch: (ObjectAnchor) -> Bool = { _ in true }
    ) -> Match {
        match(detection, in: brain, index: prebuilt, excluding: claimed,
              checking: {}, admitsWeakMatch: admitsWeakMatch, recording: nil)
    }

    static func match(
        _ detection: BrainDetection,
        in brain: UIBrain,
        index prebuilt: BrainIndex? = nil,
        excluding claimed: Set<String> = [],
        admitsWeakMatch: (ObjectAnchor) -> Bool = { _ in true },
        recording: ((BrainIndex.Work) -> Void)?
    ) -> Match {
        match(detection, in: brain, index: prebuilt, excluding: claimed,
              checking: {}, admitsWeakMatch: admitsWeakMatch, recording: recording)
    }

    public static func match(
        _ detection    : BrainDetection,
        in brain       : UIBrain,
        index prebuilt : BrainIndex? = nil,
        excluding claimed: Set<String> = [],
        checking check: () throws -> Void,
        admitsWeakMatch: (ObjectAnchor) -> Bool = { _ in true }
    ) rethrows -> Match {
        try match(
            detection,
            in: brain,
            index: prebuilt,
            excluding: claimed,
            checking: check,
            admitsWeakMatch: admitsWeakMatch,
            recording: nil
        )
    }

    static func match(
        _ detection: BrainDetection,
        in brain: UIBrain,
        index prebuilt: BrainIndex? = nil,
        excluding claimed: Set<String> = [],
        checking check: () throws -> Void,
        admitsWeakMatch: (ObjectAnchor) -> Bool = { _ in true },
        recording: ((BrainIndex.Work) -> Void)?
    ) rethrows -> Match {
        try check()
        let index = try prebuilt ?? BrainIndex(brain, checking: check, recording: recording)
        func alive(_ i: Int) throws -> ObjectAnchor? {
            try check()
            return claimed.isEmpty || !claimed.contains(brain.objects[i].anchorKey) ? brain.objects[i] : nil
        }
        let bounds = detection.bounds
        // Tolerance scales with the element: rows sit about two heights apart and must not be spanned.
        let tolerance = max(max(bounds.width, bounds.height) * 1.25, 0.02)
        recording?(.normalization)
        let normalizedLabel = LabelText.normalize(detection.label)
        func admitted(_ i: Int, _ anchor: ObjectAnchor) -> Bool {
            let exact = !normalizedLabel.isEmpty && anchor.kind == detection.kind
                && index.normalizedByAnchor[i].all.contains(normalizedLabel)
            return exact || admitsWeakMatch(anchor)
        }
        let byLabel = try normalizedLabel.isEmpty
            ? []
            : (index.byNormalizedLabel[normalizedLabel] ?? []).compactMap(alive).filter { anchor in
                try check()
                return anchor.kind == detection.kind && sizeCompatible(bounds, anchor.boundsTypical)
            }
        if !normalizedLabel.isEmpty {
            let near = try byLabel.filter { try check(); return distance($0.boundsTypical, bounds) <= tolerance }
            if near.count == 1 { return .found(near[0].anchorKey) }
            if near.count > 1 { return .ambiguous(near.map(\.anchorKey)) }
        }
        // A model-assigned name sticks to its position even when captions churn; only those few
        // anchors get positional pull, because giving it to every anchor poisoned aliases across screens.
        let modelNamedNear = try (index.modelNamedByKind[detection.kind] ?? []).compactMap { i -> ObjectAnchor? in
            try check()
            guard let anchor = try alive(i), sizeCompatible(bounds, anchor.boundsTypical),
                  distance(anchor.boundsTypical, bounds) <= tolerance,
                  admitted(i, anchor) else { return nil }
            return anchor
        }
        if modelNamedNear.count == 1 { return .found(modelNamedNear[0].anchorKey) }
        if modelNamedNear.count > 1 { return .ambiguous(modelNamedNear.map(\.anchorKey)) }
        if !normalizedLabel.isEmpty, byLabel.count == 1 { return .found(byLabel[0].anchorKey) }
        // Ordinal rescue, for unlabeled or jittered members only: a label that contradicts the slot's
        // member is another screen's object at the same place (measured), never a match.
        let candidates = try index.spatial(in: brain, checking: check)
            .candidates(for: detection, recording: recording, checking: check)
        var currentGroup: Int?
        var hits: [String] = []
        func result() -> Match? {
            if hits.count == 1 { return .found(hits[0]) }
            if hits.count > 1 { return .ambiguous(hits) }
            return nil
        }
        for candidate in candidates {
            try check()
            if currentGroup != candidate.group {
                if let answer = result() { return answer }
                currentGroup = candidate.group
            }
            recording?(.ordinalCandidate)
            let i = candidate.anchor
            guard let anchor = try alive(i),
                  distance(anchor.boundsTypical, bounds) <= candidate.tolerance,
                  sizeCompatible(bounds, anchor.boundsTypical) else { continue }
            let forms = index.normalizedByAnchor[i]
            let agrees = normalizedLabel.isEmpty || forms.label.isEmpty || forms.all.contains(normalizedLabel)
            if agrees && admitted(i, anchor) { hits.append(anchor.anchorKey) }
        }
        if let answer = result() { return answer }
        return .none
    }
}
