//
//  SceneChanges.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 06/10/2026.
//

import Foundation

/// SceneChanges writes what changed between two scenes of one window, for a reader that holds the
/// first: each element added in full, each removed one short, each changed one with its earlier
/// values, under the section it is in now, and the header facts that moved.
///
/// Elements are matched by identity, never by line. A labeled element is its id (kind and normalized
/// label); among duplicates the same role pairs first, then the nearest place, and a caption that
/// grouping turned into a control, or back, in place is the same element of another kind. An
/// unlabeled element, whose id is only a grid cell, is the nearest one of its kind within `nearby`.
/// What the reader neither sees differently nor targets with is no change: a new order, a move within
/// `nearby`, a learned group tag, panels that moved within `nearby`, or a section renamed or redrawn
/// around an element that stayed as it was. An element now in another section while its old section
/// is still there has changed, because a target names its section. The lines are `text()`'s own, so
/// the reader keeps one vocabulary.
///
/// Pure and deterministic over two scenes. `SceneDifference` names one event's effect for memory;
/// this is the reader's update, and it lives beside the renderer whose lines it repeats.
public enum SceneChanges {

    /// ElementChange exposes the same identity matching and visible-change rules as the text diff.
    public struct ElementChange: Sendable {
        public let before: SceneElement?
        public let after: SceneElement?
    }

    /// Returns changed pairs, additions and removals without unchanged scene context.
    public static func elements(from before: SceneSnapshot, to after: SceneSnapshot) -> [ElementChange] {
        let matches = pairs(before.elements, after.elements)
        let oldIndexes = Set(matches.map(\.0))
        let newIndexes = Set(matches.map(\.1))
        let sections = Set(after.sections.map(\.name))
        var changes = matches.compactMap { old, new -> ElementChange? in
            guard !earlier(before.elements[old], after.elements[new], sections: sections).isEmpty else { return nil }
            return ElementChange(before: before.elements[old], after: after.elements[new])
        }
        changes += after.elements.enumerated().compactMap { index, element in
            newIndexes.contains(index) ? nil : ElementChange(before: nil, after: element)
        }
        changes += before.elements.enumerated().compactMap { index, element in
            oldIndexes.contains(index) ? nil : ElementChange(before: element, after: nil)
        }
        return changes
    }

    /// How far an element or a panel edge may move, in window-normalized units on either axis, and
    /// still be where it was: twice the hundredth a position is printed to, so it barely shows.
    static let nearby = 0.02

    /// The changes from `before` to `after`, or the one line that says there are none. `revision` is
    /// the number the reader knows `before` by. The lines carry no preamble: what `+`, `-` and `~` mean
    /// is said once in the tool instructions, and the result names its revision beside the text.
    public static func text(
        from before: SceneSnapshot,
        to after: SceneSnapshot,
        since revision: Int,
        cuts: SceneTextCuts = []
    ) -> String {
        changes(from: before, to: after, cuts: cuts).text(since: revision)
    }

    /// Returns typed changed rows and element pairs, independently of a reader's revision.
    public static func changes(
        from before: SceneSnapshot,
        to after: SceneSnapshot,
        cuts: SceneTextCuts = []
    ) -> SceneChangeSet {
        SceneChangeSet(
            elements: elements(from: before, to: after),
            commands: before.commands == after.commands ? nil : after.commands,
            previousOutOfView: before.outOfViewFields == after.outOfViewFields ? nil : before.outOfViewFields,
            outOfView: before.outOfViewFields == after.outOfViewFields ? nil : after.outOfViewFields,
            lines: renderedChangeLines(from: before, to: after, cuts: cuts)
        )
    }

    /// The pairs of indices, before and after, that are one element, closest first. A labeled element
    /// pairs with its own id, the same role first; failing that, with its label read as another kind
    /// within `nearby`, which is grouping that fused or split a caption. An unlabeled element pairs
    /// only with its kind within `nearby`.
    static func pairs(_ before: [SceneElement], _ after: [SceneElement]) -> [(Int, Int)] {
        let byIdentity = Dictionary(grouping: after.indices, by: { identity(after[$0]) })
        let byLabel = Dictionary(
            grouping: after.indices.filter { !isPositional(after[$0]) },
            by      : { LabelText.normalize(after[$0].label) }
        )
        var candidates: [(rank: Int, distance: Double, old: Int, new: Int)] = []
        for (old, element) in before.enumerated() {
            func distance(to new: Int) -> (dx: Double, dy: Double) {
                (abs(element.bounds.midX - after[new].bounds.midX), abs(element.bounds.midY - after[new].bounds.midY))
            }
            for new in byIdentity[identity(element)] ?? [] {
                let (dx, dy) = distance(to: new)
                if isPositional(element), dx > nearby || dy > nearby { continue }
                candidates.append((element.role == after[new].role ? 0 : 1, dx + dy, old, new))
            }
            guard !isPositional(element) else { continue }
            for new in byLabel[LabelText.normalize(element.label)] ?? [] where after[new].kind != element.kind {
                let (dx, dy) = distance(to: new)
                if dx <= nearby, dy <= nearby { candidates.append((2, dx + dy, old, new)) }
            }
        }
        candidates.sort { ($0.rank, $0.distance, $0.old, $0.new) < ($1.rank, $1.distance, $1.old, $1.new) }
        var takenBefore = Set<Int>()
        var takenAfter  = Set<Int>()
        var pairs: [(Int, Int)] = []
        for candidate in candidates where !takenBefore.contains(candidate.old) && !takenAfter.contains(candidate.new) {
            takenBefore.insert(candidate.old)
            takenAfter.insert(candidate.new)
            pairs.append((candidate.old, candidate.new))
        }
        return pairs
    }

    /// What one element is across two readings: its id, or its kind when the id is only a place.
    private static func identity(_ element: SceneElement) -> String {
        isPositional(element) ? "@" + element.kind.rawValue : element.id
    }

    /// True when the element's id is a grid cell (`SceneIdentity`) and names no thing.
    private static func isPositional(_ element: SceneElement) -> Bool {
        element.isUnlabeled || element.id.hasPrefix("?|@")
    }

    /// The section an element is listed under in `scene`: its own, when the scene prints that one.
    static func placed(_ section: String?, in scene: SceneSnapshot) -> String? {
        guard let section, scene.sections.contains(where: { $0.name == section }) else { return nil }
        return section
    }

    /// True when both scenes have the same sections in the same order, with the same scroll notes and
    /// bounds within `nearby`: a panel edge that moves less is the seam's jitter, not a new layout.
    static func sameLayout(_ before: SceneSnapshot, _ after: SceneSnapshot) -> Bool {
        let old = before.sectionsInReadingOrder
        let new = after.sectionsInReadingOrder
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { old, new in
            old.name == new.name
                && old.verticalScrollNote == new.verticalScrollNote
                && old.horizontalScrollNote == new.horizontalScrollNote
                && zip(old.bounds.array, new.bounds.array).allSatisfy { abs($0 - $1) <= nearby }
        }
    }
}

/// SceneChangeSet is the typed update shared by model policy and human scene readings.
public struct SceneChangeSet: Sendable {
    public let elements: [SceneChanges.ElementChange]
    public let commands: [String]?
    public let previousOutOfView: [OutOfViewField]?
    public let outOfView: [OutOfViewField]?
    public let lines: [SceneSnapshot.TextLine]
    public var isEmpty: Bool { lines.isEmpty }
    public var header: [SceneSnapshot.TextLine] { lines.filter { $0.job == .header } }

    /// Preserves the existing human-reading syntax, including its unchanged sentinel.
    public func text(since revision: Int) -> String {
        guard !isEmpty else { return SceneSnapshot.unchangedLine(since: revision) }
        return lines.map(\.text).joined().trimmingCharacters(in: .newlines)
    }
}
